import Foundation
import UIKit

/// Funciones de IA (NVIDIA NIM) de la app: portada, gancho, subtítulos, textos, horarios, ideas y comentarios.
@MainActor
extension NIM {
    // MARK: Utilidades

    private static func json(_ raw: String, open: Character = "{", close: Character = "}") -> Data? {
        guard let a = raw.firstIndex(of: open), let b = raw.lastIndex(of: close), a < b else { return nil }
        return Data(raw[a...b].utf8)
    }

    // MARK: 1. Mejor portada (modelo con visión)

    /// Devuelve el índice del fotograma más llamativo para usar de portada.
    static func bestFrame(_ frames: [UIImage]) async throws -> Int {
        guard frames.count > 1 else { return 0 }
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "Estas son \(frames.count) imágenes numeradas del 1 al \(frames.count) de un video para redes sociales. ¿Cuál sirve mejor como portada (miniatura)? Prioriza: cara visible con expresión fuerte, nitidez, buena luz y que llame la atención. Responde SOLO con el número.",
        ]]
        for img in frames {
            let small = img.preparingThumbnail(of: CGSize(width: 512, height: 512 * img.size.height / max(img.size.width, 1))) ?? img
            guard let jpg = small.jpegData(compressionQuality: 0.6) else { continue }
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpg.base64EncodedString()]])
        }
        let raw = try await chat(.vision, system: "Eres editor de miniaturas para YouTube e Instagram.", content: content, maxTokens: 300, temperature: 0)
        let n = Int(raw.filter(\.isNumber).prefix(2)) ?? 1
        return max(0, min(frames.count - 1, n - 1))
    }

    // MARK: 2. Gancho en pantalla

    /// Frase corta para los primeros segundos del clip.
    static func hook(for transcript: String) async throws -> String {
        let system = """
        Escribe un gancho para poner como texto grande en los primeros 3 segundos de un video corto (Shorts/Reels).
        Máximo 6 palabras, que dé curiosidad sin mentir sobre el contenido. En el idioma del video. Puede llevar 1 emoji.
        \(tone == "dominicano" ? "Si queda natural, con sabor dominicano." : "")
        Responde SOLO con el gancho, sin comillas.
        """
        let raw = try await chat(.write, system: system, user: String(transcript.prefix(4000)), maxTokens: 300, temperature: 0.8)
        return String(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”").union(.whitespacesAndNewlines)).prefix(60))
    }

    // MARK: 3. Subtítulos corregidos

    /// Corrige ortografía, nombres y jerga de las frases sin cambiar cuántas son.
    static func fixSubtitles(_ lines: [StudioExport.Line]) async throws -> [StudioExport.Line] {
        guard !lines.isEmpty else { return lines }
        let numbered = lines.enumerated().map { "\($0.offset)|\($0.element.text)" }.joined(separator: "\n")
        let system = """
        Corrige estas líneas de subtítulos transcritas automáticamente: ortografía, acentos, puntuación, nombres propios y jerga
        (incluida jerga dominicana como «klk», «tamo», «vaina»). No cambies el sentido ni agregues palabras.
        Devuelve SOLO un JSON con este formato: {"lines":["texto 0","texto 1",...]} con exactamente \(lines.count) elementos, en el mismo orden.
        """
        let raw = try await chat(.write, system: system, user: numbered, maxTokens: 4000, temperature: 0.1)
        struct Wrap: Decodable { let lines: [String] }
        guard let data = json(raw), let w = try? JSONDecoder().decode(Wrap.self, from: data), w.lines.count == lines.count else { return lines }
        return zip(lines, w.lines).map { l, t in
            let fixed = t.trimmingCharacters(in: .whitespaces)
            let fw = fixed.split(separator: " ").map(String.init)
            let words = fw.count == l.words.count ? zip(l.words, fw).map { StudioExport.Word(text: $1, start: $0.start, end: $0.end) } : l.words
            return StudioExport.Line(text: fixed.isEmpty ? l.text : fixed, start: l.start, end: l.end, words: fixed.isEmpty ? l.words : words)
        }
    }

    // MARK: 4. Título, descripción y hashtags por red

    struct PostText: Decodable {
        var title: String
        var youtube: String?
        var instagram: String?
        var facebook: String?
        var hashtags: [String]?
    }

    static func writePost(transcript: String, currentTitle: String, networks: [Network]) async throws -> PostText {
        let system = """
        Eres experto en redes sociales. Con lo que se dice en el video, escribe:
        - "title": título principal (máx. 80 caracteres).
        - "youtube": título para YouTube Shorts (máx. 90, con gancho).
        - "instagram": texto para Instagram Reels (1-2 frases + llamada a la acción).
        - "facebook": texto para Facebook (1-2 frases, cercano).
        - "hashtags": 8-12 hashtags reales (amplios, de nicho y del tema), sin espacios.
        Redes de este post: \(networks.map(\.name).joined(separator: ", ")). En el idioma del video.
        \(tone == "dominicano" ? "Con estilo de creador dominicano, natural." : "")
        Responde SOLO con JSON: {"title":"","youtube":"","instagram":"","facebook":"","hashtags":["#a"]}
        """
        let user = "Título actual: \(currentTitle)\nLo que se dice en el video:\n\(transcript.prefix(6000))"
        let raw = try await chat(.write, system: system, user: user, maxTokens: 1500, temperature: 0.6)
        guard let data = json(raw), var p = try? JSONDecoder().decode(PostText.self, from: data) else {
            throw YTError(message: "La IA no devolvió un texto válido. Inténtalo otra vez.")
        }
        p.hashtags = p.hashtags?.map { "#" + $0.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "") }.filter { $0.count > 2 }
        return p
    }

    // MARK: 5. Mejor hora con IA · 6. Ideas de contenido

    static func timeAdvice(hours: [YouTubeService.HourStat], videos: [YouTubeService.TopVideo]) async throws -> String {
        let h = hours.map { String(format: "%02d:00 → %.0f vistas promedio (%d videos)", $0.hour, $0.avgViews, $0.videos) }.joined(separator: "\n")
        let v = videos.prefix(25).map { "\($0.views) vistas · \($0.date.formatted(.dateTime.weekday(.abbreviated).hour())) · \($0.title)" }.joined(separator: "\n")
        let system = """
        Eres analista de YouTube. Con estos datos REALES de un canal, da 3 recomendaciones concretas de cuándo publicar
        (días y horas) y qué tipo de video en cada horario. No inventes números que no estén en los datos. Corto, en viñetas, en español.
        """
        return try await chat(.analysis, system: system, user: "Por hora:\n\(h)\n\nVideos:\n\(v)", maxTokens: 1500, temperature: 0.4)
    }

    static func ideas(videos: [YouTubeService.TopVideo]) async throws -> [String] {
        let v = videos.prefix(30).map { "\($0.views) vistas · \($0.title)" }.joined(separator: "\n")
        let system = """
        Eres estratega de contenido. Mira qué videos de este canal funcionaron mejor y peor (datos reales) y propone 5 ideas
        de videos nuevos que aprovechen lo que funciona. Cada idea en una línea: título tentativo + por qué. En español.
        Responde SOLO con JSON: {"ideas":["...","..."]}
        """
        let raw = try await chat(.analysis, system: system, user: v, maxTokens: 1500, temperature: 0.7)
        struct Wrap: Decodable { let ideas: [String] }
        guard let data = json(raw), let w = try? JSONDecoder().decode(Wrap.self, from: data) else { return [raw] }
        return w.ideas
    }

    // MARK: 7. Clasificar comentarios · 8. Resumen

    enum Kind: String, CaseIterable { case pregunta, elogio, critica, colaboracion, spam, otro
        var label: String {
            switch self {
            case .pregunta: "Pregunta"
            case .elogio: "Elogio"
            case .critica: "Crítica"
            case .colaboracion: "Colaboración"
            case .spam: "Spam"
            case .otro: "Otro"
            }
        }
        /// Estos no se responden solos: te los deja a ti.
        var needsYou: Bool { self == .pregunta || self == .colaboracion || self == .critica }
    }

    /// Clasificaciones guardadas (id del comentario → tipo).
    static var kinds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "nim.kinds") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue.count > 3000 ? [:] : newValue, forKey: "nim.kinds") }
    }

    static func kind(of id: String) -> Kind? { kinds[id].flatMap(Kind.init(rawValue:)) }

    /// Clasifica los comentarios que aún no tienen tipo (en grupos de 40).
    static func classify(_ comments: [YouTubeService.Comment]) async throws {
        var current = kinds
        let todo = comments.filter { current[$0.id] == nil }
        for start in stride(from: 0, to: todo.count, by: 40) {
            let chunk = Array(todo[start..<min(start + 40, todo.count)])
            let list = chunk.enumerated().map { "\($0.offset)|\($0.element.text.replacingOccurrences(of: "\n", with: " ").prefix(300))" }.joined(separator: "\n")
            let system = """
            Clasifica cada comentario de redes sociales en uno de: pregunta, elogio, critica, colaboracion, spam, otro.
            «colaboracion» = propuestas de negocio, colaboraciones, contrataciones o booking. «pregunta» = pregunta real que necesita respuesta.
            Responde SOLO con JSON: {"k":["elogio","pregunta",...]} con exactamente \(chunk.count) elementos en el mismo orden.
            """
            let raw = try await chat(.analysis, system: system, user: list, maxTokens: 1500, temperature: 0)
            struct Wrap: Decodable { let k: [String] }
            guard let data = json(raw), let w = try? JSONDecoder().decode(Wrap.self, from: data), w.k.count == chunk.count else { continue }
            for (c, k) in zip(chunk, w.k) where Kind(rawValue: k.lowercased()) != nil { current[c.id] = k.lowercased() }
        }
        kinds = current
    }

    static func summary(_ comments: [YouTubeService.Comment]) async throws -> String {
        let list = comments.prefix(80).map { "- \($0.text.replacingOccurrences(of: "\n", with: " ").prefix(200))" }.joined(separator: "\n")
        let system = """
        Resume en 3-5 viñetas cortas qué está diciendo la gente en estos comentarios: qué piden, qué les gusta, qué critican
        y si hay oportunidades (colaboraciones, preguntas repetidas). Solo con lo que está en los comentarios. En español.
        """
        return try await chat(.analysis, system: system, user: list, maxTokens: 1200, temperature: 0.3)
    }
}

// MARK: 9. Aprender tu estilo

/// Guarda cómo respondes tú a mano para que la IA imite tu forma de hablar.
enum StyleMemory {
    struct Pair: Codable { let comment: String; let reply: String }
    static var pairs: [Pair] {
        get { (UserDefaults.standard.data(forKey: "nim.style")).flatMap { try? JSONDecoder().decode([Pair].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(30))), forKey: "nim.style") }
    }
    static func add(comment: String, reply: String) {
        guard !reply.isEmpty else { return }
        pairs.append(Pair(comment: String(comment.prefix(200)), reply: String(reply.prefix(300))))
    }
    /// Ejemplos para el prompt (los más recientes).
    static var examples: String {
        let p = pairs.suffix(8)
        guard !p.isEmpty else { return "" }
        return "Así respondes tú normalmente (imita este estilo, no copies):\n" + p.map { "«\($0.comment)» → «\($0.reply)»" }.joined(separator: "\n")
    }
}
