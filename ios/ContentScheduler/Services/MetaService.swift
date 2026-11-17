import Foundation
import AuthenticationServices
import UIKit

/// Facebook e Instagram con el inicio de sesión de Meta (solo el App ID, que es público; el secreto no va en la app).
@Observable
@MainActor
final class MetaService: NSObject {
    struct Page: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let token: String
        var followers: Int?
        var igID: String?
        var igUsername: String?
        var igFollowers: Int?
        var igMedia: Int?
    }

    private(set) var pages: [Page] = []
    var selectedPageID: String? { didSet { UserDefaults.standard.set(selectedPageID, forKey: "meta.page") } }
    var page: Page? { pages.first { $0.id == selectedPageID } ?? pages.first }
    var facebookConnected: Bool { page != nil && tokenValid }
    var instagramConnected: Bool { page?.igID != nil && tokenValid }
    var hasAccount: Bool { !pages.isEmpty }

    private var expiry: Date { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "meta.expiry")) }
    var tokenValid: Bool { Date.now < expiry }
    private var authSession: ASWebAuthenticationSession?

    private let graph = "https://graph.facebook.com/v21.0/"
    private var appID: String { (Bundle.main.object(forInfoDictionaryKey: "MetaAppID") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    var isConfigured: Bool { !appID.isEmpty && appID.allSatisfy(\.isNumber) }

    override init() {
        super.init()
        if let raw = Keychain.get("meta.pages"), let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Page].self, from: data) { pages = saved }
        selectedPageID = UserDefaults.standard.string(forKey: "meta.page")
    }

    private func savePages() {
        if let data = try? JSONEncoder().encode(pages), let s = String(data: data, encoding: .utf8) { Keychain.set(s, for: "meta.pages") }
    }

    // MARK: Iniciar sesión

    func connect() async throws {
        guard isConfigured else { throw YTError(message: "Falta el App ID de Meta en Config.xcconfig.") }
        let scheme = "fb\(appID)"
        var c = URLComponents(string: "https://www.facebook.com/v21.0/dialog/oauth")!
        c.queryItems = [
            .init(name: "client_id", value: appID),
            .init(name: "redirect_uri", value: "\(scheme)://authorize"),
            .init(name: "response_type", value: "token"),
            .init(name: "auth_type", value: "rerequest"),
            .init(name: "scope", value: "pages_show_list,pages_read_engagement,pages_manage_posts,business_management,instagram_basic,instagram_content_publish,pages_read_user_content,pages_manage_engagement,instagram_manage_comments"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    cont.resume(throwing: YTError(message: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "Se cerró la ventana de Facebook." : "No se pudo abrir Facebook."))
                }
            }
            s.presentationContextProvider = self
            authSession = s
            s.start()
        }
        // El token viene después de «#»
        let fragment = callback.fragment ?? callback.query ?? ""
        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding }
        }
        guard let token = params["access_token"] else {
            throw YTError(message: params["error_description"]?.replacingOccurrences(of: "+", with: " ") ?? "No se dio permiso en Facebook.")
        }
        // Facebook a veces manda expires_in = 0 (sin caducidad corta): en ese caso se usa la fecha de acceso a datos o 60 días.
        var seconds = Double(params["expires_in"] ?? "") ?? 0
        if seconds <= 0, let access = Double(params["data_access_expiration_time"] ?? ""), access > Date.now.timeIntervalSince1970 {
            seconds = access - Date.now.timeIntervalSince1970
        }
        if seconds <= 0 { seconds = 60 * 86_400 }
        UserDefaults.standard.set(Date.now.addingTimeInterval(seconds).timeIntervalSince1970, forKey: "meta.expiry")
        try await loadPages(userToken: token)
    }

    func disconnect() {
        pages = []
        Keychain.delete("meta.pages")
        UserDefaults.standard.removeObject(forKey: "meta.expiry")
        selectedPageID = nil
    }

    private func loadPages(userToken: String) async throws {
        let json = try await get("me/accounts?fields=id,name,access_token,followers_count,instagram_business_account{id,username,followers_count,media_count}&limit=50", token: userToken)
        let list = (json["data"] as? [[String: Any]] ?? []).compactMap { p -> Page? in
            guard let id = p["id"] as? String, let token = p["access_token"] as? String else { return nil }
            let ig = p["instagram_business_account"] as? [String: Any]
            return Page(id: id, name: p["name"] as? String ?? "Página", token: token, followers: p["followers_count"] as? Int,
                        igID: ig?["id"] as? String, igUsername: ig?["username"] as? String,
                        igFollowers: ig?["followers_count"] as? Int, igMedia: ig?["media_count"] as? Int)
        }
        guard !list.isEmpty else {
            throw YTError(message: "Tu cuenta no tiene páginas de Facebook, o no diste permiso a ninguna. Instagram necesita una cuenta profesional vinculada a una página.")
        }
        pages = list
        if page == nil || !list.contains(where: { $0.id == selectedPageID }) { selectedPageID = list.first?.id }
        savePages()
    }

    /// Vuelve a leer seguidores de la página e Instagram.
    func refresh() async {
        guard let p = page, tokenValid else { return }
        guard let json = try? await get("\(p.id)?fields=followers_count,instagram_business_account{id,username,followers_count,media_count}", token: p.token),
              let i = pages.firstIndex(where: { $0.id == p.id }) else { return }
        pages[i].followers = json["followers_count"] as? Int ?? pages[i].followers
        if let ig = json["instagram_business_account"] as? [String: Any] {
            pages[i].igFollowers = ig["followers_count"] as? Int
            pages[i].igMedia = ig["media_count"] as? Int
        }
        savePages()
    }

    // MARK: Publicar

    /// Reel en la página de Facebook. Con fecha futura queda programado en Facebook (entre 10 minutos y 29 días).
    func publishFacebook(file: URL, description: String, at date: Date?) async throws -> String {
        guard let p = page, tokenValid else { throw expired }
        let start = try await post("\(p.id)/video_reels?upload_phase=start", token: p.token)
        guard let videoID = start["video_id"] as? String, let up = start["upload_url"] as? String, let upURL = URL(string: up) else {
            throw YTError(message: "Facebook no devolvió dónde subir el video.")
        }
        try await upload(file: file, to: upURL, token: p.token)
        var q = "\(p.id)/video_reels?upload_phase=finish&video_id=\(videoID)&description=\(enc(description))"
        if let date, date > Date.now.addingTimeInterval(10 * 60) {
            q += "&video_state=SCHEDULED&scheduled_publish_time=\(Int(date.timeIntervalSince1970))"
        } else {
            q += "&video_state=PUBLISHED"
        }
        _ = try await post(q, token: p.token)
        return videoID
    }

    /// Reel en Instagram. Instagram no permite programar por API: se publica en el momento.
    func publishInstagram(file: URL, caption: String) async throws -> String {
        guard let p = page, let ig = p.igID, tokenValid else { throw expired }
        let created: [String: Any]
        do {
            created = try await post("\(ig)/media?media_type=REELS&upload_type=resumable&share_to_feed=true&caption=\(enc(caption))", token: p.token)
        } catch let e as YTError {
            throw YTError(message: "Al preparar el reel — \(e.message)")
        }
        guard let container = created["id"] as? String, let uri = created["uri"] as? String, let upURL = URL(string: uri) else {
            throw YTError(message: "Instagram no devolvió dónde subir el video.")
        }
        try await upload(file: file, to: upURL, token: p.token)

        // Instagram procesa el video por su cuenta y tarda lo que quiere: un clip
        // largo puede pasar de los cinco minutos. Publicarlo antes de que termine
        // hace que Meta conteste «Request processing failed» sin más explicación.
        var listo = false
        for intento in 0..<120 {
            try await Task.sleep(for: .seconds(intento < 20 ? 3 : 5))
            let st = try await get("\(container)?fields=status_code,status", token: p.token)
            let code = st["status_code"] as? String ?? ""
            if code == "FINISHED" { listo = true; break }
            if code == "ERROR" || code == "EXPIRED" {
                throw YTError(message: "Instagram no pudo procesar el video: \(st["status"] as? String ?? code)")
            }
        }
        guard listo else {
            throw YTError(message: "Instagram lleva más de ocho minutos procesando el video y no termina. Suele pasar con clips largos o pesados. Prueba con uno más corto, o espera y vuelve a intentarlo.")
        }
        let pub: [String: Any]
        do {
            pub = try await post("\(ig)/media_publish?creation_id=\(container)", token: p.token)
        } catch let e as YTError {
            throw YTError(message: "Al publicarlo — \(e.message)")
        }
        return pub["id"] as? String ?? container
    }

    // MARK: Comentarios

    typealias Comment = YouTubeService.Comment

    /// Comentarios recientes de la página (Facebook) o de la cuenta de Instagram.
    func comments(_ n: Network) async throws -> [Comment] {
        guard let p = page, tokenValid else { throw expired }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func date(_ s: Any?) -> Date {
            guard let s = s as? String else { return .now }
            return iso.date(from: s.replacingOccurrences(of: "+0000", with: "Z")) ?? .now
        }
        var out: [Comment] = []
        if n == .facebook {
            let json = try await get("\(p.id)/feed?limit=15&fields=id,permalink_url,comments.limit(30).order(reverse_chronological){id,message,from,created_time,comments.limit(10){from}}", token: p.token)
            for post in json["data"] as? [[String: Any]] ?? [] {
                let link = post["permalink_url"] as? String
                for c in ((post["comments"] as? [String: Any])?["data"] as? [[String: Any]]) ?? [] {
                    guard let id = c["id"] as? String else { continue }
                    let from = c["from"] as? [String: Any]
                    if (from?["id"] as? String) == p.id { continue }
                    let replies = ((c["comments"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
                    let mine = replies.contains { (($0["from"] as? [String: Any])?["id"] as? String) == p.id }
                    out.append(Comment(id: "fb_" + id, commentID: id, videoID: "", author: from?["name"] as? String ?? "Alguien",
                                       text: c["message"] as? String ?? "", date: date(c["created_time"]), replied: mine, link: link))
                }
            }
        } else if n == .instagram, let ig = p.igID {
            let json = try await get("\(ig)/media?limit=15&fields=id,permalink,comments.limit(30){id,text,username,timestamp,replies{username}}", token: p.token)
            for m in json["data"] as? [[String: Any]] ?? [] {
                let link = m["permalink"] as? String
                for c in ((m["comments"] as? [String: Any])?["data"] as? [[String: Any]]) ?? [] {
                    guard let id = c["id"] as? String else { continue }
                    let user = c["username"] as? String ?? ""
                    if user == p.igUsername { continue }
                    let replies = ((c["replies"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
                    let mine = replies.contains { ($0["username"] as? String) == p.igUsername }
                    out.append(Comment(id: "ig_" + id, commentID: id, videoID: "", author: user.isEmpty ? "Alguien" : "@" + user,
                                       text: c["text"] as? String ?? "", date: date(c["timestamp"]), replied: mine, link: link))
                }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Comentario nuevo en un Reel/publicación propia (para «primer comentario»).
    func comment(_ n: Network, on objectID: String, text: String) async throws {
        guard let p = page, tokenValid else { throw expired }
        _ = try await post("\(objectID)/comments?message=\(enc(text))", token: p.token)
    }

    func reply(_ n: Network, to commentID: String, text: String) async throws {
        guard let p = page, tokenValid else { throw expired }
        _ = try await post(n == .instagram ? "\(commentID)/replies?message=\(enc(text))" : "\(commentID)/comments?message=\(enc(text))", token: p.token)
    }

    func hide(_ n: Network, commentID: String) async throws {
        guard let p = page, tokenValid else { throw expired }
        _ = try await post(n == .instagram ? "\(commentID)?hide=true" : "\(commentID)?is_hidden=true", token: p.token)
    }

    // MARK: HTTP

    private var expired: YTError { YTError(message: "La sesión de Facebook caducó. Toca «Continuar con Facebook» en Ajustes.") }
    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        try await call("GET", path, token: token)
    }
    private func post(_ path: String, token: String) async throws -> [String: Any] {
        try await call("POST", path, token: token)
    }
    private func call(_ method: String, _ path: String, token: String) async throws -> [String: Any] {
        let sep = path.contains("?") ? "&" : "?"
        var req = URLRequest(url: URL(string: graph + path + sep + "access_token=" + enc(token))!)
        req.httpMethod = method
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw Self.error(json) }
        return json
    }

    private func upload(file: URL, to url: URL, token: String) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "offset")
        req.setValue(String(size), forHTTPHeaderField: "file_size")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw Self.error((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
    }

    static func error(_ json: [String: Any]) -> YTError {
        let e = json["error"] as? [String: Any] ?? (json["debug_info"] as? [String: Any]) ?? [:]
        let code = e["code"] as? Int ?? 0
        let sub = e["error_subcode"] as? Int ?? 0
        let msg = e["error_user_msg"] as? String ?? e["message"] as? String ?? "error desconocido"
        if code == 190 { return YTError(message: "Facebook no aceptó la sesión (\(msg)). Toca «Continuar con Facebook» en Ajustes.") }
        if code == 10 || code == 200 {
            return YTError(message: "Meta no te deja hacer esto todavía: \(msg)\n\nSuele ser que tu app de Meta está en modo desarrollo, o que falta el permiso instagram_content_publish.")
        }
        // Meta devuelve «Request processing failed» para medio mundo. Lo que de
        // verdad distingue un caso de otro son el código y el subcódigo.
        if code == 1 || code == 2 {
            return YTError(message: "Meta falló sin decir por qué (código \(code)\(sub > 0 ? ", subcódigo \(sub)" : "")).\n\nRevisa que tu cuenta de Instagram sea profesional y esté vinculada a la página, y que tu app de Meta no esté en modo desarrollo.")
        }
        let detalle = sub > 0 ? "\(msg) (código \(code), subcódigo \(sub))" : "\(msg) (código \(code))"
        return YTError(message: "Meta: \(detalle)")
    }
}

extension MetaService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
