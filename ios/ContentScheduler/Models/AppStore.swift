import SwiftUI
import AVFoundation

@Observable
@MainActor
final class AppStore {
    var state = AppState() { didSet { persist() } }
    var toast: String?
    /// Video que llegó desde otra app con «Compartir → Content Scheduler».
    var incomingVideo: URL?
    /// Redes conectadas de verdad (las elige por defecto cada video nuevo).
    var connected: Set<Network> = []

    nonisolated static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let videosDir: URL = {
        let dir = documents.appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let stateURL = documents.appendingPathComponent("state.json")

    init() {
        if let data = try? Data(contentsOf: Self.stateURL), let saved = try? JSONDecoder().decode(AppState.self, from: data) {
            state = saved
        }
        // Una subida que quedó a medias al cerrar la app se marca para reintentar.
        for i in state.posts.indices where state.posts[i].yt?.state == .uploading {
            state.posts[i].yt = YTInfo(state: .failed, error: "La subida se interrumpió. Toca Guardar para reintentar.")
            state.posts[i].status = .error
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(2.6)); if toast == message { toast = nil } }
    }

    func index(of id: UUID) -> Int? { state.posts.firstIndex { $0.id == id } }
    func post(_ id: UUID) -> Post? { state.posts.first { $0.id == id } }
    func update(_ id: UUID, _ change: (inout Post) -> Void) {
        guard let i = index(of: id) else { return }
        change(&state.posts[i])
    }

    var upcoming: [Post] { state.posts.filter { $0.status != .published }.sorted { $0.date < $1.date } }
    var published: [Post] { state.posts.filter { $0.status == .published }.sorted { $0.date > $1.date } }

    /// Siguiente horario libre según los horarios elegidos.
    func nextFreeSlot(after: Date = .now) -> Date {
        let taken = Set(state.posts.filter { $0.status != .published }.map { Int($0.date.timeIntervalSince1970 / 60) })
        let cal = Calendar.current
        let slots = state.slots.sorted().compactMap { s -> (Int, Int)? in
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        for d in 0..<60 {
            guard let day = cal.date(byAdding: .day, value: d, to: max(after, .now)) else { continue }
            for (h, m) in slots {
                guard let t = cal.date(bySettingHour: h, minute: m, second: 0, of: day) else { continue }
                if t > .now && t > after.addingTimeInterval(-1) && !taken.contains(Int(t.timeIntervalSince1970 / 60)) { return t }
            }
        }
        return Date.now.addingTimeInterval(86_400)
    }

    func defaultNetworks(youtubeConnected: Bool) -> Set<Network> {
        var set = connected
        if youtubeConnected { set.insert(.youtube) }
        return set
    }

    /// Copia el video a la app, lee duración, orientación y miniatura, y crea el post.
    func addVideo(from url: URL, youtubeConnected: Bool, at date: Date? = nil) async -> UUID {
        let asset = AVURLAsset(url: url)
        var duration = 30, vertical = true
        if let d = try? await asset.load(.duration) { duration = max(1, Int(d.seconds.rounded())) }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = size.applying(t)
            vertical = abs(r.height) >= abs(r.width)
        }
        var thumb: Data?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        if let result = try? await gen.image(at: CMTime(seconds: min(1, Double(duration) / 3), preferredTimescale: 600)) {
            thumb = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.6)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let title = name.count > 30 || name.hasPrefix("IMG") || UUID(uuidString: name) != nil ? "Nuevo clip" : name.replacingOccurrences(of: "_", with: " ")
        let post = Post(title: String(title.prefix(100)), tags: "#viral #reels",
                        networks: defaultNetworks(youtubeConnected: youtubeConnected),
                        date: date ?? nextFreeSlot(), duration: duration, isVertical: vertical,
                        videoFile: url.lastPathComponent, thumbnail: thumb, gradient: state.posts.count % Theme.gradients.count)
        state.posts.append(post)
        return post.id
    }

    /// Cambia el video de un post por uno nuevo (por ejemplo, el que sale del Estudio).
    func replaceVideo(of id: UUID, with url: URL) async {
        let asset = AVURLAsset(url: url)
        var duration = 30
        if let d = try? await asset.load(.duration) { duration = max(1, Int(d.seconds.rounded())) }
        var thumb: Data?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        if let r = try? await gen.image(at: CMTime(seconds: min(1, Double(duration) / 3), preferredTimescale: 600)) {
            thumb = UIImage(cgImage: r.image).jpegData(compressionQuality: 0.6)
        }
        deleteVideoFile(of: id)
        update(id) {
            $0.videoFile = url.lastPathComponent
            $0.duration = duration
            if let thumb { $0.thumbnail = thumb }
        }
    }

    func deleteVideoFile(of id: UUID) {
        guard let name = post(id)?.videoFile else { return }
        try? FileManager.default.removeItem(at: Self.videosDir.appendingPathComponent(name))
        update(id) { $0.videoFile = nil }
    }

    func remove(_ id: UUID) {
        deleteVideoFile(of: id)
        state.posts.removeAll { $0.id == id }
    }

    /// Copia del post (con su video si todavía está en la app) en el siguiente horario libre.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard var copy = post(id) else { return nil }
        copy.id = UUID()
        copy.status = .scheduled
        copy.errorMessage = nil
        copy.yt = nil; copy.fb = nil; copy.ig = nil
        if let name = copy.videoFile {
            let src = Self.videosDir.appendingPathComponent(name)
            let dest = Self.videosDir.appendingPathComponent(UUID().uuidString + "." + src.pathExtension)
            copy.videoFile = (try? FileManager.default.copyItem(at: src, to: dest)) != nil ? dest.lastPathComponent : nil
        }
        copy.date = nextFreeSlot()
        state.posts.append(copy)
        show("Post duplicado para \(copy.date.dayLabel.lowercased()) a las \(copy.date.hm)")
        return copy.id
    }

    func recycle(_ id: UUID) {
        guard var copy = post(id) else { return }
        copy.id = UUID()
        copy.status = .scheduled
        copy.errorMessage = nil
        copy.yt = nil; copy.fb = nil; copy.ig = nil
        copy.videoFile = nil
        copy.date = nextFreeSlot()
        copy.tags = ["#parati", "#fyp", "#tendencia", "#viral", "#reels"].shuffled().prefix(3).joined(separator: " ")
        state.posts.append(copy)
        show("De vuelta en la cola con hashtags nuevos")
    }

    // MARK: Estados como en tu app

    func isScheduled(_ p: Post) -> Bool { p.yt?.videoID != nil && p.status == .scheduled }
    var porProgramar: [Post] { upcoming.filter { $0.status != .error && $0.status != .approval && !isScheduled($0) } }
    var programados: [Post] { upcoming.filter { isScheduled($0) } }
    var porRevisar: [Post] { upcoming.filter { $0.status == .error || $0.status == .approval } }

    /// Vuelve a repartir lo que falta por programar en los siguientes horarios libres, en orden.
    func reorganize() {
        let ids = porProgramar.sorted { $0.date < $1.date }.map(\.id)
        for id in ids { update(id) { $0.date = .distantFuture } }
        var after = Date.now
        for id in ids {
            let t = nextFreeSlot(after: after)
            update(id) { $0.date = t }
            after = t.addingTimeInterval(60)
        }
        show("Cola reorganizada")
    }

    /// Borra de la app todo lo que no se ha publicado (lo ya subido a YouTube se queda en YouTube).
    func clearQueue() {
        for p in upcoming { deleteVideoFile(of: p.id) }
        state.posts.removeAll { $0.status != .published }
        show("Cola borrada")
    }
}
