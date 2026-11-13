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
                $0.yt = YTInfo(videoID: videoID, state: now ? .published : .scheduled, progress: 1)
                $0.status = now ? .published : .scheduled
                if now { $0.date = .now }
            }
            store.deleteVideoFile(of: id)
            store.show(now ? "Publicado en YouTube" : "Subido. YouTube lo publica \(post.date.dayLabel.lowercased()) a las \(post.date.hm)")
        } catch {
            store.update(id) {
                $0.yt = YTInfo(state: .failed, error: error.localizedDescription)
                $0.status = .error
                $0.errorMessage = error.localizedDescription
            }
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
        try? await yt.refreshChannel()
        let ids = store.state.posts.compactMap { $0.yt?.videoID }
        guard !ids.isEmpty, let states = try? await yt.states(for: ids) else { return }
        for post in store.state.posts {
            guard let vid = post.yt?.videoID else { continue }
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
                    p.yt?.state = .published
                    p.status = .published
                    p.errorMessage = nil
                } else if p.date < Date.now.addingTimeInterval(-900) {
                    p.yt?.state = .privateLocked
                }
            }
        }
    }
}
