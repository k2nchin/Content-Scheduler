import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct YTChannel: Codable {
    var id: String
    var title: String
    var subscribers: Int?
    var views: Int
    var videos: Int
    var checked: Date
}

struct YTError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Conexión con YouTube usando el inicio de sesión oficial de Google (OAuth con PKCE, sin claves secretas en la app).
@Observable
@MainActor
final class YouTubeService: NSObject {
    private(set) var channel: YTChannel?
    var isConnected: Bool { channel != nil }

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private let scope = "https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/youtube.force-ssl"
    private var authSession: ASWebAuthenticationSession?

    private var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    private var redirectScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "yt.channel") { channel = try? JSONDecoder().decode(YTChannel.self, from: data) }
    }

    private func saveChannel() {
        UserDefaults.standard.set(channel.flatMap { try? JSONEncoder().encode($0) }, forKey: "yt.channel")
    }

    // MARK: Conectar / desconectar

    func connect() async throws {
        guard isConfigured else {
            throw YTError(message: "Falta el ID de cliente de Google para iOS en Config.xcconfig.")
        }
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    cont.resume(throwing: YTError(message: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "Se cerró la ventana de Google." : "No se pudo abrir Google."))
                }
            }
            session.presentationContextProvider = self
            authSession = session
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw YTError(message: "No se dio permiso para YouTube.")
        }
        let token = try await tokenRequest([
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirectURI,
        ])
        if let refresh = token.refresh_token { Keychain.set(refresh, for: "yt.refresh") }
        try await refreshChannel()
    }

    func disconnect() {
        if let refresh = Keychain.get("yt.refresh") {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(refresh)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.delete("yt.refresh")
        accessToken = nil
        channel = nil
        saveChannel()
    }

    // MARK: Tokens

    private struct TokenResponse: Decodable { let access_token: String; let expires_in: Int; let refresh_token: String? }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let t = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw YTError(message: "Google no aceptó la conexión. Vuelve a conectar YouTube en Ajustes.")
        }
        accessToken = t.access_token
        tokenExpiry = Date.now.addingTimeInterval(Double(t.expires_in - 60))
        return t
    }

    private func token() async throws -> String {
        if let accessToken, Date.now < tokenExpiry { return accessToken }
        guard let refresh = Keychain.get("yt.refresh") else {
            throw YTError(message: "Conecta YouTube en Ajustes.")
        }
        return try await tokenRequest(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"]).access_token
    }

    // MARK: API

    private func api(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { throw Self.error(status: status, json: json) }
        return json
    }

    static func error(status: Int, json: [String: Any]) -> YTError {
        let err = json["error"] as? [String: Any]
        let reason = ((err?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
        let msg = err?["message"] as? String ?? "error \(status)"
        switch (status, reason) {
        case (401, _): return YTError(message: "La conexión con YouTube caducó. Vuelve a conectar en Ajustes.")
        case (_, "quotaExceeded"): return YTError(message: "Se acabó la cuota diaria de YouTube. Se puede volver a subir mañana.")
        case (_, "uploadLimitExceeded"): return YTError(message: "YouTube no deja subir más videos hoy en este canal.")
        case (_, "youtubeSignupRequired"): return YTError(message: "Esta cuenta de Google no tiene canal de YouTube.")
        case (403, "insufficientPermissions"), (403, "ACCESS_TOKEN_SCOPE_INSUFFICIENT"):
            return YTError(message: "Falta el permiso de comentarios. Desconecta y vuelve a conectar YouTube en Ajustes.")
        case (_, "commentsDisabled"): return YTError(message: "Ese video tiene los comentarios desactivados.")
        case (_, "invalidPublishAt"): return YTError(message: "YouTube no aceptó esa hora. Elige una hora futura.")
        default:
            if status == 403 && msg.contains("has not been used") { return YTError(message: "La API de YouTube no está activada en Google Cloud.") }
            return YTError(message: "YouTube: \(msg)")
        }
    }

    func refreshChannel() async throws {
        let json = try await api("GET", "channels?part=snippet,statistics&mine=true")
        guard let item = (json["items"] as? [[String: Any]])?.first,
              let id = item["id"] as? String,
              let snippet = item["snippet"] as? [String: Any],
              let stats = item["statistics"] as? [String: Any] else {
            throw YTError(message: "Esta cuenta de Google no tiene canal de YouTube.")
        }
        let num = { (k: String) in Int(stats[k] as? String ?? "") ?? 0 }
        channel = YTChannel(id: id, title: snippet["title"] as? String ?? "Tu canal",
                            subscribers: (stats["hiddenSubscriberCount"] as? Bool) == true ? nil : num("subscriberCount"),
                            views: num("viewCount"), videos: num("videoCount"), checked: .now)
        saveChannel()
    }

    private func metadata(for post: Post, now: Bool) -> [String: Any] {
        let short = post.isVertical && post.duration <= 180
        var desc = post.title + "\n\n" + post.tags
        if short && !post.tags.lowercased().contains("#shorts") { desc += "\n#Shorts" }
        var status: [String: Any] = ["privacyStatus": now ? "public" : "private", "selfDeclaredMadeForKids": false]
        if !now { status["publishAt"] = ISO8601DateFormatter().string(from: post.date) }
        return [
            "snippet": ["title": String(post.title.prefix(100)), "description": String(desc.prefix(4900)),
                        "tags": Array(post.tagList.prefix(15)), "categoryId": "10"],
            "status": status,
        ]
    }

    /// Sube el video. Si no es "ahora", queda privado con hora de publicación y YouTube lo publica solo.
    func upload(post: Post, file: URL, now: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var initReq = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        initReq.httpMethod = "POST"
        initReq.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initReq.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        initReq.setValue("video/*", forHTTPHeaderField: "X-Upload-Content-Type")
        initReq.httpBody = try JSONSerialization.data(withJSONObject: metadata(for: post, now: now))
        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        guard let http = initResp as? HTTPURLResponse, http.statusCode == 200,
              let location = http.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            let json = (try? JSONSerialization.jsonObject(with: initData)) as? [String: Any] ?? [:]
            throw Self.error(status: (initResp as? HTTPURLResponse)?.statusCode ?? 0, json: json)
        }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let delegate = UploadProgress { sent in Task { @MainActor in progress(size > 0 ? Double(sent) / Double(size) : 0) } }
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let (data, resp) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: delegate)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if status == 200 || status == 201, let id = json["id"] as? String { return id }
                if (400..<500).contains(status) { throw Self.error(status: status, json: json) }
                lastError = YTError(message: "YouTube respondió \(status).")
            } catch let e as YTError {
                throw e
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .seconds(2 * (attempt + 1)))
        }
        throw YTError(message: "Se cortó la conexión varias veces (\(lastError?.localizedDescription ?? "")). Inténtalo con mejor señal.")
    }

    func update(post: Post, now: Bool) async throws {
        guard let id = post.yt?.videoID else { return }
        var body = metadata(for: post, now: now)
        body["id"] = id
        _ = try await api("PUT", "videos?part=snippet,status", body: body)
    }

    func delete(videoID: String) async throws {
        _ = try await api("DELETE", "videos?id=\(videoID)")
    }

    // MARK: Comentarios

    struct Comment: Identifiable, Hashable {
        let id: String          // id del hilo
        let commentID: String   // id del comentario principal (para responder)
        let videoID: String
        let author: String
        let text: String
        let date: Date
        var replied: Bool
    }

    /// Últimos comentarios de los videos del canal.
    func comments() async throws -> [Comment] {
        guard let ch = channel else { throw YTError(message: "Conecta YouTube en Ajustes.") }
        let json = try await api("GET", "commentThreads?part=snippet,replies&allThreadsRelatedToChannelId=\(ch.id)&maxResults=50&order=time&textFormat=plainText")
        let iso = ISO8601DateFormatter()
        return (json["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let thread = item["snippet"] as? [String: Any],
                  let top = thread["topLevelComment"] as? [String: Any],
                  let cid = top["id"] as? String,
                  let sn = top["snippet"] as? [String: Any] else { return nil }
            let author = (sn["authorChannelId"] as? [String: Any])?["value"] as? String
            if author == ch.id { return nil } // comentarios del propio canal
            let replies = ((item["replies"] as? [String: Any])?["comments"] as? [[String: Any]]) ?? []
            let mine = replies.contains { r in
                (((r["snippet"] as? [String: Any])?["authorChannelId"] as? [String: Any])?["value"] as? String) == ch.id
            }
            return Comment(id: id, commentID: cid, videoID: thread["videoId"] as? String ?? "",
                           author: sn["authorDisplayName"] as? String ?? "Alguien",
                           text: sn["textDisplay"] as? String ?? "",
                           date: iso.date(from: sn["publishedAt"] as? String ?? "") ?? .now,
                           replied: mine)
        }
    }

    func reply(to commentID: String, text: String) async throws {
        _ = try await api("POST", "comments?part=snippet", body: ["snippet": ["parentId": commentID, "textOriginal": text]])
    }

    struct VideoState { let isPublic: Bool; let failed: String?; let views: Int; let likes: Int }

    func states(for ids: [String]) async throws -> [String: VideoState] {
        var out: [String: VideoState] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)].joined(separator: ",")
            let json = try await api("GET", "videos?part=status,statistics&id=\(chunk)")
            for item in json["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let st = item["status"] as? [String: Any] ?? [:], stats = item["statistics"] as? [String: Any] ?? [:]
                let upload = st["uploadStatus"] as? String ?? ""
                out[id] = VideoState(isPublic: st["privacyStatus"] as? String == "public",
                                     failed: ["rejected", "failed"].contains(upload) ? (st["rejectionReason"] as? String ?? st["failureReason"] as? String ?? upload) : nil,
                                     views: Int(stats["viewCount"] as? String ?? "") ?? 0,
                                     likes: Int(stats["likeCount"] as? String ?? "") ?? 0)
            }
        }
        return out
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

extension YouTubeService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onSent: (Int64) -> Void
    init(_ onSent: @escaping (Int64) -> Void) { self.onSent = onSent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
    }
    static func set(_ value: String, for key: String) {
        delete(key)
        var q = base(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
