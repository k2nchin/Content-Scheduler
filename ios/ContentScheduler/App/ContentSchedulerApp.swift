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

    var body: some View {
        TabView {
            QueueView().tabItem { Label("Cola", systemImage: "list.bullet.rectangle") }
            CalendarView().tabItem { Label("Calendario", systemImage: "calendar") }
            StatsView().tabItem { Label("Stats", systemImage: "chart.bar.fill") }
            ClipsView().tabItem { Label("Reciclar", systemImage: "arrow.triangle.2.circlepath") }
            SettingsView().tabItem { Label("Ajustes", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.bg)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Theme.fg, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}
