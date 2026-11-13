import Foundation

/// Une la cola de la app con YouTube: subir, actualizar, borrar y revisar estados.
@MainActor
enum Publisher {
    static func fileURL(_ post: Post) -> URL? {
        guard let name = post.videoFile else { return nil }
        let url = AppStore.videosDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func upload(_ id: UUID, now: Bool, store: AppStore, yt: YouTubeService) async {
        guard let post = store.post(id), let file = fileURL(post) else {
            store.show("Falta el archivo del video. Elígelo otra vez.")
            return
        }
        store.update(id) { $0.yt = YTInfo(state: .uploading); $0.errorMessage = nil }
        do {
            let videoID = try await yt.upload(post: post, file: file, now: now) { p in
                store.update(id) { $0.yt?.progress = min(p, 0.99) }
            }
            store.update(id) {
                $0.yt = YTInfo(videoID: videoID, state: now ? .published : .scheduled, progress: 1, account: yt.channel?.id)
                $0.status = now ? .published : .scheduled
                if now { $0.date = .now }
            }
            if let p = store.post(id), let cover = p.cover {
                if (try? await yt.setThumbnail(videoID: videoID, jpeg: cover)) != nil { store.update(id) { $0.yt?.coverSet = true } }
                else { store.show("La portada no se pudo poner: YouTube exige verificar tu canal por teléfono.") }
            }
            if let p = store.post(id), !needsFile(p) { store.deleteVideoFile(of: id) }
            Notifier.send(now ? "Publicado en YouTube" : "Programado en YouTube", post.title)
            store.show(now ? "Publicado en YouTube" : "Subido. YouTube lo publica \(post.date.dayLabel.lowercased()) a las \(post.date.hm)")
        } catch {
            store.update(id) {
                $0.yt = YTInfo(state: .failed, error: error.localizedDescription)
                $0.status = .error
                $0.errorMessage = error.localizedDescription
            }
            Notifier.send("No se pudo subir a YouTube", "\(post.title): \(error.localizedDescription)")
            store.show(error.localizedDescription)
        }
    }

    static func update(_ id: UUID, now: Bool, store: AppStore, yt: YouTubeService) async {
        guard let post = store.post(id) else { return }
        do {
            try await yt.update(post: post, now: now)
            if now { store.update(id) { $0.status = .published; $0.yt?.state = .published; $0.date = .now } }
            store.show(now ? "Publicado en YouTube" : "Cambios guardados también en YouTube")
        } catch {
            store.show(error.localizedDescription)
        }
    }

    static func refresh(store: AppStore, yt: YouTubeService) async {
        guard yt.isConnected else { return }
        for acc in yt.accounts { try? await yt.refreshChannel(account: acc.id) }
        // Revisar cada video con la cuenta que lo subió
        var states: [String: YouTubeService.VideoState] = [:]
        let byAccount = Dictionary(grouping: store.state.posts.filter { $0.yt?.videoID != nil }) { $0.yt?.account ?? yt.channel?.id ?? "" }
        for (acc, posts) in byAccount where yt.accounts.contains(where: { $0.id == acc }) {
            if let s = try? await yt.states(for: posts.compactMap { $0.yt?.videoID }, account: acc) { states.merge(s) { a, _ in a } }
            else { return }
        }
        var newlyPublished: [UUID] = []
        for post in store.state.posts {
            guard let vid = post.yt?.videoID else { continue }
            guard byAccount.keys.contains(post.yt?.account ?? yt.channel?.id ?? ""),
                  yt.accounts.contains(where: { $0.id == (post.yt?.account ?? yt.channel?.id) }) else { continue }
            store.update(post.id) { p in
                guard let s = states[vid] else {
                    p.yt?.state = .failed
                    p.yt?.error = "El video ya no existe en YouTube."
                    return
                }
                p.yt?.views = s.views
                p.yt?.likes = s.likes
                if let reason = s.failed {
                    p.status = .error
                    p.errorMessage = "YouTube rechazó el video (\(reason))."
                    p.yt?.state = .failed
                } else if s.isPublic {
                    if p.yt?.state != .published { Notifier.send("¡Ya se publicó en YouTube!", p.title); newlyPublished.append(post.id) }
                    p.yt?.state = .published
                    p.status = .published
                    p.errorMessage = nil
                } else if p.date < Date.now.addingTimeInterval(-900) {
                    p.yt?.state = .privateLocked
                }
            }
        }
        // Primer comentario cuando el video ya es público
        for p in store.state.posts where p.yt?.state == .published && p.yt?.commented != true {
            guard let text = p.firstComment?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let vid = p.yt?.videoID else { continue }
            if (try? await yt.comment(on: vid, text: text, account: p.yt?.account)) != nil {
                store.update(p.id) { $0.yt?.commented = true }
            }
        }
        _ = newlyPublished
    }

    // MARK: Facebook e Instagram

    /// El archivo se guarda hasta que todas las redes elegidas lo tengan.
    static func needsFile(_ p: Post) -> Bool {
        (p.networks.contains(.youtube) && p.yt?.videoID == nil)
            || (p.networks.contains(.facebook) && p.fb?.id == nil)
            || (p.networks.contains(.instagram) && p.ig?.state != .published)
    }

    static func caption(_ p: Post, _ n: Network) -> String { (p.text(for: n) + "\n\n" + p.tags).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func publishMeta(_ id: UUID, now: Bool, store: AppStore, meta: MetaService) async {
        guard let p = store.post(id), let file = fileURL(p) else { return }
        if p.networks.contains(.facebook), meta.facebookConnected, p.fb?.id == nil {
            store.update(id) { $0.fb = NetInfo(state: .working) }
            do {
                let vid = try await meta.publishFacebook(file: file, description: caption(p, .facebook), at: now ? nil : p.date)
                let scheduled = !now && p.date > Date.now.addingTimeInterval(10 * 60)
                store.update(id) { $0.fb = NetInfo(state: scheduled ? .scheduled : .published, id: vid) }
                if !scheduled, let text = p.firstComment, !text.isEmpty { try? await meta.comment(.facebook, on: vid, text: text) }
                Notifier.send(scheduled ? "Programado en Facebook" : "Publicado en Facebook", p.title)
                store.show(scheduled ? "Programado en Facebook" : "Publicado en Facebook")
            } catch {
                store.update(id) { $0.fb = NetInfo(state: .failed, error: error.localizedDescription); $0.status = .error; $0.errorMessage = error.localizedDescription }
                store.show(error.localizedDescription)
            }
        }
        if p.networks.contains(.instagram), meta.instagramConnected, p.ig?.state != .published {
            if now || p.date <= Date.now.addingTimeInterval(60) {
                await publishInstagram(id, store: store, meta: meta)
            } else {
                store.update(id) { $0.ig = NetInfo(state: .waiting) }
            }
        }
        settle(id, store: store)
    }

    static func publishInstagram(_ id: UUID, store: AppStore, meta: MetaService) async {
        guard let p = store.post(id), let file = fileURL(p) else { return }
        store.update(id) { $0.ig = NetInfo(state: .working) }
        do {
            let mid = try await meta.publishInstagram(file: file, caption: caption(p, .instagram))
            store.update(id) { $0.ig = NetInfo(state: .published, id: mid) }
            if let text = p.firstComment, !text.isEmpty { try? await meta.comment(.instagram, on: mid, text: text) }
            Notifier.send("Publicado en Instagram", p.title)
            store.show("Publicado en Instagram")
        } catch {
            store.update(id) { $0.ig = NetInfo(state: .failed, error: error.localizedDescription); $0.status = .error; $0.errorMessage = error.localizedDescription }
            Notifier.send("No se pudo publicar en Instagram", error.localizedDescription)
            store.show(error.localizedDescription)
        }
        settle(id, store: store)
    }

    /// Instagram no deja programar: lo que ya tocaba se publica cuando la app abre o despierta.
    static func publishDue(store: AppStore, meta: MetaService) async {
        guard meta.instagramConnected else { return }
        for p in store.state.posts where p.ig?.state == .waiting && p.date <= .now {
            await publishInstagram(p.id, store: store, meta: meta)
        }
    }

    private static func settle(_ id: UUID, store: AppStore) {
        guard let p = store.post(id) else { return }
        if !needsFile(p) { store.deleteVideoFile(of: id) }
        let states = [p.networks.contains(.facebook) ? p.fb?.state : nil, p.networks.contains(.instagram) ? p.ig?.state : nil].compactMap { $0 }
        if states.contains(.failed) { return }
        let ytDone = !p.networks.contains(.youtube) || p.yt?.state == .published
        if ytDone && !states.isEmpty && states.allSatisfy({ $0 == .published }) {
            store.update(id) { $0.status = .published; $0.errorMessage = nil }
        }
    }
}
