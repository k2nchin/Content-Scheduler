import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta
    @State private var connectingYT = false
    @State private var connectingMeta = false
    @State private var confirmYT = false
    @State private var confirmMeta = false

    var body: some View {
        NavigationStack {
            Screen {
                AppHeader()
                PageTitle(kicker: "Tu cuenta", title: "Ajustes")

                SectionLabel(text: "Cuentas conectadas")
                Card {
                    // YouTube
                    Button { if youtube.isConnected { confirmYT = true } else { connectYouTube() } } label: {
                        row(.youtube, "YouTube",
                            youtube.channel.map { "Canal: \($0.title)" } ?? (connectingYT ? "Conectando…" : "Toca para conectar tu canal"),
                            youtube.isConnected)
                    }.buttonStyle(.plain)
                    if youtube.isConnected {
                        Divider().overlay(Theme.line)
                        NavigationLink { CommentsView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.accent).frame(width: 32)
                                VStack(alignment: .leading) {
                                    Text("Comentarios de YouTube").bold()
                                    Text("Responder y respuestas automáticas").font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }

                    Divider().overlay(Theme.line)

                    // Facebook + Instagram (Meta)
                    if meta.hasAccount {
                        row(.facebook, "Facebook", meta.page.map { "Página: \($0.name)" } ?? "", meta.facebookConnected)
                        Divider().overlay(Theme.line)
                        row(.instagram, "Instagram",
                            meta.page?.igUsername.map { "@\($0)" } ?? "Sin cuenta profesional vinculada a la página",
                            meta.instagramConnected)
                        if meta.pages.count > 1 {
                            Picker("Página", selection: Binding(get: { meta.page?.id ?? "" }, set: { meta.selectedPageID = $0 })) {
                                ForEach(meta.pages) { Text($0.name).tag($0.id) }
                            }.font(.footnote)
                        }
                        if !meta.tokenValid {
                            Button { connectMeta() } label: { Label("La sesión caducó · Entrar de nuevo con Facebook", systemImage: "arrow.clockwise") }
                                .font(.footnote.bold()).foregroundStyle(Theme.warn)
                        }
                        Button(role: .destructive) { confirmMeta = true } label: { Text("Desconectar Facebook e Instagram").font(.footnote) }
                    } else {
                        Button { connectMeta() } label: {
                            HStack(spacing: 10) {
                                NetLogo(network: .facebook, size: 18)
                                Text(connectingMeta ? "Conectando…" : "Continuar con Facebook").bold()
                                Spacer()
                                NetLogo(network: .instagram, size: 18)
                            }
                            .foregroundStyle(.white).padding(14)
                            .background(Network.facebook.color, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                        Text("Conecta tus páginas de Facebook y la cuenta profesional de Instagram vinculada a ellas.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }

                    Divider().overlay(Theme.line)
                    HStack(spacing: 12) {
                        NetBadge(network: .tiktok, size: 32, dimmed: true)
                        VStack(alignment: .leading) {
                            Text("TikTok").bold().foregroundStyle(Theme.muted)
                            Text("Próximamente").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }

                SectionLabel(text: "Notificaciones")
                Card {
                    Toggle(isOn: Binding(get: { UserDefaults.standard.object(forKey: "cs.notify") as? Bool ?? true },
                                         set: { v in UserDefaults.standard.set(v, forKey: "cs.notify"); if v { Task { _ = await Notifier.requestPermission() } } })) {
                        VStack(alignment: .leading) {
                            Text("Avisos en el teléfono").bold()
                            Text("Cuando un video se programa, se publica o falla, y cuando llegan comentarios.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }

                Text("CONTENT SCHEDULER · iOS").font(Theme.mono).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("¿Desconectar YouTube?", isPresented: $confirmYT, titleVisibility: .visible) {
                Button("Desconectar", role: .destructive) { youtube.disconnect(); store.show("YouTube desconectado") }
            }
            .confirmationDialog("¿Desconectar Facebook e Instagram?", isPresented: $confirmMeta, titleVisibility: .visible) {
                Button("Desconectar", role: .destructive) { meta.disconnect(); store.show("Facebook e Instagram desconectados") }
            }
        }
    }

    private func connectYouTube() {
        connectingYT = true
        Task {
            do { try await youtube.connect(); store.show("YouTube conectado") } catch { store.show(error.localizedDescription) }
            connectingYT = false
        }
    }

    private func connectMeta() {
        connectingMeta = true
        Task {
            do { try await meta.connect(); store.show("Facebook e Instagram conectados") } catch { store.show(error.localizedDescription) }
            connectingMeta = false
        }
    }

    private func row(_ n: Network, _ title: String, _ detail: String, _ on: Bool) -> some View {
        HStack(spacing: 12) {
            NetBadge(network: n, size: 32)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(on ? Theme.ok : Theme.accent).font(.title3)
        }
        .contentShape(Rectangle())
    }
}

struct FlowSlots: View {
    let slots: [String]
    let remove: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(slots, id: \.self) { s in
                HStack(spacing: 6) {
                    Text(s).font(.system(size: 13, design: .monospaced))
                    Button { remove(s) } label: { Image(systemName: "xmark").font(.caption2) }.foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
            }
        }
    }
}
