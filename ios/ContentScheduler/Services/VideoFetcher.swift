import Foundation

/// Trae un video desde tu propio servidor a partir de un link.
/// La app no descarga de ninguna plataforma: solo le pide el archivo a tu servidor.
///
/// Contrato del servidor:
///   POST {servidor}/fetch   body: {"url": "https://…"}
///   Respuesta A: el archivo de video (Content-Type: video/*)
///   Respuesta B: {"video_url": "https://…"}  → la app lo baja de ahí
///   Error:       {"error": "texto"}
enum VideoFetcher {
    /// Dirección del servidor: se pone en Ajustes y se cambia sin recompilar.
    static var server: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "clip.server")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !saved.isEmpty { return saved }
            return (Bundle.main.object(forInfoDictionaryKey: "ClipServerURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "clip.server") }
    }

    static var isConfigured: Bool {
        guard let u = URL(string: server), let s = u.scheme else { return false }
        return s == "http" || s == "https"
    }

    private static func endpoint() throws -> URL {
        guard var c = URLComponents(string: server), c.scheme != nil else {
            throw YTError(message: "Pon la dirección de tu servidor en Ajustes → Servidor de videos.")
        }
        if !c.path.contains("fetch") {
            c.path = c.path.hasSuffix("/") ? c.path + "fetch" : c.path + "/fetch"
        }
        guard let u = c.url else { throw YTError(message: "Esa dirección de servidor no es válida.") }
        return u
    }

    /// Pide el video y lo guarda en la app. `progress` va de 0 a 1 (−1 si no se sabe el tamaño).
    static func fetch(_ link: String, progress: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: clean), let s = u.scheme, s == "http" || s == "https" else {
            throw YTError(message: "Pega un link válido.")
        }
        await progress(-1, "Pidiéndole el video a tu servidor…")

        var req = URLRequest(url: try endpoint())
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["url": clean])

        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // Respuesta en JSON: o es un error, o trae la dirección del video
        if type.contains("json") || !(200..<300).contains(status) {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let msg = json["error"] as? String { throw YTError(message: "Tu servidor: \(msg)") }
            guard (200..<300).contains(status) else { throw YTError(message: "Tu servidor respondió con error \(status).") }
            guard let s = (json["video_url"] ?? json["url"]) as? String, let vu = URL(string: s) else {
                throw YTError(message: "Tu servidor no devolvió el video.")
            }
            await progress(-1, "Bajando el video…")
            return try await download(vu, progress: progress)
        }

        // El servidor mandó el archivo directo
        let ext = type.contains("quicktime") ? "mov" : "mp4"
        return try move(tmp, ext: ext)
    }

    private static func download(_ url: URL, progress: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        let http = resp as? HTTPURLResponse
        guard (200..<300).contains(http?.statusCode ?? 0) else {
            try? FileManager.default.removeItem(at: tmp)
            throw YTError(message: "No se pudo bajar el video de tu servidor (error \(http?.statusCode ?? 0)).")
        }
        await progress(1, "Listo")
        return try move(tmp, ext: url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
    }

    /// Mueve el archivo temporal a la carpeta de videos de la app.
    private static func move(_ tmp: URL, ext: String) throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > 100_000 else {
            try? FileManager.default.removeItem(at: tmp)
            throw YTError(message: "Tu servidor devolvió un archivo vacío o demasiado pequeño.")
        }
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + "." + ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
