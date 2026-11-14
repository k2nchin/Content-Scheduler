import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta
    @State private var connectingYT = false
    @State private var connectingMeta = false
    @State private var connectingDrive = false
    @State private var drive = DriveService.shared
    @State private var closing: YTChannel?
    @State private var confirmMeta = false
    @AppStorage("cs.lock") private var lock = false
    @AppStorage("cs.weekly") private var weekly = true
    @State private var exporting = false
    @State private var importing = false
    @State private var backupDoc = BackupDocument(data: Data())

    var body: some View {
        NavigationStack {
            Screen {
                AppHeader()
                PageTitle(kicker: "Tu cuenta", title: "Ajustes")

                SectionLabel(text: "Cuentas conectadas")
                Card {
                    // YouTube: varias cuentas
                    ForEach(youtube.accounts, id: \.id) { acc in
                        HStack(spacing: 12) {
                            NetBadge(network: .youtube, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acc.title).bold().lineLimit(1)
                                Text(acc.id == youtube.channel?.id ? "Cuenta activa" : "Toca para usar esta cuenta")
                                    .font(.caption).foregroundStyle(acc.id == youtube.channel?.id ? Theme.ok : Theme.muted)
                            }
                            Spacer()
                            Button { closing = acc } label: { Text("Cerrar sesión").font(.caption.bold()) }
                                .foregroundStyle(Theme.red).buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { youtube.setActive(acc.id) }
                        Divider().overlay(Theme.line)
                    }
                    Button { connectYouTube() } label: {
                        HStack(spacing: 12) {
                            NetBadge(network: .youtube, size: 32, dimmed: youtube.isConnected)
                            Text(connectingYT ? "Conectando…" : youtube.isConnected ? "Agregar otra cuenta de YouTube" : "Conectar YouTube").bold()
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(Theme.accent).font(.title3)
                        }.contentShape(Rectangle())
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

                SectionLabel(text: "Almacenamiento en la nube")
                Card {
                    if drive.isConnected {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill.badge.icloud").font(.title3).foregroundStyle(Theme.accent).frame(width: 32)
                            VStack(alignment: .leading) {
                                Text("Google Drive").bold()
                                Text(drive.email ?? "").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Desconectar") { drive.disconnect(); store.show("Google Drive desconectado") }
                                .font(.caption.bold()).foregroundStyle(Theme.red).buttonStyle(.borderless)
                        }
                        Divider().overlay(Theme.line)
                        Toggle(isOn: Binding(get: { drive.useDrive }, set: { drive.useDrive = $0 })) {
                            VStack(alignment: .leading) {
                                Text("Guardar los clips en Drive").bold()
                                Text("Carpeta «Content Scheduler». No ocupan espacio en tu iPhone; se bajan solo al publicarse.").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    } else {
                        Button {
                            connectingDrive = true
                            Task {
                                do { try await drive.connect(); store.show("Google Drive conectado") } catch { store.show(error.localizedDescription) }
                                connectingDrive = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.badge.icloud").font(.title3).foregroundStyle(Theme.accent).frame(width: 32)
                                VStack(alignment: .leading) {
                                    Text(connectingDrive ? "Conectando…" : "Conectar Google Drive").bold()
                                    Text("Para guardar tus clips en la nube. La app solo ve los archivos que ella crea.").font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Theme.accent).font(.title3)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
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

                SectionLabel(text: "Seguridad y respaldo")
                Card {
                    Toggle(isOn: $weekly) {
                        VStack(alignment: .leading) {
                            Text("Reporte semanal").bold()
                            Text("Cada lunes: seguidores de tus cuentas y lo que publicaste en la semana.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Divider().overlay(Theme.line)
                    Toggle(isOn: $lock) {
                        VStack(alignment: .leading) {
                            Text("Bloquear con Face ID").bold()
                            Text("Pide tu cara o tu código al abrir la app.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Divider().overlay(Theme.line)
                    Button { backupDoc = BackupManager.make(store); exporting = true } label: {
                        Label("Exportar copia de seguridad", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { importing = true } label: {
                        Label("Restaurar desde una copia", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Text("Guarda tu cola, horarios, reglas de comentarios y grupos de hashtags (sin los archivos de video).")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                Text("CONTENT SCHEDULER · iOS").font(Theme.mono).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileExporter(isPresented: $exporting, document: backupDoc, contentType: .json,
                          defaultFilename: "ContentScheduler-\(Date.now.formatted(.iso8601.year().month().day()))") { result in
                if case .success = result { store.show("Copia de seguridad guardada") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                do { try BackupManager.restore(url, into: store); store.show("Copia restaurada") }
                catch { store.show("Ese archivo no es una copia válida de Content Scheduler.") }
            }
            .confirmationDialog("¿Cerrar sesión de \(closing?.title ?? "esta cuenta")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    if let c = closing { youtube.disconnect(c.id); store.show("Sesión cerrada: \(c.title)") }
                    closing = nil
                }
            } message: { Text("Solo se cierra esta cuenta. Lo que ya está programado en YouTube se queda allá.") }
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
