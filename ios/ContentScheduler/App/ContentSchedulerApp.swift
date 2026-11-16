import SwiftUI
import BackgroundTasks

@main
struct ContentSchedulerApp: App {
    @State private var store = AppStore()
    @State private var youtube = YouTubeService()
    @State private var meta = MetaService()
    @Environment(\.scenePhase) private var phase

    static let refreshID = "com.contentscheduler.app.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(youtube)
                .environment(meta)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    NotificationRouter.shared.start()
                    _ = await Notifier.requestPermission()
                    await Self.sync(store: store, yt: youtube, meta: meta)
                }
                .onChange(of: phase) { _, new in
                    if new == .active { Task { await Self.sync(store: store, yt: youtube, meta: meta) } }
                    if new == .background { Self.scheduleRefresh() }
                }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            Self.scheduleRefresh()
            await Self.backgroundWork(store: store, yt: youtube, meta: meta)
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date.now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Con la app cerrada: revisa estados de YouTube, comentarios nuevos y responde solo si está activado.
    @MainActor
    static func sync(store: AppStore, yt: YouTubeService, meta: MetaService) async {
        var c: Set<Network> = []
        if yt.isConnected { c.insert(.youtube) }
        if meta.facebookConnected { c.insert(.facebook) }
        if meta.instagramConnected { c.insert(.instagram) }
        store.connected = c
        await Publisher.refresh(store: store, yt: yt)
        await meta.refresh()
        await Publisher.publishDue(store: store, meta: meta)
        WeeklyReport.sendIfDue(store: store, yt: yt, meta: meta)
        let done = await autoReplyAll(yt: yt, meta: meta)
        let total = done.values.reduce(0, +)
        if total > 0 { store.show("Respondí \(total) \(total == 1 ? "comentario" : "comentarios") automáticamente") }
    }

    /// Responde solo los comentarios pendientes de YouTube, Facebook e Instagram. Devuelve cuántos respondió en cada red.
    @MainActor
    static func autoReplyAll(yt: YouTubeService, meta: MetaService) async -> [Network: Int] {
        guard AutoReply.enabled else { return [:] }
        var done: [Network: Int] = [:]
        if yt.isConnected, let list = try? await yt.comments() {
            await flagImportant(list, network: .youtube)
            done[.youtube] = await AutoReply.run(list, yt: yt)
        }
        for n in [Network.facebook, .instagram] where (n == .facebook ? meta.facebookConnected : meta.instagramConnected) {
            if let list = try? await meta.comments(n) {
                await flagImportant(list, network: n)
                let acc = n == .facebook ? meta.page?.name : meta.page?.igUsername
                done[n] = await AutoReply.run(list, network: n, account: acc) { c, text in try await meta.reply(n, to: c.commentID, text: text) }
            }
        }
        return done.filter { $0.value > 0 }
    }

    /// Clasifica con IA y te avisa de preguntas y colaboraciones nuevas (esas no se responden solas).
    @MainActor
    static func flagImportant(_ list: [YouTubeService.Comment], network: Network) async {
        guard NIM.isConfigured else { return }
        let pending = list.filter { !$0.replied && !AutoReply.answered.contains($0.id) }
        let before = Set(pending.filter { NIM.kind(of: $0.id) != nil }.map(\.id))
        try? await NIM.classify(pending)
        let fresh = pending.filter { !before.contains($0.id) }
        let collab = fresh.filter { NIM.kind(of: $0.id) == .colaboracion }.count
        let questions = fresh.filter { NIM.kind(of: $0.id) == .pregunta }.count
        if collab > 0 { Notifier.send("💼 Posible colaboración en \(network.name)", "Tienes \(collab) \(collab == 1 ? "comentario" : "comentarios") de colaboración o negocio para responder tú.") }
        if questions > 0 { Notifier.send("❓ Preguntas en \(network.name)", "\(questions) \(questions == 1 ? "pregunta espera" : "preguntas esperan") tu respuesta.") }
    }

    @MainActor
    static func backgroundWork(store: AppStore, yt: YouTubeService, meta: MetaService) async {
        await Publisher.publishDue(store: store, meta: meta)
        await meta.refresh()
        WeeklyReport.sendIfDue(store: store, yt: yt, meta: meta)
        if yt.isConnected { await Publisher.refresh(store: store, yt: yt) }
        if AutoReply.enabled {
            let done = await autoReplyAll(yt: yt, meta: meta)
            let total = done.values.reduce(0, +)
            if total > 0 {
                let detail = done.map { "\($0.value) en \($0.key.name)" }.joined(separator: ", ")
                Notifier.send("Respuestas automáticas", "Respondí \(total) \(total == 1 ? "comentario" : "comentarios"): \(detail).")
            }
        } else if yt.isConnected, let comments = try? await yt.comments() {
            let pending = comments.filter { !$0.replied && !AutoReply.answered.contains($0.id) }
            let seen = Set(UserDefaults.standard.stringArray(forKey: "cs.seenComments") ?? [])
            let fresh = pending.filter { !seen.contains($0.id) }
            UserDefaults.standard.set(Array(seen.union(comments.map(\.id)).suffix(3000)), forKey: "cs.seenComments")
            if !fresh.isEmpty { Notifier.send("Comentarios nuevos", "Tienes \(fresh.count) \(fresh.count == 1 ? "comentario nuevo" : "comentarios nuevos") en YouTube.") }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: AppTab = .contenido
    @State private var locked = AppLock.enabled
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch tab {
            case .contenido: ContenidoView()
            case .clipper: ClipperView(inTab: true)
            case .horarios: CalendarView()
            case .metrica: MetricaView()
            case .comentarios: NavigationStack { CommentsView() }
            case .ajustes: SettingsView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar(tab: $tab) }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.bg)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Theme.fg, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
        .overlay { if locked { LockScreen { locked = false } } }
        .onChange(of: phase) { _, p in if p == .background && AppLock.enabled { locked = true } }
    }
}
