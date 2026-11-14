import Foundation
import UserNotifications

/// Reglas de respuesta automática a comentarios de YouTube, compartidas por la pantalla y el trabajo en segundo plano.
@MainActor
enum AutoReply {
    static let defaultTemplates = "¡Gracias por comentar, {nombre}! 🙌\nMuchas gracias por el apoyo, {nombre} 🔥\n¡Qué bueno que te gustó, {nombre}! Sígueme para más 🎶"
    static let defaultRules = "precio, cuánto, cuanto => Escríbeme por mensaje directo y te doy toda la info, {nombre} 📩\nsiguiente, parte 2, otra => ¡Viene pronto, {nombre}! Activa la campanita 🔔"
    static let defaultBlocked = "http, www., .com, gana dinero, sígueme, follow me, sub4sub"

    private static let d = UserDefaults.standard
    /// Encendida por defecto: responde sola en YouTube, Facebook e Instagram.
    static var enabled: Bool { d.object(forKey: "cs.autoReply") as? Bool ?? true }
    static var templates: [String] { lines(d.string(forKey: "cs.replyTemplates") ?? defaultTemplates) }
    static var rules: [(keys: [String], reply: String)] {
        lines(d.string(forKey: "cs.replyRules") ?? defaultRules).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let keys = parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            let reply = parts[1].trimmingCharacters(in: .whitespaces)
            return keys.isEmpty || reply.isEmpty ? nil : (keys, reply)
        }
    }
    static var blocked: [String] {
        (d.string(forKey: "cs.blockedWords") ?? defaultBlocked).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    static var skipBlocked: Bool { d.object(forKey: "cs.skipBlocked") as? Bool ?? true }

    private static func lines(_ raw: String) -> [String] {
        raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Comentarios ya respondidos desde la app (por si YouTube no devuelve la respuesta todavía).
    static var answered: Set<String> {
        get { Set(d.stringArray(forKey: "cs.answered") ?? []) }
        set { d.set(Array(newValue.suffix(2000)), forKey: "cs.answered") }
    }

    static func isSpam(_ c: YouTubeService.Comment) -> Bool {
        let t = c.text.lowercased()
        return blocked.contains { t.contains($0) }
    }

    static func name(_ c: YouTubeService.Comment) -> String {
        c.author.trimmingCharacters(in: CharacterSet(charactersIn: "@")).split(separator: " ").first.map(String.init) ?? ""
    }

    static func fill(_ template: String, _ c: YouTubeService.Comment) -> String {
        template.replacingOccurrences(of: "{nombre}", with: name(c))
    }

    /// La respuesta que se daría a este comentario, o nil si no se debe responder solo.
    static func reply(for c: YouTubeService.Comment) -> String? {
        if c.replied || answered.contains(c.id) { return nil }
        if skipBlocked && isSpam(c) { return nil }
        let t = c.text.lowercased()
        if let rule = rules.first(where: { r in r.keys.contains { t.contains($0) } }) { return fill(rule.reply, c) }
        let ts = templates
        guard !ts.isEmpty else { return nil }
        return fill(ts[abs(c.id.hashValue) % ts.count], c)
    }

    /// Responde a los pendientes. Devuelve cuántos respondió.
    @discardableResult
    static func run(_ comments: [YouTubeService.Comment], yt: YouTubeService, limit: Int = 15) async -> Int {
        await run(comments, limit: limit, network: .youtube, account: yt.channel?.title) { c, text in try await yt.reply(to: c.commentID, text: text) }
    }

    /// Responder con IA (NVIDIA NIM) cuando no aplica una regla por palabra.
    static var useAI: Bool { d.object(forKey: "cs.aiReplies") as? Bool ?? true }

    /// Regla por palabra → IA → respuesta rápida. nil = no responder.
    static func smartReply(for c: YouTubeService.Comment, network: Network, account: String?) async -> String? {
        if c.replied || answered.contains(c.id) { return nil }
        if skipBlocked && isSpam(c) { return nil }
        let t = c.text.lowercased()
        if let rule = rules.first(where: { r in r.keys.contains { t.contains($0) } }) { return fill(rule.reply, c) }
        if useAI && NIM.isConfigured {
            if let ai = try? await NIM.reply(to: c.text, author: c.author, network: network, account: account) { return ai }
            return nil   // la IA lo marcó como spam/insulto, o falló: mejor no responder a ciegas
        }
        return reply(for: c)
    }

    @discardableResult
    static func run(_ comments: [YouTubeService.Comment], limit: Int = 15, network: Network = .youtube, account: String? = nil,
                    send: (YouTubeService.Comment, String) async throws -> Void) async -> Int {
        var done = 0
        for c in comments where done < limit {
            guard let text = await smartReply(for: c, network: network, account: account) else { continue }
            do {
                try await send(c, text)
                answered.insert(c.id)
                done += 1
                try? await Task.sleep(for: .milliseconds(600))
            } catch { break }
        }
        let key = "cs.autoCount." + Date.now.formatted(.iso8601.year().month().day())
        d.set(d.integer(forKey: key) + done, forKey: key)
        return done
    }

    static var todayCount: Int { d.integer(forKey: "cs.autoCount." + Date.now.formatted(.iso8601.year().month().day())) }
}

/// Avisos en el teléfono.
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    static func send(_ title: String, _ body: String) {
        guard UserDefaults.standard.object(forKey: "cs.notify") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
