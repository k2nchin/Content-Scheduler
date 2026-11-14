import Foundation

/// NVIDIA NIM llamado directo desde el iPhone con TU clave, guardada en el Llavero de iOS (no va dentro de la app).
@MainActor
enum NIM {
    static let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
    static let defaultModel = "meta/llama-3.3-70b-instruct"

    static var key: String? {
        let k = Keychain.get("nim.key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? nil : k
    }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "nim.model")?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultModel : m
    }
    static var isConfigured: Bool { key != nil }

    static func save(key: String) { key.isEmpty ? Keychain.delete("nim.key") : Keychain.set(key, for: "nim.key") }

    static func chat(system: String, user: String, maxTokens: Int = 800, temperature: Double = 0.4) async throws -> String {
        guard let key else { throw YTError(message: "Pon tu clave de NVIDIA en Ajustes → IA.") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": temperature, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw YTError(message: "NVIDIA no aceptó la clave. Revísala en Ajustes → IA.") }
            if status == 429 { throw YTError(message: "Se acabaron los créditos o el límite de NVIDIA por ahora.") }
            if status == 404 { throw YTError(message: "Ese modelo no existe en NVIDIA NIM. Revisa el nombre en Ajustes → IA.") }
            let msg = json["detail"] as? String ?? (json["error"] as? [String: Any])?["message"] as? String ?? "error \(status)"
            throw YTError(message: "NVIDIA NIM: \(msg)")
        }
        let content = (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prueba rápida de la clave y el modelo.
    static func test() async throws -> String {
        try await chat(system: "Responde solo con la palabra: listo", user: "prueba", maxTokens: 5, temperature: 0)
    }

    // MARK: Respuestas a comentarios

    /// Respuesta corta y natural a un comentario. Devuelve nil si es spam, insulto o no merece respuesta.
    static func reply(to comment: String, author: String, network: Network, account: String?) async throws -> String? {
        let name = author.trimmingCharacters(in: CharacterSet(charactersIn: "@")).split(separator: " ").first.map(String.init) ?? ""
        let system = """
        Eres el community manager de \(account ?? "un creador de contenido") en \(network.name).
        Escribe UNA respuesta breve (máximo 2 frases) al comentario de un seguidor: cálida, natural y en el mismo idioma del comentario.
        Puedes usar el nombre «\(name)» si queda natural y como mucho 1 emoji. Sin hashtags, sin links, sin inventar datos (fechas, precios, lanzamientos).
        Si te preguntan algo que no sabes, invita a estar pendiente o a escribir por mensaje directo.
        Si el comentario es spam, un insulto, odio o no tiene sentido, responde exactamente: SKIP
        Responde solo con el texto de la respuesta.
        """
        let text = try await chat(system: system, user: comment, maxTokens: 120, temperature: 0.7)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”").union(.whitespacesAndNewlines))
        if text.isEmpty || text.uppercased().hasPrefix("SKIP") { return nil }
        return String(text.prefix(500))
    }

    // MARK: Clipper

    static func findClips(lines: [StudioExport.Line], duration: Double, count: Int, length: Double) async throws -> [ClipAI.Result] {
        let minL = max(10, length * 0.5), maxL = length * 1.5
        var transcript = lines.map { String(format: "[%.1f-%.1f] ", $0.start, $0.end) + $0.text }.joined(separator: "\n")
        if transcript.count > 60_000 { transcript = String(transcript.prefix(60_000)) }
        let system = """
        Eres un editor experto en clips virales para YouTube Shorts, Instagram Reels y TikTok.
        Recibes la transcripción de un video con tiempos en segundos. Elige los \(count) mejores momentos para clips.
        Reglas:
        - Cada clip dura entre \(Int(minL)) y \(Int(maxL)) segundos y empieza y termina en límites de frase (no cortes a mitad de idea).
        - Prioriza un gancho fuerte en los primeros 3 segundos, emoción, humor, polémica, revelaciones o frases citables.
        - Los clips no se enciman.
        - Responde SOLO con JSON válido, sin texto extra, en español, con esta forma:
        {"clips":[{"start":0,"end":0,"score":0,"hook":"frase de gancho","reason":"por qué funciona","titles":{"youtube":"","instagram":"","facebook":""},"hashtags":["",""]}]}
        - score es de 0 a 100 según el potencial viral real; no infles los números.
        """
        let raw = try await chat(system: system, user: String(format: "Duración total: %.1f s\nTranscripción:\n", duration) + transcript,
                                 maxTokens: 3000, temperature: 0.3)
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}") else {
            throw YTError(message: "La IA no devolvió un resultado válido. Inténtalo otra vez.")
        }
        struct Wrap: Decodable { let clips: [Loose] }
        struct Loose: Decodable {
            var start: Double?; var end: Double?; var score: Double?; var hook: String?; var reason: String?
            var titles: [String: String]?; var hashtags: [String]?
        }
        let wrap = try JSONDecoder().decode(Wrap.self, from: Data(raw[a...b].utf8))
        var out: [ClipAI.Result] = []
        for c in wrap.clips {
            guard var s = c.start, var e = c.end else { continue }
            s = max(0, s); e = min(duration, e)
            guard e - s >= max(3, minL * 0.6), e - s <= maxL * 1.25 else { continue }
            if out.contains(where: { s < $0.end && e > $0.start }) { continue }
            let tags = (c.hashtags ?? []).map { "#" + $0.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "") }.filter { $0.count > 1 }
            out.append(ClipAI.Result(start: (s * 10).rounded() / 10, end: (e * 10).rounded() / 10,
                                     score: max(0, min(100, Int(c.score ?? 0))), hook: c.hook ?? "", reason: c.reason ?? "",
                                     titles: .init(youtube: String((c.titles?["youtube"] ?? "").prefix(100)),
                                                   instagram: c.titles?["instagram"] ?? "", facebook: c.titles?["facebook"] ?? ""),
                                     hashtags: Array(tags.prefix(8))))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(count))
    }
}
