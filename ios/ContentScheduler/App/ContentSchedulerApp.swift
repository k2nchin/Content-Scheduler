import SwiftUI

@main
struct ContentSchedulerApp: App {
    @State private var store = AppStore()
    @State private var youtube = YouTubeService()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(youtube)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await Publisher.refresh(store: store, yt: youtube) }
                .onChange(of: phase) { _, new in
                    if new == .active { Task { await Publisher.refresh(store: store, yt: youtube) } }
                }
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
