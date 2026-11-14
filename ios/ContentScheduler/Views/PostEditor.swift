import SwiftUI
import PhotosUI

struct PostEditor: View {
    let postID: UUID
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var tags = ""
    @State private var custom: [String: String] = [:]
    @State private var firstComment = ""
    @State private var aiTags = false
    @State private var perNetwork = false
    @State private var studio = false
    @State private var networks: Set<Network> = []
    @State private var date = Date.now
    @State private var loaded = false
    @State private var pick: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var busy = false
    @AppStorage("cs.hashtagGroups") private var groupsRaw = "#musica #envivo #viral\n#meme #humor #parati\n#reels #shorts #fyp"
    private var groups: [String] { groupsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private var post: Post? { store.post(postID) }

    var body: some View {
        NavigationStack {
            Screen {
                if let post {
                    if let err = post.errorMessage {
                        DemoBanner(text: err, icon: "exclamationmark.triangle", color: Theme.red)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Thumb(post: post, width: 74)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Título").font(.caption).foregroundStyle(Theme.muted)
                            TextField("Título", text: $title, axis: .vertical)
                                .lineLimit(3...4).padding(12)
                                .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                                .onChange(of: title) { _, v in if v.count > 100 { title = String(v.prefix(100)) } }
                        }
                    }
                    Text("Hashtags").font(.caption).foregroundStyle(Theme.muted).padding(.top, 6)
                    TextField("#musica #envivo", text: $tags).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                    if NIM.isConfigured {
                        Button {
                            aiTags = true
                            Task {
                                do {
                                    let t = try await NIM.hashtags(title: title, networks: Array(networks))
                                    if !t.isEmpty { tags = t.joined(separator: " ") }
                                } catch { store.show(error.localizedDescription) }
                                aiTags = false
                            }
                        } label: { Label(aiTags ? "Pensando hashtags…" : "✨ Hashtags con IA", systemImage: "number") }
                            .font(.caption.bold()).foregroundStyle(Theme.accent).disabled(aiTags || title.isEmpty)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(groups, id: \.self) { g in
                                Button(g) {
                                    let have = Set(tags.split(separator: " ").map(String.init))
                                    let add = g.split(separator: " ").map(String.init).filter { !have.contains($0) }
                                    tags = (tags.trimmingCharacters(in: .whitespaces) + " " + add.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
                                }
                                .font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(Capsule().strokeBorder(Theme.line))
                            }
                            Button {
                                let t = tags.trimmingCharacters(in: .whitespaces)
                                guard !t.isEmpty, !groups.contains(t) else { return }
                                groupsRaw = (groups + [t]).joined(separator: "\n")
                                store.show("Grupo de hashtags guardado")
                            } label: { Label("Guardar grupo", systemImage: "plus") }
                                .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(Theme.accent).overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
                        }
                    }.scrollIndicators(.hidden)

                    DisclosureGroup(isExpanded: $perNetwork) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Network.allCases.filter { networks.contains($0) && $0.isReal }) { n in
                                HStack(alignment: .top, spacing: 8) {
                                    NetBadge(network: n).padding(.top, 10)
                                    TextField(n == .youtube ? "Título para YouTube (máx. 100)" : "Texto para \(n.name)",
                                              text: Binding(get: { custom[n.rawValue] ?? "" }, set: { custom[n.rawValue] = $0 }), axis: .vertical)
                                        .lineLimit(1...4).padding(10).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            Text("Si lo dejas vacío, se usa el título general.").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.top, 6)
                    } label: {
                        Text("Texto distinto por red").font(.footnote.bold())
                    }.tint(Theme.fg)

                    Text("Primer comentario (opcional)").font(.caption).foregroundStyle(Theme.muted).padding(.top, 6)
                    TextField("Se pone solo al publicarse: un link, más hashtags…", text: $firstComment, axis: .vertical)
                        .lineLimit(1...3).padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))

                    Text("Redes").font(.caption).foregroundStyle(Theme.muted).padding(.top, 6)
                    HStack(spacing: 8) {
                        ForEach(Network.allCases) { n in
                            let on = networks.contains(n)
                            Button {
                                if on { networks.remove(n) } else { networks.insert(n) }
                            } label: {
                                VStack(spacing: 6) {
                                    NetBadge(network: n)
                                    Text(n.name).font(.system(size: 11)).foregroundStyle(on ? Theme.fg : Theme.muted)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(on ? Theme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Theme.fg : Theme.line))
                            }.buttonStyle(.plain)
                        }
                    }

                    if networks.contains(.youtube) { youtubeBox(post) }
                    if networks.contains(.facebook) || networks.contains(.instagram) { metaBox(post) }

                    DatePicker("Día y hora", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "es"))
                        .padding(.top, 6)

                    let uploading = post.yt?.state == .uploading
                    HStack(spacing: 10) {
                        Button { approval(post) } label: { Label("Aprobación", systemImage: "link") }
                            .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.fg))
                        Button { publishNow(post) } label: { Label("Publicar ya", systemImage: "paperplane") }
                            .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.fg))
                    }.padding(.top, 12).disabled(uploading || busy)
                    Button { save(post) } label: { Text(saveLabel(post)) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(uploading || busy)
                    HStack(spacing: 10) {
                        if Publisher.hasVideo(post) && post.yt?.videoID == nil && post.fb == nil && post.ig == nil {
                            Button { studio = true } label: { Label("Estudio", systemImage: "wand.and.stars") }
                                .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.fg))
                        }
                        Button { _ = write(); if let id = store.duplicate(postID) { dismiss(); _ = id } } label: { Label("Duplicar", systemImage: "plus.square.on.square") }
                            .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.fg))
                    }.disabled(busy)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Eliminar", systemImage: "trash") }
                        .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.red)).disabled(uploading || busy)
                }
            }
            .navigationTitle(post?.yt == nil && post?.status == .scheduled && post?.videoFile != nil ? "Nuevo post" : "Editar post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                if let post { ToolbarItem(placement: .topBarTrailing) { StatusPill(status: post.status) } }
            }
            .onAppear(perform: load)
            .onChange(of: pick) { _, item in attach(item) }
            .fullScreenCover(isPresented: $studio) { StudioView(postID: postID) }
            .confirmationDialog("¿Eliminar este post?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if let post, let vid = post.yt?.videoID, post.yt?.state != .published {
                    Button("Eliminar aquí y en YouTube", role: .destructive) {
                        Task {
                            do { try await youtube.delete(videoID: vid, account: post.yt?.account); store.remove(postID); dismiss() }
                            catch { store.show(error.localizedDescription) }
                        }
                    }
                }
                Button("Eliminar de la app", role: .destructive) { store.remove(postID); dismiss(); store.show("Eliminado") }
            }
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func youtubeBox(_ post: Post) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                NetBadge(network: .youtube, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    switch post.yt?.state {
                    case .uploading:
                        Text("Subiendo a YouTube… \(Int((post.yt?.progress ?? 0) * 100))%").bold()
                        ProgressView(value: post.yt?.progress ?? 0)
                        Text("Deja la app abierta hasta que termine.").font(.caption).foregroundStyle(Theme.muted)
                    case .scheduled, .published, .privateLocked:
                        Text(post.yt?.state == .published ? "Publicado en YouTube" : post.yt?.state == .privateLocked ? "Subido, pero YouTube lo dejó privado" : "Subido · YouTube lo publica solo").bold()
                        Text(post.yt?.state == .privateLocked ? "La app de Google todavía no está verificada por YouTube."
                             : post.yt?.state == .scheduled ? "\(post.date.dayLabel) a las \(post.date.hm), aunque cierres la app." : "")
                            .font(.caption).foregroundStyle(Theme.muted)
                        if let vid = post.yt?.videoID, let url = URL(string: "https://youtu.be/\(vid)") {
                            Link("Ver en YouTube", destination: url).font(.caption.bold())
                        }
                    default:
                        if let err = post.yt?.error, post.yt?.state == .failed {
                            Text("No se pudo subir").bold().foregroundStyle(Theme.red)
                            Text(err).font(.caption).foregroundStyle(Theme.muted)
                        }
                        if !youtube.isConnected {
                            Text("YouTube sin conectar").bold()
                            Text("Conéctalo en Ajustes para subir este video.").font(.caption).foregroundStyle(Theme.muted)
                        } else if !Publisher.hasVideo(post) {
                            Text("Falta el archivo del video").bold()
                            PhotosPicker(selection: $pick, matching: .videos) { Label("Elegir video", systemImage: "video") }
                                .font(.caption.bold())
                        } else if post.yt?.state != .failed {
                            Text("Listo para subir").bold()
                            Text("Se sube al tocar Guardar y YouTube lo publica a la hora elegida.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func metaBox(_ post: Post) -> some View {
        Card {
            ForEach([Network.facebook, .instagram].filter { networks.contains($0) }) { n in
                let info = n == .facebook ? post.fb : post.ig
                let connected = n == .facebook ? meta.facebookConnected : meta.instagramConnected
                HStack(alignment: .top, spacing: 12) {
                    NetBadge(network: n, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metaTitle(n, info, connected)).bold()
                        Text(metaDetail(n, info, connected)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func metaTitle(_ n: Network, _ i: NetInfo?, _ connected: Bool) -> String {
        switch i?.state {
        case .working: "Publicando en \(n.name)…"
        case .scheduled: "Programado en \(n.name)"
        case .waiting: "Esperando la hora"
        case .published: "Publicado en \(n.name)"
        case .failed: "No se pudo publicar"
        case nil: connected ? "Listo para \(n.name)" : "\(n.name) sin conectar"
        }
    }

    private func metaDetail(_ n: Network, _ i: NetInfo?, _ connected: Bool) -> String {
        if let e = i?.error { return e }
        if i?.state == .waiting { return "Instagram no deja programar: se publica a la hora si la app está abierta o despierta en segundo plano." }
        if i == nil && !connected { return "Toca «Continuar con Facebook» en Ajustes." }
        if i == nil && n == .instagram { return "Se publica a la hora elegida (Instagram no permite programar por API)." }
        if i == nil { return "Facebook lo programa y lo publica solo a la hora elegida." }
        return ""
    }

    private func saveLabel(_ post: Post) -> String {
        Publisher.hasVideo(post) && ((networks.contains(.youtube) && post.yt?.videoID == nil && youtube.isConnected) || wantsMeta)
            ? "Guardar y programar" : "Guardar"
    }

    private func load() {
        guard !loaded, let post else { return }
        title = post.title; tags = post.tags; networks = post.networks; date = post.date; custom = post.custom ?? [:]; firstComment = post.firstComment ?? ""
        perNetwork = !(post.custom ?? [:]).values.allSatisfy { $0.isEmpty }; loaded = true
    }

    private func write() -> (changed: Bool, post: Post)? {
        guard let before = post else { return nil }
        store.update(postID) {
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.title : title
            $0.tags = tags
            $0.networks = networks
            $0.date = date
            $0.custom = custom.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            let fc = firstComment.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.firstComment = fc.isEmpty ? nil : fc
        }
        guard let after = post else { return nil }
        return (before.title != after.title || before.tags != after.tags || before.date != after.date || before.custom != after.custom, after)
    }

    private var wantsMeta: Bool {
        (networks.contains(.facebook) && meta.facebookConnected) || (networks.contains(.instagram) && meta.instagramConnected)
    }

    private func save(_ current: Post) {
        guard !networks.isEmpty else { return store.show("Elige al menos una red") }
        let uploaded = current.yt?.videoID != nil
        if (networks.contains(.youtube) && !uploaded || wantsMeta) && date < Date.now.addingTimeInterval(-60) {
            return store.show("Esa hora ya pasó. Elige otra o usa Publicar ya.")
        }
        guard let result = write() else { return }
        let changed = result.changed, p = result.post
        if p.status == .error { store.update(postID) { $0.status = .scheduled; $0.errorMessage = nil } }
        dismiss()
        let ytUpload = networks.contains(.youtube) && youtube.isConnected && !uploaded && Publisher.hasVideo(p)
        let ytUpdate = networks.contains(.youtube) && youtube.isConnected && uploaded && changed && p.yt?.state != .published
        let metaNow = wantsMeta && Publisher.hasVideo(p)
        if !ytUpload && !ytUpdate && !metaNow { return store.show("Guardado") }
        let (store, youtube, meta, id) = (store, youtube, meta, postID)
        Task {
            if ytUpload { await Publisher.upload(id, now: false, store: store, yt: youtube) }
            if ytUpdate { await Publisher.update(id, now: false, store: store, yt: youtube) }
            if metaNow { await Publisher.publishMeta(id, now: false, store: store, meta: meta) }
        }
    }

    private func publishNow(_ current: Post) {
        guard write() != nil else { return }
        dismiss()
        let (store, youtube, meta, id) = (store, youtube, meta, postID)
        let yt = networks.contains(.youtube) && youtube.isConnected
        let hasFile = Publisher.hasVideo(current)
        Task {
            if yt && current.yt?.videoID != nil { await Publisher.update(id, now: true, store: store, yt: youtube) }
            else if yt && hasFile { await Publisher.upload(id, now: true, store: store, yt: youtube) }
            if wantsMeta && hasFile { await Publisher.publishMeta(id, now: true, store: store, meta: meta) }
        }
    }

    private func approval(_ current: Post) {
        _ = write()
        store.update(postID) { $0.status = .approval }
        UIPasteboard.general.string = "Revisa este post: \(title)\n\(tags)\n\(date.dayLabel) a las \(date.hm)"
        store.show("Resumen copiado para enviarlo a tu cliente")
    }

    private func attach(_ item: PhotosPickerItem?) {
        guard let item else { return }
        busy = true
        Task {
            defer { busy = false; pick = nil }
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return store.show("No se pudo leer el video.") }
            store.update(postID) { $0.videoFile = movie.url.lastPathComponent; $0.yt = nil }
        }
    }
}
