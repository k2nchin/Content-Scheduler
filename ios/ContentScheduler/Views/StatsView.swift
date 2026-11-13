import SwiftUI
import Charts

struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var range = 7
    @State private var refreshing = false

    private struct DayPoint: Identifiable { let id = UUID(); let date: Date; let network: Network; let views: Double }

    private func demo(_ days: Int, offset: Int = 0) -> [DayPoint] {
        var gen = SeededRandom(seed: UInt64(days * 31 + offset))
        var out: [DayPoint] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            let d = Calendar.current.date(byAdding: .day, value: -(i + offset), to: .now)!
            let week = [1.3, 0.8, 1, 1, 1.05, 1.1, 1.35][Calendar.current.component(.weekday, from: d) - 1]
            let trend = 1 + Double(days - i) / Double(days) * 0.6
            for (j, n) in [Network.facebook, .instagram, .tiktok].enumerated() where store.state.demoAccounts[n] ?? false {
                out.append(DayPoint(date: d, network: n, views: (900 + gen.next() * 1400) * [1.2, 1.6, 1.9][j] * week * trend))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Tus", outline: "números", subtitle: "Vistas, me gusta y crecimiento de cada cuenta.")
                youtubeSection
                SectionLabel(text: "Facebook, Instagram y TikTok (ejemplo)")
                Picker("Rango", selection: $range) {
                    Text("7 días").tag(7); Text("30 días").tag(30); Text("90 días").tag(90)
                }.pickerStyle(.segmented)
                let data = demo(range), prev = demo(range, offset: range)
                let total = data.reduce(0) { $0 + $1.views }, before = prev.reduce(0) { $0 + $1.views }
                let delta = before > 0 ? (total - before) / before * 100 : 0
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    kpi("Vistas", compact(total), "eye", delta)
                    kpi("Me gusta", compact(total * 0.082), "heart", delta * 0.8 + 2)
                    kpi("Seguidores", "+" + compact(total * 0.0061), "person.badge.plus", delta * 1.1 + 4)
                    kpi("Posts", "\(store.published.count + range * 2)", "paperplane", 12.5)
                }
                Card {
                    Text("VISTAS POR DÍA").font(Theme.mono).foregroundStyle(Theme.muted)
                    Chart(data) { p in
                        BarMark(x: .value("Día", p.date, unit: .day), y: .value("Vistas", p.views))
                            .foregroundStyle(by: .value("Red", p.network.name))
                    }
                    .chartForegroundStyleScale(["Facebook": Network.facebook.color, "Instagram": Network.instagram.color, "TikTok": Network.tiktok.color])
                    .frame(height: 180)
                }
                SectionLabel(text: "Por red (ejemplo)")
                Card {
                    let perNet = [Network.facebook, .instagram, .tiktok, .youtube].map { n in
                        (n, data.filter { $0.network == n }.reduce(0) { $0 + $1.views })
                    }.sorted { $0.1 > $1.1 }
                    let maxNet = max(perNet.first?.1 ?? 1, 1)
                    ForEach(perNet, id: \.0) { n, v in
                        HStack(spacing: 10) {
                            NetBadge(network: n)
                            Text(n.name).font(.footnote).frame(width: 74, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.bg3).frame(height: 9)
                                    Capsule().fill(n.color).frame(width: geo.size.width * (v / maxNet), height: 9)
                                }
                            }.frame(height: 9)
                            Text(v > 0 ? compact(v) : "—").font(.system(size: 12, design: .monospaced)).frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                SectionLabel(text: "Tus mejores horas (ejemplo)")
                Card {
                    heatmap
                    Text("Tu mejor momento: **Sáb 21:00**. Tus horarios se ajustan a estas horas.").font(.footnote)
                }
                SectionLabel(text: "Hashtags que más rinden (ejemplo)")
                FlowTags(tags: [("#viral", 38), ("#envivo", 27), ("#meme", 22), ("#musica", 15), ("#parati", 9), ("#latino", 6)])

                let top = store.state.posts.sorted { $0.title.count > $1.title.count }.prefix(3)
                if !top.isEmpty {
                    SectionLabel(text: "Lo más visto")
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 12) {
                            Thumb(post: p, width: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("\(compact(total * [0.21, 0.13, 0.08][i])) vistas · ejemplo").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            Button { store.recycle(p.id) } label: { Image(systemName: "arrow.clockwise").padding(10) }
                                .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .padding(10)
                        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                    }
                }
            }
        }
    }

    @ViewBuilder private var youtubeSection: some View {
        if let ch = youtube.channel {
            HStack {
                NetBadge(network: .youtube)
                Text("\(ch.title) · datos reales".uppercased()).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button(refreshing ? "…" : "Actualizar") {
                    refreshing = true
                    Task { await Publisher.refresh(store: store, yt: youtube); refreshing = false }
                }.font(Theme.mono).foregroundStyle(Theme.accent)
            }.padding(.top, 10)
            let mine = store.state.posts.filter { $0.yt?.videoID != nil }.sorted { ($0.yt?.views ?? 0) > ($1.yt?.views ?? 0) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                kpi("Suscriptores", ch.subscribers.map { compact(Double($0)) } ?? "Oculto", "person.2", nil)
                kpi("Vistas totales", compact(Double(ch.views)), "eye", nil)
                kpi("Videos", compact(Double(ch.videos)), "video", nil)
                kpi("Subidos desde aquí", "\(mine.count)", "arrow.up.circle", nil)
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
            Card { NavigationLink { CommentsView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.accent).frame(width: 32)
                    VStack(alignment: .leading) {
                        Text("Comentarios de YouTube").bold()
                        Text("Responder y respuestas automáticas").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain) }
        } else {
            Card {
                HStack(spacing: 12) {
                    NetBadge(network: .youtube, size: 34)
                    VStack(alignment: .leading) {
                        Text("Conecta YouTube").bold()
                        Text("En Ajustes, para ver los números reales de tu canal.").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }.padding(.top, 10)
        }
    }

    private func kpi(_ label: String, _ value: String, _ icon: String, _ delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label.uppercased(), systemImage: icon).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.fg)
            if let delta {
                Text("\(delta >= 0 ? "▲" : "▼") \(String(format: "%.1f", abs(delta)))%")
                    .font(.caption).foregroundStyle(delta >= 0 ? Theme.ok : Theme.red)
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }

    private var heatmap: some View {
        let hours = ["6", "9", "12", "15", "18", "21", "0", "3"]
        let base = [0.15, 0.35, 0.5, 0.35, 0.75, 0.95, 0.4, 0.08]
        let days = ["Lu", "Ma", "Mi", "Ju", "Vi", "Sá", "Do"]
        var gen = SeededRandom(seed: 99)
        let values = days.indices.map { d in base.map { min(1, $0 * (d >= 5 ? 1.15 : 1) * (0.75 + gen.next() * 0.4)) } }
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("")
                ForEach(hours, id: \.self) { Text($0 + "h").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }
            }
            ForEach(days.indices, id: \.self) { d in
                GridRow {
                    Text(days[d]).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
                    ForEach(hours.indices, id: \.self) { h in
                        RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.08 + values[d][h] * 0.92)).aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }
}

struct FlowTags: View {
    let tags: [(String, Int)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.0) { t in
                HStack(spacing: 6) {
                    Text(t.0).font(.footnote)
                    Text("+\(t.1)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ok)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
        }
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
