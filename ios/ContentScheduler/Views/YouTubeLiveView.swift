import SwiftUI

/// Directos de YouTube: vigila el chat con la API oficial y marca los momentos en que explota.
/// YouTube no tiene API para crear clips, así que la app marca el momento y te lleva a él para que toques «Clip».
@Observable
@MainActor
final class YouTubeLiveWatcher {
    struct Moment: Identifiable, Codable, Hashable {
        var id = UUID()
        let videoID: String
        let channel: String
        let offset: Double       // segundos desde que empezó el directo
        let at: Date
        let reason: String
        let rate: Int            // mensajes por minuto en ese momento
        var used = false
        /// Link al momento exacto del directo.
        var url: URL? { URL(string: "https://www.youtube.com/watch?v=\(videoID)&t=\(Int(max(0, offset - 25)))s") }
    }

    var live: YouTubeService.LiveInfo?
    var watching = false
    var perMinute = 0
    var lastEvent = ""
    var moments: [Moment] = [] { didSet { save() } }
    var quotaCalls = 0
    /// Tiempo real: sigue el ritmo que marca YouTube (~5 s). Apagado: cada 20 s, gasta menos cuota.
    var fast: Bool {
        get { UserDefaults.standard.object(forKey: "yt.live.fast") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "yt.live.fast") }
    }
    /// Unidades de cuota por hora con el ritmo actual.
    var quotaPerHour: Int { fast ? 3600 : 900 }

    private var task: Task<Void, Never>?
    private var times: [Date] = []
    private var hits: [Date] = []
    private var baseline = 0.5
    private var lastMark = Date.distantPast

    private static let hype = ["jaja", "jsjs", "lol", "lmao", "omg", "🔥", "😂", "🤣", "💀", "clip", "wtf",
                               "que lo que", "klk", "diache", "wow", "no puede ser", "brutal", "duro"]

    init() {
        if let d = UserDefaults.standard.data(forKey: "yt.live.moments"),
           let m = try? JSONDecoder().decode([Moment].self, from: d) { moments = m }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(moments.prefix(300))), forKey: "yt.live.moments")
    }

    func start(_ query: String, yt: YouTubeService) async throws {
        stop()
        let info = try await yt.findLive(query)
        live = info
        watching = true
        times = []; hits = []; baseline = 0.5; quotaCalls = 0
        lastEvent = "Vigilando el chat de \(info.channel)…"
        task = Task { await loop(yt: yt) }
    }

    func stop() {
        watching = false
        task?.cancel()
        task = nil
    }

    private func loop(yt: YouTubeService) async {
        guard let info = live else { return }
        var pageToken: String?
        var ticks = 0
        while watching && !Task.isCancelled {
            do {
                let page = try await yt.liveChat(chatID: info.chatID, after: pageToken)
                quotaCalls += 1
                if page.ended {
                    lastEvent = "El directo terminó."
                    watching = false
                    return
                }
                pageToken = page.next
                let now = Date.now
                for t in page.texts {
                    times.append(now)
                    if Self.hype.contains(where: { t.contains($0) }) { hits.append(now) }
                }
                evaluate()
                // Cada ~2 min refresca los espectadores (1 unidad)
                ticks += 1
                if ticks % (fast ? 24 : 6) == 0, let v = try? await yt.liveViewers(videoID: info.videoID) {
                    live?.viewers = v
                    quotaCalls += 1
                }
                // En tiempo real se sigue el ritmo de YouTube; si no, cada 20 s para cuidar la cuota
                let wait = fast ? max(2_000, page.waitMs) : max(20_000, page.waitMs)
                try await Task.sleep(for: .milliseconds(wait))
            } catch is CancellationError {
                return
            } catch {
                lastEvent = error.localizedDescription
                watching = false
                return
            }
        }
    }

    /// Marca el momento si el chat se dispara o hay muchas reacciones.
    private func evaluate() {
        let now = Date.now
        times.removeAll { now.timeIntervalSince($0) > 120 }
        hits.removeAll { now.timeIntervalSince($0) > 40 }
        let last30 = Double(times.filter { now.timeIntervalSince($0) <= 30 }.count)
        let rate = last30 / 30
        perMinute = Int(rate * 60)
        let spike = rate >= max(baseline * 3, 0.5)
        let hype = hits.count >= 8
        baseline = baseline * 0.9 + max(rate, 0.05) * 0.1
        guard spike || hype, now.timeIntervalSince(lastMark) > 90, let info = live else { return }
        lastMark = now
        let m = Moment(videoID: info.videoID, channel: info.channel,
                       offset: now.timeIntervalSince(info.started),
                       at: now,
                       reason: spike ? "el chat explotó" : "muchas reacciones en el chat",
                       rate: perMinute)
        moments.insert(m, at: 0)
        lastEvent = "🔥 Momento marcado (\(m.rate) msj/min)"
        Notifier.send("🔥 Momento en \(info.channel)", "\(m.reason) · \(m.rate) msj/min. Toca para abrirlo en YouTube.")
    }
}

struct YouTubeLiveView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var watcher = YouTubeLiveWatcher()
    @State private var query = ""
    @State private var busy = false

    private var red: Color { Color(hex: 0xFF0000) }

    var body: some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: "Stream", title: "YouTube en vivo")
                if !youtube.isConnected {
                    DemoBanner(text: "Conecta YouTube en Ajustes para leer el chat de los directos.", icon: "info.circle")
                } else {
                    watchBox
                    momentsList
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { watcher.stop(); dismiss() } } }
            .onDisappear { watcher.stop() }
        }
    }

    private var watchBox: some View {
        Box {
            Text("CANAL O LINK DEL DIRECTO").font(Theme.mono).foregroundStyle(Theme.muted)
            TextField("@canal o https://youtube.com/live/…", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(watcher.watching)
            if let live = watcher.live, watcher.watching {
                HStack {
                    Circle().fill(red).frame(width: 8, height: 8)
                    Text(live.channel).font(.footnote.bold()).lineLimit(1)
                    Spacer()
                    Text("\(live.viewers) viendo · \(watcher.perMinute) msj/min")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Text(live.title).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                if !watcher.lastEvent.isEmpty { Text(watcher.lastEvent).font(.caption).foregroundStyle(Theme.accent) }
                HStack(spacing: 10) {
                    Button { markNow() } label: { Label("Marcar ahora", systemImage: "bookmark").frame(maxWidth: .infinity) }
                        .buttonStyle(BoxButtonStyle(filled: true, color: red))
                    Button { watcher.stop() } label: { Text("Parar").frame(maxWidth: .infinity) }
                        .buttonStyle(BoxButtonStyle())
                }
                Text("Deja esta pantalla abierta. Llevas ~\(watcher.quotaCalls * 5) de 10.000 unidades de cuota hoy.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            } else {
                Button {
                    busy = true
                    Task {
                        do { try await watcher.start(query, yt: youtube) } catch { store.show(error.localizedDescription) }
                        busy = false
                    }
                } label: { Label(busy ? "Buscando el directo…" : "Vigilar el chat", systemImage: "eye").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle(filled: true, color: red)).disabled(busy)
                Divider().overlay(Theme.line)
                Toggle(isOn: Binding(get: { watcher.fast }, set: { watcher.fast = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tiempo real").bold()
                        Text(watcher.fast
                             ? "Lee el chat al ritmo de YouTube (~5 s): te avisa al instante. Alcanza para ~2,5 h de directo al día."
                             : "Lee el chat cada 20 s: avisa con un poco de retraso, pero alcanza para ~11 h al día.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Text("La app marca los momentos en que el chat explota. YouTube no deja crear clips por programa: tocas el momento y lo abres en YouTube para usar su botón «Clip».")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var momentsList: some View {
        Group {
            if !watcher.moments.isEmpty {
                SectionLabel(text: "Momentos marcados (\(watcher.moments.count))")
                ForEach(watcher.moments) { m in
                    Box {
                        HStack(alignment: .top, spacing: 12) {
                            Text(clock(m.offset)).font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.accent).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.channel).font(.footnote.bold())
                                Text("\(m.reason) · \(m.rate) msj/min").font(.caption).foregroundStyle(Theme.muted)
                                Text(m.at.dayLabel + " " + m.at.hm).font(.caption2).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            if m.used { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                        }
                        HStack(spacing: 14) {
                            Button {
                                if let u = m.url { openURL(u) }
                                if let i = watcher.moments.firstIndex(where: { $0.id == m.id }) { watcher.moments[i].used = true }
                            } label: { Label("Abrir en YouTube", systemImage: "play.rectangle") }
                                .font(.caption.bold())
                            Button {
                                UIPasteboard.general.string = m.url?.absoluteString
                                store.show("Link del momento copiado")
                            } label: { Label("Copiar link", systemImage: "link") }
                                .font(.caption.bold()).foregroundStyle(Theme.muted)
                            Button { watcher.moments.removeAll { $0.id == m.id } } label: { Image(systemName: "xmark") }
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                Text("Cuando tengas el VOD del directo, estos tiempos te dicen exactamente dónde cortar en el Clipper.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    private func markNow() {
        guard let live = watcher.live else { return }
        let m = YouTubeLiveWatcher.Moment(videoID: live.videoID, channel: live.channel,
                                          offset: Date.now.timeIntervalSince(live.started), at: .now,
                                          reason: "a mano", rate: watcher.perMinute)
        watcher.moments.insert(m, at: 0)
        store.show("Momento marcado")
    }

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
