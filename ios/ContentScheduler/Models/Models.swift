import SwiftUI

enum Network: String, Codable, CaseIterable, Identifiable {
    case facebook, instagram, youtube, tiktok
    var id: String { rawValue }
    var name: String {
        switch self {
        case .facebook: "Facebook"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .tiktok: "TikTok"
        }
    }
    var short: String {
        switch self {
        case .facebook: "f"
        case .instagram: "ig"
        case .youtube: "yt"
        case .tiktok: "tt"
        }
    }
    var color: Color {
        switch self {
        case .facebook: Color(hex: 0x3B82F6)
        case .instagram: Color(hex: 0xE1306C)
        case .youtube: Color(hex: 0xFF3B30)
        case .tiktok: Color(hex: 0x25F4EE)
        }
    }
    /// Solo YouTube publica de verdad por ahora.
    var isReal: Bool { self == .youtube }
}

enum PostStatus: String, Codable {
    case scheduled, approval, error, published
    var label: String {
        switch self {
        case .scheduled: "Programado"
        case .approval: "En aprobación"
        case .error: "Error"
        case .published: "Publicado"
        }
    }
    var color: Color {
        switch self {
        case .scheduled: Theme.accent
        case .approval: Theme.warn
        case .error: Theme.red
        case .published: Theme.ok
        }
    }
}

enum YTState: String, Codable {
    case uploading, scheduled, published, privateLocked, failed
}

struct YTInfo: Codable, Hashable {
    var videoID: String?
    var state: YTState
    var progress: Double = 0
    var error: String?
    var views: Int?
    var likes: Int?
}

struct Post: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var tags: String
    var networks: Set<Network>
    var date: Date
    var status: PostStatus = .scheduled
    var duration: Int = 30
    var isVertical: Bool = true
    /// Nombre del archivo de video guardado en la app (Documents/videos). Se borra al terminar de subir.
    var videoFile: String?
    var thumbnail: Data?
    var gradient: Int = 0
    var errorMessage: String?
    var yt: YTInfo?

    var durationText: String { "\(duration / 60):" + String(format: "%02d", duration % 60) }
    var tagList: [String] {
        tags.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }
}

struct AppState: Codable {
    var posts: [Post] = []
    var slots: [String] = ["09:00", "13:00", "18:30", "21:00"]
    var demoAccounts: [Network: Bool] = [.facebook: true, .instagram: true, .tiktok: true]
    var telegram = false
    var viralAlert = true
    var weeklyReport = true
}
