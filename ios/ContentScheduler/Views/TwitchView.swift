import SwiftUI

/// Clips de Twitch: vigila el chat de un directo y crea clips cuando explota; en tu canal, los pasa a 9:16 y a la cola.
struct TwitchView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss
    @State private var twitch = TwitchService.shared
    @State private var busy = false
    @State private var converting: Set<String> = []

    private var twitchPurple: Color { Color(hex: 0x9146FF) }

    var body: some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: "Stream", title: "Twitch")
                if !twitch.isConfigured {
                    DemoBanner(text: "Falta el Client ID de Twitch. Crea una app en dev.twitch.tv (tipo «Pública», con Device Flow) y pásame el Client ID.", icon: "exclamationmark.triangle")
                } else if !twitch.isConnected {
                    Box {
                        Text("Conecta tu cuenta de Twitch para crear clips de cualquier directo y bajar los de tu canal.").font(.footnote).foregroundStyle(Theme.muted)
                        if let code = twitch.userCode {
                            Text("Escribe este código en twitch.tv/activate:").font(.footnote)
                            Text(code).font(.system(size: 30, weight: .heavy, design: .monospaced)).foregroundStyle(twitchPurple)
                            Button("Copiar código") { UIPasteboard.general.string = code }.font(.caption.bold())
                            ProgressView("Esperando que confirmes en Twitch…").font(.caption)
                        }
                        Button {
                            busy = true
                            Task {
                                do { try await twitch.connect(); store.show("Twitch conectado") } catch { store.show(error.localizedDescription) }
                                busy = false
                            }
                        } label: { Text(busy ? "Conectando…" : "Conectar Twitch").frame(maxWidth: .infinity) }
                            .buttonStyle(BoxButtonStyle(filled: true, color: twitchPurple)).disabled(busy)
                    }
                } else {
                    watchBox
                    clipsList
                    Button("Desconectar Twitch (\(twitch.login ?? ""))") { twitch.disconnect() }
                        .font(.footnote).foregroundStyle(Theme.red)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }

    private var watchBox: some View {
        Box {
            Text("CANAL EN VIVO").font(Theme.mono).tracking(1.6).foregroundStyle(Theme.muted)
            TextField("nombre del canal", text: $twitch.channel)
                .textInputAutocapitalization(.never).autocorrectionDisabled().padding(10).background(Theme.bg3)
                .disabled(twitch.watching)
            if twitch.watching {
                HStack {
                    Circle().fill(twitch.isLive ? .red : Theme.muted).frame(width: 8, height: 8)
                    Text(twitch.isLive ? "En vivo · \(twitch.viewers) viendo" : "No está en vivo").font(.footnote.bold())
                    Spacer()
                    Text("\(twitch.perMinute) msj/min").font(.system(size: 12, design: .monospaced))
                }
                if !twitch.lastEvent.isEmpty { Text(twitch.lastEvent).font(.caption).foregroundStyle(Theme.muted) }
                HStack(spacing: 10) {
                    Button {
                        Task { do { try await twitch.createClip(reason: "a mano") } catch { store.show(error.localizedDescription) } }
                    } label: { Label("Clip ahora", systemImage: "scissors").frame(maxWidth: .infinity) }
                        .buttonStyle(BoxButtonStyle(filled: true, color: twitchPurple)).disabled(!twitch.isLive)
                    Button { twitch.stopWatching() } label: { Text("Parar").frame(maxWidth: .infinity) }
                        .buttonStyle(BoxButtonStyle())
                }
                Text("Deja esta pantalla abierta: cuando el chat explota (≥3× lo normal) o hay muchas risas/🔥, se crea un clip en Twitch (máx. 1 por minuto).")
                    .font(.caption2).foregroundStyle(Theme.muted)
            } else {
                Button {
                    Task { do { try await twitch.startWatching() } catch { store.show(error.localizedDescription) } }
                } label: { Label("Vigilar el chat y clipear solo", systemImage: "eye").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle(filled: true, color: twitchPurple))
            }
        }
    }

    private var clipsList: some View {
        Group {
            if !twitch.clips.isEmpty {
                SectionLabel(text: "Clips creados (\(twitch.clips.count))")
                ForEach(twitch.clips) { c in
                    Box {
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: c.thumbnail.flatMap(URL.init)) { img in img.resizable().scaledToFill() } placeholder: { Theme.bg3 }
                                .frame(width: 96, height: 54).clipped()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title ?? "Clip de \(c.channel)").font(.footnote.bold()).lineLimit(2)
                                Text("\(c.created.dayLabel) \(c.created.hm) · \(c.reason)").font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                        HStack(spacing: 14) {
                            if let u = c.url.flatMap(URL.init) { Link("Ver en Twitch", destination: u).font(.caption.bold()) }
                            else { Button("Actualizar") { Task { await twitch.refreshDetails(c.id) } }.font(.caption.bold()) }
                            if c.broadcasterID == twitch.userID {
                                Button(converting.contains(c.id) ? "Creando…" : "A la cola en 9:16") { Task { await toQueue(c) } }
                                    .font(.caption.bold()).foregroundStyle(Theme.accent).disabled(converting.contains(c.id))
                            }
                        }
                    }
                }
                Text("Solo los clips de tu canal se pueden bajar y publicar: Twitch no deja bajar clips de otros canales.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    /// Baja el clip de tu canal, lo pasa a 9:16 siguiendo a la persona, con subtítulos, y lo manda a la cola.
    private func toQueue(_ c: TwitchService.Clip) async {
        converting.insert(c.id)
        defer { converting.remove(c.id) }
        do {
            let file = try await twitch.download(c)
            defer { try? FileManager.default.removeItem(at: file) }
            let dur = try await AVURLAssetDuration.of(file)
            let out = try await StudioExport.run(source: file, start: 0, end: dur, subtitles: true, vertical: true, track: true) { _ in }
            let id = await store.addVideo(from: out, youtubeConnected: youtube.isConnected)
            store.update(id) { $0.title = c.title ?? "Clip de Twitch" }
            store.show("Clip de Twitch en la cola ✓")
        } catch { store.show(error.localizedDescription) }
    }
}

import AVFoundation
enum AVURLAssetDuration {
    static func of(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }
}
