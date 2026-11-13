import SwiftUI
import LocalAuthentication
import UniformTypeIdentifiers

// MARK: Bloqueo con Face ID

enum AppLock {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "cs.lock") }

    static func unlock() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear Content Scheduler")) ?? false
    }
}

struct LockScreen: View {
    let onUnlock: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "faceid").font(.system(size: 54)).foregroundStyle(Theme.accent)
            Text("CONTENT SCHEDULER").font(Theme.display(24)).foregroundStyle(Theme.fg)
            Button { Task { if await AppLock.unlock() { onUnlock() } } } label: { Text("Desbloquear") }
                .buttonStyle(PrimaryButtonStyle()).frame(width: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .task { if await AppLock.unlock() { onUnlock() } }
    }
}

// MARK: Reporte semanal (lunes), solo con datos reales

@MainActor
enum WeeklyReport {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "cs.weekly") as? Bool ?? true }

    static func sendIfDue(store: AppStore, yt: YouTubeService, meta: MetaService) {
        guard enabled else { return }
        let cal = Calendar.current
        guard cal.component(.weekday, from: .now) == 2 else { return } // lunes
        let week = "\(cal.component(.yearForWeekOfYear, from: .now))-\(cal.component(.weekOfYear, from: .now))"
        guard UserDefaults.standard.string(forKey: "cs.weeklySent") != week else { return }

        var lines: [String] = []
        if let ch = yt.channel {
            var line = "YouTube (\(ch.title)): \(ch.subscribers.map { compact(Double($0)) } ?? "oculto") suscriptores"
            let weekAgo = cal.date(byAdding: .day, value: -7, to: .now)!.formatted(.iso8601.year().month().day())
            if let old = yt.snapshots.last(where: { $0.day <= weekAgo }), let now = ch.subscribers {
                let d = now - old.followers
                line += " (\(d >= 0 ? "+" : "")\(d) en la semana)"
            }
            lines.append(line)
        }
        if meta.facebookConnected, let f = meta.page?.followers { lines.append("Facebook: \(compact(Double(f))) seguidores") }
        if meta.instagramConnected, let f = meta.page?.igFollowers { lines.append("Instagram: \(compact(Double(f))) seguidores") }
        let since = Date.now.addingTimeInterval(-7 * 86_400)
        let published = store.state.posts.filter { $0.status == .published && $0.date >= since }.count
        lines.append("Publicados en la semana: \(published) · Programados: \(store.programados.count)")
        guard !lines.isEmpty else { return }
        Notifier.send("Tu semana en Content Scheduler", lines.joined(separator: "\n"))
        UserDefaults.standard.set(week, forKey: "cs.weeklySent")
    }
}

// MARK: Copia de seguridad

struct Backup: Codable {
    var state: AppState
    var settings: [String: String]
    static let keys = ["cs.replyTemplates", "cs.replyRules", "cs.blockedWords", "cs.hashtagGroups"]
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
enum BackupManager {
    static func make(_ store: AppStore) -> BackupDocument {
        var settings: [String: String] = [:]
        for k in Backup.keys { if let v = UserDefaults.standard.string(forKey: k) { settings[k] = v } }
        // Los archivos de video no van en la copia (pesan mucho); el resto sí.
        var state = store.state
        for i in state.posts.indices { state.posts[i].videoFile = nil }
        let data = (try? JSONEncoder().encode(Backup(state: state, settings: settings))) ?? Data()
        return BackupDocument(data: data)
    }

    static func restore(_ url: URL, into store: AppStore) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        store.state = backup.state
        for (k, v) in backup.settings where Backup.keys.contains(k) { UserDefaults.standard.set(v, forKey: k) }
    }
}
