import Foundation

/// Cliente del motor de clipping que corre en tu iMac (la carpeta `clipper-web`, con Docker).
///
/// El iPhone no procesa nada aquí: le manda el link al iMac, el iMac baja el video,
/// lo transcribe, la IA escoge los momentos y devuelve los clips ya cortados en 9:16
/// con subtítulos. La app se los baja y los mete en la cola de publicación.
///
/// La dirección y la clave se ponen en Ajustes → Motor de clipping.
///   POST   {servidor}/tasks/                      → {"task_id": "…"}
///   GET    {servidor}/tasks/{id}                  → estado, progreso y clips
///   GET    {servidor}/tasks/{id}/clips/{cid}/file → el archivo del clip
enum ClipEngine {

    // MARK: Configuración

    /// Dirección del motor, por ejemplo http://192.168.1.50:8000 (el iMac en tu red).
    static var server: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "clip.engine")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !saved.isEmpty { return saved }
            return (Bundle.main.object(forInfoDictionaryKey: "ClipEngineURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "clip.engine") }
    }

    /// Clave de API del motor (`sk_…`), de Ajustes → Claves de API en la web. Se guarda en el llavero.
    static var apiKey: String {
        get { Keychain.get("clip.engine.key") ?? "" }
        set { newValue.isEmpty ? Keychain.delete("clip.engine.key") : Keychain.set(newValue, for: "clip.engine.key") }
    }

    static var isConfigured: Bool {
        guard let u = URL(string: server), let s = u.scheme, s == "http" || s == "https" else { return false }
        return !apiKey.isEmpty
    }

    // MARK: Lo que devuelve el motor

    struct Clip: Identifiable, Hashable {
        let id: String
        let filename: String
        /// El título de gancho que escribió la IA, el que va quemado arriba los primeros segundos.
        let hookTitle: String
        /// Lo que se dice en el clip, para usarlo de descripción.
        let text: String
        let start: Double
        let end: Double
        let duration: Double
        /// 0 a 100. Cuanto más alto, más posibilidades le ve la IA.
        let virality: Int
        /// El desglose, 0 a 25 cada uno: gancho, enganche, valor y ganas de compartirlo.
        let hook: Int
        let engagement: Int
        let value: Int
        let shareable: Int
        /// En una serie: «Parte 2 de 5». Vacío en los demás modos.
        let partNumber: Int
    }

    /// Un modo de corte de los que sabe hacer el motor.
    struct Workflow: Identifiable, Hashable {
        let id: String
        let available: Bool
        /// Segundos mínimos que tiene que durar el video para este modo.
        let minSeconds: Int

        var name: String {
            switch id {
            case "series": return "Serie"
            case "topic": return "Por tema"
            case "recap": return "Resumen"
            case "trailer": return "Tráiler"
            default: return "Los mejores momentos"
            }
        }
        var detail: String {
            switch id {
            case "series": return "Una historia partida en capítulos: Parte 1, Parte 2…"
            case "topic": return "Solo los momentos que hablen de lo que tú digas."
            case "recap": return "Un clip con lo esencial de todo el video."
            case "trailer": return "Un adelanto que engancha sin destripar el final."
            default: return "La IA busca los momentos con más posibilidades."
            }
        }
        var icon: String {
            switch id {
            case "series": return "square.stack"
            case "topic": return "magnifyingglass"
            case "recap": return "text.alignleft"
            case "trailer": return "sparkles"
            default: return "star"
            }
        }
    }

    /// Una plantilla de subtítulos del motor.
    struct CaptionTemplate: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let animation: String
    }

    struct Status {
        /// `queued`, `processing`, `completed`, `error` o `cancelled`.
        let state: String
        /// De 0 a 1.
        let progress: Double
        let message: String
        let clips: [Clip]
        var isDone: Bool { state == "completed" }
        var isFailed: Bool { state == "error" || state == "cancelled" }
    }

    /// Cómo quieres los clips. Los valores son los que entiende el motor.
    struct Options {
        var subtitles = true
        /// `vertical`, `vertical_fit`, `vertical_pan`, `vertical_split` u `original`.
        var format = "vertical" {
            didSet {
                let buenos = ["vertical", "vertical_fit", "vertical_pan", "vertical_split", "original"]
                if !buenos.contains(format) { format = "vertical" }
            }
        }
        /// `fast`, `balanced` o `quality`.
        var mode = "balanced"
        /// `auto`, `short` (15-30 s), `medium` (30-60 s) o `long` (1-2 min).
        var length = "auto" {
            didSet { if !["auto", "short", "medium", "long"].contains(length) { length = "auto" } }
        }
        var captionTemplate = "default"
        var broll = false
        /// Vacío = los mejores momentos. Si pones texto, la IA corta siguiendo esa instrucción.
        var instructions = ""
        /// `highlights`, `series`, `topic`, `recap` o `trailer`.
        var workflow = "highlights"
        /// Solo en `topic`: de qué tiene que hablar el clip.
        var topic = ""
        /// Solo en `series`: cuántas partes.
        var partCount = 3
    }

    // MARK: Llamadas

    private static func url(_ path: String) throws -> URL {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard let u = URL(string: base + path) else {
            throw YTError(message: "La dirección del motor de clipping no es válida. Revísala en Ajustes.")
        }
        return u
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard isConfigured else {
            throw YTError(message: "Pon la dirección y la clave de tu motor de clipping en Ajustes.")
        }
        var r = URLRequest(url: try url(path))
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func json(_ r: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            // Si no vino JSON, al menos se enseña lo que haya respondido.
            if obj.isEmpty, let crudo = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !crudo.isEmpty, crudo.count < 300 {
                throw YTError(message: "Tu motor dijo: \(crudo)")
            }
            throw error(code, obj)
        }
        return obj
    }

    /// Traduce los errores del motor a algo que se entienda.
    private static func error(_ code: Int, _ obj: [String: Any]) -> YTError {
        if let m = motivo(obj["detail"]) ?? motivo(obj["message"]) ?? motivo(obj["error"]) {
            return YTError(message: m)
        }
        switch code {
        case 401, 403: return YTError(message: "Tu motor de clipping rechazó la clave. Genera otra en la web y pégala en Ajustes.")
        case 404: return YTError(message: "El motor de clipping no encontró eso. ¿Está encendido el iMac?")
        case 0: return YTError(message: "No se pudo hablar con tu motor de clipping. Comprueba que el iMac esté encendido y en la misma red.")
        default: return YTError(message: "Tu motor de clipping respondió con error \(code).")
        }
    }

    /// Saca el texto de un «detail», venga como venga: texto, objeto o lista.
    private static func motivo(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let d = v as? [String: Any] {
            for k in ["message", "detail", "msg", "error", "reason"] {
                if let m = motivo(d[k]) { return m }
            }
        }
        // Los errores de validación llegan como una lista de objetos.
        if let lista = v as? [Any] {
            let textos = lista.compactMap { motivo($0) }
            if !textos.isEmpty { return textos.joined(separator: ". ") }
        }
        return nil
    }

    /// Manda el link y devuelve el identificador del trabajo.
    static func start(_ link: String, options: Options = Options()) async throws -> String {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: clean), let s = u.scheme, s == "http" || s == "https" else {
            throw YTError(message: "Pega un link válido de YouTube, Twitch o Kick.")
        }
        var body: [String: Any] = [
            "source": ["url": clean],
            "add_subtitles": options.subtitles,
            "output_format": options.format,
            "processing_mode": options.mode,
            "clip_length": options.length,
            "caption_template": options.captionTemplate,
            "include_broll": options.broll,
        ]
        // El motor corta en 500 y 120; se recorta aquí para que no rebote la petición.
        if !options.instructions.isEmpty { body["instructions"] = String(options.instructions.prefix(500)) }
        if options.workflow != "highlights" {
            body["workflow"] = options.workflow
            var wo: [String: Any] = [:]
            if options.workflow == "topic" { wo["topic"] = String(options.topic.prefix(120)) }
            if options.workflow == "series" { wo["part_count"] = min(10, max(2, options.partCount)) }
            if !wo.isEmpty { body["workflow_options"] = wo }
        }
        let obj = try await json(try request("/tasks/", method: "POST", body: body))
        guard let id = obj["task_id"] as? String else {
            throw YTError(message: "Tu motor de clipping no devolvió el trabajo.")
        }
        return id
    }

    /// Cómo va el trabajo y qué clips hay ya.
    static func status(_ taskID: String) async throws -> Status {
        let obj = try await json(try request("/tasks/\(taskID)"))
        let raw = (obj["progress"] as? Double) ?? Double((obj["progress"] as? Int) ?? 0)
        let list = (obj["clips"] as? [[String: Any]]) ?? []
        let clips = list.compactMap(parseClip)
        return Status(
            state: (obj["status"] as? String) ?? "processing",
            // El motor cuenta de 0 a 100, nunca de 0 a 1.
            progress: min(1, max(0, raw / 100)),
            message: (obj["progress_message"] as? String) ?? "",
            clips: ordenar(clips)
        )
    }

    /// Una serie se lee por capítulos; lo demás, por nota.
    private static func ordenar(_ clips: [Clip]) -> [Clip] {
        if clips.contains(where: { $0.partNumber > 0 }) {
            return clips.sorted { $0.partNumber < $1.partNumber }
        }
        return clips.sorted { $0.virality > $1.virality }
    }

    private static func parseClip(_ c: [String: Any]) -> Clip? {
        guard let id = c["id"] as? String else { return nil }
        let start = number(c["start_time"])
        let end = number(c["end_time"])
        let dur = number(c["duration"])
        return Clip(
            id: id,
            filename: (c["filename"] as? String) ?? "clip.mp4",
            hookTitle: (c["hook_title"] as? String) ?? "",
            text: (c["text"] as? String) ?? "",
            start: start,
            end: end,
            duration: dur > 0 ? dur : max(0, end - start),
            virality: Int(number(c["virality_score"]).rounded()),
            hook: Int(number(c["hook_score"]).rounded()),
            engagement: Int(number(c["engagement_score"]).rounded()),
            value: Int(number(c["value_score"]).rounded()),
            shareable: Int(number(c["shareability_score"]).rounded()),
            partNumber: Int(number(c["part_number"]).rounded())
        )
    }

    private static func number(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String {
            if let d = Double(s) { return d }
            // El motor manda los tiempos como «MM:SS» o «HH:MM:SS».
            let partes = s.split(separator: ":").compactMap { Double($0) }
            if partes.count >= 2 {
                return partes.reduce(0) { $0 * 60 + $1 }
            }
        }
        return 0
    }

    /// Espera a que termine, avisando del progreso. Devuelve los clips.
    /// Pregunta cada 3 segundos; si el iMac tarda, sigue esperando mientras siga respondiendo.
    /// Espera a que termine, avisando del progreso y de los clips que ya hay.
    /// El motor guarda cada clip en cuanto lo corta, así que `parciales` trae
    /// los que ya están listos: se pueden ver y publicar sin esperar al resto.
    static func wait(_ taskID: String, onProgress: @escaping @MainActor (Double, String, [Clip]) -> Void) async throws -> [Clip] {
        var fallos = 0
        while !Task.isCancelled {
            do {
                let s = try await status(taskID)
                fallos = 0
                await onProgress(s.progress, s.message.isEmpty ? "Tu iMac está trabajando…" : s.message, s.clips)
                if s.isDone { return s.clips }
                if s.isFailed {
                    throw YTError(message: s.message.isEmpty ? "El motor de clipping no pudo con ese video." : s.message)
                }
            } catch let e as YTError {
                throw e
            } catch {
                // Un corte de red no tira el trabajo: el iMac sigue cortando.
                fallos += 1
                if fallos >= 20 {
                    throw YTError(message: "Se perdió la conexión con tu iMac. El trabajo sigue allá; vuelve a entrar más tarde.")
                }
                await onProgress(-1, "Reconectando con tu iMac…", [])
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw CancellationError()
    }

    /// Baja un clip ya cortado y lo guarda en la app.
    static func download(task taskID: String, clip: Clip) async throws -> URL {
        let r = try request("/tasks/\(taskID)/clips/\(clip.id)/file?download=true")
        let (tmp, resp) = try await URLSession.shared.download(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: tmp)
            let obj = (try? Data(contentsOf: tmp)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            throw error(code, obj)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard size > 50_000 else {
            try? FileManager.default.removeItem(at: tmp)
            throw YTError(message: "Ese clip llegó vacío desde tu iMac.")
        }
        let ext = (clip.filename as NSString).pathExtension.isEmpty ? "mp4" : (clip.filename as NSString).pathExtension
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + "." + ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Un trabajo anterior, para poder volver a él.
    struct Job: Identifiable, Hashable {
        let id: String
        /// De dónde salió, para reconocerlo en la lista.
        let source: String
        let status: String
        let clips: Int
        let date: Date?

        var done: Bool { status == "completed" }
        var working: Bool { status == "processing" || status == "queued" }
        var failed: Bool { status == "error" || status == "cancelled" }
    }

    /// El trabajo que quedó a medias al cerrar la app, si lo hubo.
    static var pending: String {
        get { UserDefaults.standard.string(forKey: "clip.engine.task") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "clip.engine.task") }
    }

    /// Los últimos trabajos del motor, los de ahora y los de antes.
    static func jobs(limit: Int = 15) async throws -> [Job] {
        let obj = try await json(try request("/tasks/?limit=\(limit)"))
        let lista = (obj["tasks"] as? [[String: Any]]) ?? []
        let fechas = ISO8601DateFormatter()
        fechas.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return lista.compactMap { j in
            guard let id = j["id"] as? String else { return nil }
            let cuando = (j["created_at"] as? String) ?? ""
            return Job(id: id,
                       source: (j["source_title"] as? String) ?? (j["source_url"] as? String) ?? "Video",
                       status: (j["status"] as? String) ?? "",
                       clips: Int(number(j["clips_count"])),
                       date: fechas.date(from: cuando) ?? ISO8601DateFormatter().date(from: cuando))
        }
    }

    // MARK: Directos

    /// Un directo que el iMac está grabando y clipeando por trozos.
    struct Live: Identifiable {
        let id: String
        let url: String
        /// `pedido`, `grabando`, `parando`, `terminado` o `error`.
        let status: String
        let chunks: Int
        let minutes: Int
        let error: String?

        var isRunning: Bool { status == "pedido" || status == "grabando" || status == "parando" }
        var rotulo: String {
            switch status {
            case "pedido": return "Esperando al iMac"
            case "grabando": return chunks == 0 ? "Grabando el primer trozo" : "Grabando · \(chunks) trozos clipeados"
            case "parando": return "Cerrando el último trozo"
            case "error": return error ?? "Falló"
            default: return chunks == 0 ? "Terminado" : "Terminado · \(chunks) trozos"
            }
        }
    }

    private static func parseLive(_ d: [String: Any]) -> Live? {
        guard let id = d["id"] as? String else { return nil }
        return Live(id: id,
                    url: (d["url"] as? String) ?? "",
                    status: (d["status"] as? String) ?? "pedido",
                    chunks: Int(number(d["chunks_sent"])),
                    minutes: Int(number(d["chunk_minutes"])),
                    error: d["error_message"] as? String)
    }

    /// Encarga al iMac que grabe un directo y lo vaya clipeando mientras sigue en vivo.
    ///
    /// El teléfono no graba nada: solo deja el encargo apuntado. El iMac lo
    /// recoge, graba por trozos y cada trozo entra como un trabajo normal, así
    /// que los clips van apareciendo sin esperar a que el directo acabe.
    static func startLive(_ link: String, minutesPerChunk: Int = 10, options: Options = Options()) async throws -> Live {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: clean), let s = u.scheme, s == "http" || s == "https" else {
            throw YTError(message: "Pega el link del directo: youtube.com/@canal/live, twitch.tv/canal o kick.com/canal.")
        }
        let body: [String: Any] = [
            "url": clean,
            "chunk_minutes": min(30, max(2, minutesPerChunk)),
            "options": [
                "add_subtitles": options.subtitles,
                "output_format": options.format,
                "processing_mode": options.mode,
                "clip_length": options.length,
                "caption_template": options.captionTemplate,
                "include_broll": options.broll,
            ],
        ]
        guard let live = parseLive(try await json(try request("/lives/", method: "POST", body: body))) else {
            throw YTError(message: "Tu motor no devolvió el directo.")
        }
        return live
    }

    /// Los directos de este motor, el de ahora y los de antes.
    static func lives() async throws -> [Live] {
        let obj = try await json(try request("/lives/"))
        return ((obj["lives"] as? [[String: Any]]) ?? []).compactMap(parseLive)
    }

    /// Pide parar. El trozo que estaba a medias se manda igual antes de cerrar.
    static func stopLive(_ id: String) async throws -> Live? {
        parseLive(try await json(try request("/lives/\(id)/stop", method: "POST")))
    }

    /// Los modos de corte que este motor permite. Si falla, al menos están los highlights.
    static func workflows() async throws -> [Workflow] {
        let obj = try await json(try request("/tasks/workflows"))
        let list = (obj["workflows"] as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard let id = w["id"] as? String else { return nil }
            return Workflow(id: id,
                            available: (w["available"] as? Bool) ?? false,
                            minSeconds: Int(number(w["min_source_seconds"])))
        }
    }

    /// Las plantillas de subtítulos que trae el motor.
    static func captionTemplates() async throws -> [CaptionTemplate] {
        let obj = try await json(try request("/caption-templates"))
        let list = (obj["templates"] as? [[String: Any]]) ?? []
        return list.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return CaptionTemplate(id: id,
                                   name: (c["name"] as? String) ?? id,
                                   detail: (c["description"] as? String) ?? "",
                                   animation: (c["animation"] as? String) ?? "none")
        }
    }

    // MARK: Estudio — retocar los clips en el iMac

    /// Recorta por los extremos y vuelve a renderizar. Los dos valores son segundos a quitar.
    @discardableResult
    static func trim(task: String, clip: String, start: Double, end: Double) async throws -> Clip? {
        let obj = try await json(try request("/tasks/\(task)/clips/\(clip)",
                                             method: "PATCH",
                                             body: ["start_offset": max(0, start), "end_offset": max(0, end)]))
        return (obj["clip"] as? [String: Any]).flatMap(parseClip)
    }

    /// Parte el clip en dos por ese segundo, contando desde su principio.
    static func split(task: String, clip: String, at seconds: Double) async throws {
        guard seconds > 0 else { throw YTError(message: "Elige un punto después del principio.") }
        _ = try await json(try request("/tasks/\(task)/clips/\(clip)/split",
                                       method: "POST", body: ["split_time": seconds]))
    }

    /// Junta varios clips en uno solo, en el orden que se le pasen.
    static func merge(task: String, clips: [String]) async throws {
        guard clips.count >= 2 else { throw YTError(message: "Elige al menos dos clips para juntarlos.") }
        _ = try await json(try request("/tasks/\(task)/clips/merge",
                                       method: "POST", body: ["clip_ids": clips]))
    }

    /// Reescribe los subtítulos a mano, con su tamaño, posición y palabras resaltadas.
    /// `position` solo puede ser `top`, `middle` o `bottom`.
    static func captions(task: String, clip: String, text: String,
                         position: String = "bottom", size: Int? = nil,
                         highlight: [String] = []) async throws {
        let sitio = ["top", "middle", "bottom"].contains(position) ? position : "bottom"
        var body: [String: Any] = ["caption_text": text, "position": sitio, "highlight_words": highlight]
        if let size { body["font_size"] = min(72, max(12, size)) }
        _ = try await json(try request("/tasks/\(task)/clips/\(clip)/captions", method: "PATCH", body: body))
    }

    /// Baja el clip con los ajustes de una red: `tiktok`, `reels` o `shorts`.
    static func export(task: String, clip: Clip, preset: String) async throws -> URL {
        let r = try request("/tasks/\(task)/clips/\(clip.id)/export?preset=\(preset)")
        let (tmp, resp) = try await URLSession.shared.download(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: tmp)
            throw error(code, [:])
        }
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + ".mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Borra un clip del trabajo.
    static func delete(task: String, clip: String) async throws {
        _ = try await json(try request("/tasks/\(task)/clips/\(clip)", method: "DELETE"))
    }

    /// La dirección para ver el clip sin bajarlo, ya con la clave puesta.
    static func streamRequest(task: String, clip: String) -> URLRequest? {
        try? request("/tasks/\(task)/clips/\(clip)/file")
    }

    /// Comprueba que el iMac contesta y que la clave sirve.
    static func check() async throws {
        _ = try await json(try request("/tasks/"))
    }
}
