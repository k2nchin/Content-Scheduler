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
        req.earliestBeginDate = Date.now.addingTimeInterval(20 * 60)
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
    }

    @MainActor
    static func backgroundWork(store: AppStore, yt: YouTubeService, meta: MetaService) async {
        await Publisher.publishDue(store: store, meta: meta)
        guard yt.isConnected else { return }
        await Publisher.refresh(store: store, yt: yt)
        guard let comments = try? await yt.comments() else { return }
        let pending = comments.filter { !$0.replied && !AutoReply.answered.contains($0.id) }
        let seen = Set(UserDefaults.standard.stringArray(forKey: "cs.seenComments") ?? [])
        let fresh = pending.filter { !seen.contains($0.id) }
        UserDefaults.standard.set(Array(seen.union(comments.map(\.id)).suffix(3000)), forKey: "cs.seenComments")
        if AutoReply.enabled {
            let n = await AutoReply.run(pending, yt: yt)
            if n > 0 { Notifier.send("Respuestas automáticas", "Respondí \(n) \(n == 1 ? "comentario" : "comentarios") en YouTube.") }
        } else if !fresh.isEmpty {
            Notifier.send("Comentarios nuevos", "Tienes \(fresh.count) \(fresh.count == 1 ? "comentario nuevo" : "comentarios nuevos") en YouTube.")
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: AppTab = .contenido

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch tab {
            case .contenido: ContenidoView()
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
    }
}
