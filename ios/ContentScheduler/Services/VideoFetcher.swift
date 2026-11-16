import Foundation

/// Trae un video desde tu propio servidor a partir de un link.
/// La app no descarga de YouTube ni de ninguna plataforma: solo le pide el archivo a tu servidor.
///
/// Contrato que tiene que cumplir tu servidor:
///   POST {servidor}/fetch   body: {"url": "https://…"}
///   Respuesta A: el archivo de video (Content-Type: video/*)
///   Respuesta B: {"video_url": "https://…"}  → la app lo baja de ahí
///   Error:       {"error": "texto"}
@MainActor
enum VideoFetcher {
    /// Dirección del servidor: se pone en Ajustes y se puede cambiar sin recompilar.
    static var server: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "clip.server")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !saved.isEmpty { return saved }
            return (Bundle.main.object(forInfoDictionaryKey: "ClipServerURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "clip.server") }
    }
    static var isConfigured: Bool { URL(string: server)?.scheme?.hasPrefix("http") == true }

    private static func endpoint() throws -> URL {
        guard var base = URLComponents(string: server), base.scheme != nil else {
            throw YTError(message: "Pon la dirección de tu servidor en Ajustes → Servidor de videos.")
        }
        if !base.path.contains("fetch") {
            base.path = base.path.hasSuffix("/") ? base.path + "fetch" : base.path + "/fetch"
        }
        guard let u = base.url else { throw YTError(message: "Esa dirección de servidor no es válida.") }
        return u
    }

    /// Pide el video y lo guarda en la app. `progress` va de 0 a 1 (−1 si el servidor no dice el tamaño).
    static func fetch(_ link: String, progress: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: clean), u.scheme?.hasPrefix("http") == true else {
            throw YTError(message: "Pega un link válido.")
        }
        progress(-1, "Pidiéndole el video a tu servidor…")
        var req = URLRequest(url: try endpoint())
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["url": clean])

        let (stream, resp) = try await URLSession.shared.bytes(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // Respuesta en JSON: o es un error, o trae la dirección del video
        if type.contains("json") || !(200..<300).contains(status) {
            var data = Data()
            for try await b in stream { data.append(b) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let msg = json["error"] as? String { throw YTError(message: "Tu servidor: \(msg)") }
            guard (200..<300).contains(status) else {
                throw YTError(message: "Tu servidor respondió con error \(status).")
            }
            guard let s = (json["video_url"] ?? json["url"]) as? String, let vu = URL(string: s) else {
                throw YTError(message: "Tu servidor no devolvió el video.")
            }
            return try await download(vu, progress: progress)
        }

        // El servidor manda el archivo directo
        return try await save(stream, expected: http?.expectedContentLength ?? -1,
                              ext: type.contains("quicktime") ? "mov" : "mp4", progress: progress)
    }

    private static func download(_ url: URL, progress: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        progress(0, "Bajando el video…")
        let (stream, resp) = try await URLSession.shared.bytes(from: url)
        let http = resp as? HTTPURLResponse
        guard (200..<300).contains(http?.statusCode ?? 0) else {
            throw YTError(message: "No se pudo bajar el video de tu servidor (error \(http?.statusCode ?? 0)).")
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return try await save(stream, expected: http?.expectedContentLength ?? -1, ext: ext, progress: progress)
    }

    private static func save(_ stream: URLSession.AsyncBytes, expected: Int64, ext: String,
                             progress: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + "." + ext)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            throw YTError(message: "No se pudo guardar el video en el iPhone.")
        }
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 20)
        var got: Int64 = 0
        var lastShown = Date.distantPast
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                got += Int64(buffer.count)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if Date.now.timeIntervalSince(lastShown) > 0.3 {
                    lastShown = .now
                    let mb = Double(got) / 1_048_576
                    if expected > 0 {
                        progress(Double(got) / Double(expected), String(format: "Bajando… %.0f MB de %.0f MB", mb, Double(expected) / 1_048_576))
                    } else {
                        progress(-1, String(format: "Bajando… %.0f MB", mb))
                    }
                }
            }
        }
        if !buffer.isEmpty { got += Int64(buffer.count); try handle.write(contentsOf: buffer) }
        guard got > 100_000 else {
            try? FileManager.default.removeItem(at: dest)
            throw YTError(message: "Tu servidor devolvió un archivo vacío o demasiado pequeño.")
        }
        progress(1, "Listo")
        return dest
    }
}
