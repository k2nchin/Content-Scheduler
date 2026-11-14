import Foundation
import AVFoundation

/// IA del Clipper: el iPhone transcribe el video (gratis, sin subir el audio) y la IA de NVIDIA NIM,
/// en tu servidor de Vercel, elige los momentos con más potencial viral.
@MainActor
enum ClipAI {
    struct Result: Decodable, Hashable {
        struct Titles: Decodable, Hashable { var youtube: String; var instagram: String; var facebook: String }
        var start: Double
        var end: Double
        var score: Int
        var hook: String
        var reason: String
        var titles: Titles
        var hashtags: [String]
    }

    static var url: URL? {
        let s = (Bundle.main.object(forInfoDictionaryKey: "ClipAIURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("https://") ? URL(string: s) : nil
    }
    static var isConfigured: Bool { NIM.isConfigured || url != nil }

    /// Transcribe el video completo por partes de 50 s (el reconocimiento de voz trabaja mejor así).
    static func transcribe(_ source: URL, duration: Double, progress: (String) -> Void) async throws -> [StudioExport.Line] {
        let asset = AVURLAsset(url: source)
        var all: [StudioExport.Line] = []
        var t = 0.0
        let step = 50.0
        while t < duration {
            let end = min(duration, t + step)
            progress("Escuchando el video… \(Int(t / duration * 100))%")
            let range = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
            if let audio = try? await StudioExport.exportAudio(asset, range: range) {
                let lines = (try? await StudioExport.transcribe(audio)) ?? []
                all += lines.map { StudioExport.Line(text: $0.text, start: $0.start + t, end: $0.end + t) }
                try? FileManager.default.removeItem(at: audio)
            }
            t = end
        }
        return all
    }

    static func findClips(lines: [StudioExport.Line], duration: Double, count: Int, length: Double, token: String) async throws -> [Result] {
        guard let url else { throw YTError(message: "Falta la dirección de la IA (CLIP_AI_URL) en la configuración de la app.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 70
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "segments": lines.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
            "duration": duration, "count": count,
            "minLength": max(10, length * 0.5), "maxLength": length * 1.5, "language": "español",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw YTError(message: msg ?? "La IA respondió con error \(status).")
        }
        struct Wrap: Decodable { let clips: [Result] }
        return try JSONDecoder().decode(Wrap.self, from: data).clips
    }
}
