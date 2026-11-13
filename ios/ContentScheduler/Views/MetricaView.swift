import SwiftUI
import Charts

/// Pantalla «Estadísticas»: por red, con tus números reales. Donde no hay cuenta se ven guiones.
struct MetricaView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube

    enum Metric: String, CaseIterable { case seguidores = "Seguidores", vistas = "Vistas", meGusta = "Me gusta" }

    @State private var network: Network = .youtube
    @State private var compare = false
    @AppStorage("cs.autoRefresh") private var auto = true
    @State private var metric: Metric = .seguidores
    @State private var refreshing = false

    private var connected: Bool { network == .youtube && youtube.isConnected }

    var body: some View {
        Screen {
            AppHeader()
            PageTitle(kicker: "Analítica", title: "Estadísticas")
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(connected ? Theme.ok : Theme.muted).frame(width: 7, height: 7)
                    Text(connected ? "Con datos" : "Sin datos").font(.footnote)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(Capsule().strokeBorder(Theme.line))
                Spacer()
                ShareLink(item: report) { Label("Reporte", systemImage: "doc.text") }
                    .buttonStyle(BoxButtonStyle())
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(refreshing ? 360 : 0))
                        .animation(refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshing)
                        .frame(width: 42, height: 42).overlay(Circle().strokeBorder(Theme.line))
                }.foregroundStyle(Theme.fg)
            }
            Divider().overlay(Theme.line).padding(.vertical, 6)

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Network.allCases) { n in
                        Button { network = n } label: {
                            Label(n.name, systemImage: icon(n)).font(.footnote)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .foregroundStyle(network == n ? .white : Theme.muted)
                                .background(network == n ? Theme.accent : Theme.bg2)
                        }.buttonStyle(.plain)
                    }
                }.overlay(Rectangle().strokeBorder(Theme.line))
            }.scrollIndicators(.hidden)

            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    seg("Detalle", !compare) { compare = false }
                    seg("Comparar", compare) { compare = true }
                }.overlay(Rectangle().strokeBorder(Theme.line))
                Toggle("Auto cada 3 min", isOn: $auto).font(.footnote).fixedSize()
            }

            if compare { compareView } else { detailView }
        }
        .task(id: auto) {
            await refresh()
            while auto && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                if !Task.isCancelled { await refresh() }
            }
        }
    }

    // MARK: Detalle

    @ViewBuilder private var detailView: some View {
        let ch = connected ? youtube.channel : nil
        let r = connected ? youtube.recent : nil
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person").font(.title3).foregroundStyle(Theme.muted)
                    .frame(width: 64, height: 64).background(Theme.bg3, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 3))
                VStack(alignment: .leading, spacing: 3) {
                    Text(ch?.title ?? "Sin cuenta").font(.title3)
                    Text(network.isReal ? network.name : "\(network.name) · próximamente").font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(18)
            Divider().overlay(Theme.line)
            cell("Seguidores", ch?.subscribers.map { compact(Double($0)) } ?? (ch != nil ? "Oculto" : nil), nil)
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                cell("Vistas", r.map { compact(Double($0.views)) }, "últimos \(r?.videos ?? 10) videos")
                Divider().overlay(Theme.line)
                cell("Me gusta", r.map { compact(Double($0.likes)) }, nil)
            }.fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                cell("Comentarios", r.map { compact(Double($0.comments)) }, nil)
                Divider().overlay(Theme.line)
                cell("Interacción", r.flatMap { $0.views > 0 ? String(format: "%.1f%%", Double($0.likes + $0.comments) / Double($0.views) * 100) : nil },
                     "me gusta + comentarios / vistas")
            }.fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.bg2).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        Box {
            Text("CRECIMIENTO").font(Theme.display(22)).foregroundStyle(Theme.fg)
            Text("Una foto por día de esta cuenta").font(.footnote).foregroundStyle(Theme.muted)
            HStack(spacing: 0) {
                ForEach(Metric.allCases, id: \.self) { m in seg(m.rawValue, metric == m) { metric = m } }
            }.overlay(Rectangle().strokeBorder(Theme.line))
            let points = connected ? youtube.snapshots : []
            if points.count < 2 {
                Text("—").font(.title).foregroundStyle(Theme.fg)
                Text(connected ? "La gráfica se llena con una foto por día. Vuelve mañana para ver el cambio." : "Sin cuenta conectada.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                Chart(points, id: \.day) { s in
                    LineMark(x: .value("Día", s.day), y: .value(metric.rawValue, value(s)))
                        .foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                    AreaMark(x: .value("Día", s.day), y: .value(metric.rawValue, value(s)))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 200)
            }
        }
    }

    // MARK: Comparar

    private var compareView: some View {
        Box {
            Text("COMPARAR REDES").font(Theme.display(22)).foregroundStyle(Theme.fg)
            ForEach(Network.allCases) { n in
                let on = n == .youtube && youtube.isConnected
                HStack {
                    NetBadge(network: n, dimmed: !on)
                    Text(n.name).font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(on ? (youtube.channel?.subscribers.map { compact(Double($0)) } ?? "Oculto") : "—").font(.headline)
                        Text("seguidores").font(.caption2).foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .trailing) {
                        Text(on ? (youtube.recent.map { compact(Double($0.views)) } ?? "—") : "—").font(.headline)
                        Text("vistas recientes").font(.caption2).foregroundStyle(Theme.muted)
                    }.frame(width: 96, alignment: .trailing)
                }
                if n != Network.allCases.last { Divider().overlay(Theme.line) }
            }
        }
    }

    // MARK: Piezas

    private func value(_ s: YouTubeService.Snapshot) -> Int {
        switch metric { case .seguidores: s.followers; case .vistas: s.views; case .meGusta: s.likes }
    }

    private func cell(_ title: String, _ value: String?, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(Theme.muted)
            Text(value ?? "–").font(value == nil ? .title2.bold() : Theme.display(30)).foregroundStyle(value == nil ? Theme.accent : Theme.fg)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.muted) }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func seg(_ text: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.footnote).padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(on ? .white : Theme.muted).background(on ? Theme.accent : Theme.bg2)
    }

    private func icon(_ n: Network) -> String {
        switch n { case .facebook: "f.square"; case .youtube: "play.rectangle"; case .instagram: "camera"; case .tiktok: "music.note" }
    }

    private var report: String {
        var lines = ["Reporte Content Scheduler · \(Date.now.formatted(date: .long, time: .omitted))"]
        if let ch = youtube.channel {
            lines.append("YouTube · \(ch.title)")
            lines.append("Suscriptores: \(ch.subscribers.map(String.init) ?? "oculto")")
            lines.append("Vistas totales: \(ch.views) · Videos: \(ch.videos)")
            if let r = youtube.recent {
                lines.append("Últimos \(r.videos) videos: \(r.views) vistas, \(r.likes) me gusta, \(r.comments) comentarios")
            }
        } else {
            lines.append("Sin cuentas conectadas.")
        }
        lines.append("Programados: \(store.programados.count) · Por programar: \(store.porProgramar.count) · Por revisar: \(store.porRevisar.count)")
        return lines.joined(separator: "\n")
    }

    private func refresh() async {
        guard youtube.isConnected, !refreshing else { return }
        refreshing = true
        await Publisher.refresh(store: store, yt: youtube)
        try? await youtube.refreshRecent()
        refreshing = false
    }
}
