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
        case .facebook: Color(hex: 0x0866FF)
        case .instagram: Color(hex: 0xE1306C)
        case .youtube: Color(hex: 0xFF0000)
        case .tiktok: Color(hex: 0x25F4EE)
        }
    }
    /// Logo de la red (Simple Icons, CC0) en Assets.xcassets.
    var logo: String { "logo-" + rawValue }
    /// Redes que ya publican de verdad (TikTok todavía no).
    var isReal: Bool { self != .tiktok }
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
    /// Canal de YouTube al que se subió.
    var account: String?
    /// Ya se puso el primer comentario.
    var commented: Bool?
    /// Ya se subió la portada.
    var coverSet: Bool?
}

/// Estado de la publicación en Facebook o Instagram.
struct NetInfo: Codable, Hashable {
    enum State: String, Codable { case working, scheduled, waiting, published, failed }
    var state: State
    var id: String?
    var error: String?
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
    /// Id del video en tu Google Drive (carpeta «Content Scheduler»).
    var driveID: String?
    var thumbnail: Data?
    var gradient: Int = 0
    var errorMessage: String?
    var yt: YTInfo?
    var fb: NetInfo?
    /// Título o texto distinto por red (clave: rawValue de la red). Vacío = usar el título general.
    var custom: [String: String]?
    /// Comentario que se pone solo al publicarse (YouTube, Facebook, Instagram).
    var firstComment: String?
    /// Portada elegida en el Estudio (JPEG).
    var cover: Data?
    var ig: NetInfo?

    func text(for n: Network) -> String {
        let t = custom?[n.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? title : t
    }

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
