import SwiftUI
import Charts

/// Pantalla «Estadísticas»: por red, con tus números reales. Donde no hay cuenta se ven guiones.
struct MetricaView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta

    enum Metric: String, CaseIterable { case seguidores = "Seguidores", vistas = "Vistas", meGusta = "Me gusta" }

    @State private var network: Network = .youtube
    @State private var compare = false
    @AppStorage("cs.autoRefresh") private var auto = true
    @State private var metric: Metric = .seguidores
    @State private var refreshing = false
    @State private var ideas: [String] = []
    @State private var thinking = false

    private var connected: Bool {
        switch network {
        case .youtube: youtube.isConnected
        case .facebook: meta.facebookConnected
        case .instagram: meta.instagramConnected
        case .tiktok: false
        }
    }
    private var accountName: String? {
        switch network {
        case .youtube: youtube.channel?.title
        case .facebook: meta.page?.name
        case .instagram: meta.page?.igUsername.map { "@" + $0 }
        case .tiktok: nil
        }
    }
    private var followers: String? {
        switch network {
        case .youtube: youtube.channel.map { $0.subscribers.map { compact(Double($0)) } ?? "Oculto" }
        case .facebook: meta.facebookConnected ? meta.page?.followers.map { compact(Double($0)) } : nil
        case .instagram: meta.instagramConnected ? meta.page?.igFollowers.map { compact(Double($0)) } : nil
        case .tiktok: nil
        }
    }

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

            HStack(spacing: 0) {
                ForEach(Network.allCases) { n in
                    Button { network = n } label: {
                        VStack(spacing: 5) {
                            NetLogo(network: n, size: 18)
                            Text(n.name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(network == n ? .white : Theme.muted)
                        .background(network == n ? Theme.accent : Theme.bg2)
                    }.buttonStyle(.plain)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 0) {
                seg("Detalle", !compare) { compare = false }.frame(maxWidth: .infinity)
                seg("Comparar", compare) { compare = true }.frame(maxWidth: .infinity)
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Toggle(isOn: $auto) {
                Label("Actualizar solo cada 3 min", systemImage: "clock.arrow.2.circlepath").font(.footnote)
            }

            if network == .youtube { YTAccountPicker() }
            if network == .youtube && youtube.isConnected && NIM.isConfigured {
                Box {
                    Text("IDEAS DE CONTENIDO").font(Theme.mono).foregroundStyle(Theme.muted)
                    Text("La IA mira qué videos tuyos funcionaron mejor y te propone qué grabar.").font(.caption).foregroundStyle(Theme.muted)
                    Button {
                        thinking = true
                        Task {
                            do { ideas = try await NIM.ideas(videos: try await youtube.topVideos()) } catch { store.show(error.localizedDescription) }
                            thinking = false
                        }
                    } label: { Label(thinking ? "Pensando…" : "✨ Darme ideas", systemImage: "lightbulb") }
                        .buttonStyle(BoxButtonStyle(filled: true)).disabled(thinking)
                    ForEach(Array(ideas.enumerated()), id: \.offset) { i, idea in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                            Text(idea).font(.footnote)
                        }
                    }
                }
            }
            if compare { compareView } else { detailView }
        }
        .onChange(of: youtube.activeID) { _, _ in Task { await refresh() } }
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
        let r = network == .youtube && connected ? youtube.recent : nil
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NetBadge(network: network, size: 52, dimmed: !connected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connected ? (accountName ?? "Tu cuenta") : "Sin cuenta").font(.title3).lineLimit(1)
                    Text(network.isReal ? network.name : "\(network.name) · próximamente").font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(18)
            Divider().overlay(Theme.line)
            cell("Seguidores", connected ? followers : nil,
                 network == .instagram && connected ? meta.page?.igMedia.map { "\($0) publicaciones" } : nil)
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
        .background(Theme.bg2).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        Box {
            Text("CRECIMIENTO").font(Theme.display(22)).foregroundStyle(Theme.fg)
            Text("Una foto por día de esta cuenta").font(.footnote).foregroundStyle(Theme.muted)
            HStack(spacing: 0) {
                ForEach(Metric.allCases, id: \.self) { m in seg(m.rawValue, metric == m) { metric = m } }
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            let points = network == .youtube && connected ? youtube.snapshots : []
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
                let on = n == .youtube ? youtube.isConnected : n == .facebook ? meta.facebookConnected : n == .instagram ? meta.instagramConnected : false
                let f: String? = n == .youtube ? youtube.channel.map { $0.subscribers.map { compact(Double($0)) } ?? "Oculto" }
                    : n == .facebook ? meta.page?.followers.map { compact(Double($0)) }
                    : n == .instagram ? meta.page?.igFollowers.map { compact(Double($0)) } : nil
                HStack {
                    NetBadge(network: n, dimmed: !on)
                    Text(n.name).font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(on ? (f ?? "—") : "—").font(.headline)
                        Text("seguidores").font(.caption2).foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .trailing) {
                        Text(on && n == .youtube ? (youtube.recent.map { compact(Double($0.views)) } ?? "—") : "—").font(.headline)
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
            Text(value ?? "–").font(value == nil ? .title2.bold() : Theme.display(28)).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(value == nil ? Theme.accent : Theme.fg)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.muted) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func seg(_ text: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.footnote).padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(on ? .white : Theme.muted).background(on ? Theme.accent : Theme.bg2)
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
        guard !refreshing else { return }
        refreshing = true
        await meta.refresh()
        if youtube.isConnected {
            await Publisher.refresh(store: store, yt: youtube)
            try? await youtube.refreshRecent()
        }
        refreshing = false
    }
}
