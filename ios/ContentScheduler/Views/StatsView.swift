import SwiftUI

struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Tus", outline: "números", subtitle: "Datos de tu canal de YouTube.")
                youtubeSection
            }
        }
    }

    @ViewBuilder private var youtubeSection: some View {
        if let ch = youtube.channel {
            HStack {
                NetBadge(network: .youtube)
                Text(ch.title.uppercased()).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button(refreshing ? "…" : "Actualizar") {
                    refreshing = true
                    Task { await Publisher.refresh(store: store, yt: youtube); refreshing = false }
                }.font(Theme.mono).foregroundStyle(Theme.accent)
            }.padding(.top, 10)
            let mine = store.state.posts.filter { $0.yt?.videoID != nil }.sorted { ($0.yt?.views ?? 0) > ($1.yt?.views ?? 0) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                kpi("Suscriptores", ch.subscribers.map { compact(Double($0)) } ?? "Oculto", "person.2")
                kpi("Vistas totales", compact(Double(ch.views)), "eye")
                kpi("Videos", compact(Double(ch.videos)), "video")
                kpi("Subidos desde aquí", "\(mine.count)", "arrow.up.circle")
            }
            if !mine.isEmpty {
                Card {
                    ForEach(mine.prefix(5)) { p in
                        HStack {
                            Text(p.title).lineLimit(1).font(.footnote)
                            Spacer()
                            Text("\(compact(Double(p.yt?.views ?? 0))) 👁  \(compact(Double(p.yt?.likes ?? 0))) ♥")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
            Text("Actualizado \(ch.checked.dayLabel.lowercased()) a las \(ch.checked.hm)").font(.caption).foregroundStyle(Theme.muted)
        } else {
            Card {
                HStack(spacing: 12) {
                    NetBadge(network: .youtube, size: 34)
                    VStack(alignment: .leading) {
                        Text("Conecta YouTube").bold()
                        Text("En Ajustes, para ver los números de tu canal.").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }.padding(.top, 10)
        }
    }

    private func kpi(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label.uppercased(), systemImage: icon).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.fg)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }

}
