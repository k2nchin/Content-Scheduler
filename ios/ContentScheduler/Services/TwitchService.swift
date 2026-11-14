import Foundation
import UIKit

/// Twitch por la API oficial: crear clips de un directo (a mano o cuando el chat explota)
/// y, en TU canal, bajar el clip para pasarlo a 9:16 con seguimiento de cara y subtítulos.
@Observable
@MainActor
final class TwitchService: NSObject {
    static let shared = TwitchService()

    struct Clip: Identifiable, Codable, Hashable {
        let id: String
        let channel: String
        let broadcasterID: String
        let created: Date
        let reason: String
        var url: String?
        var thumbnail: String?
        var title: String?
    }

    private(set) var login: String?
    private(set) var userID: String?
    var isConnected: Bool { login != nil && Keychain.get("twitch.refresh") != nil }

    // Inicio de sesión con código (sin contraseñas en la app)
    var userCode: String?
    var verifyURL: URL?

    // Vigilancia del chat
    var watching = false
    var channel = ""
    var isLive = false
    var viewers = 0
    var perMinute = 0
    var clips: [Clip] = [] { didSet { save() } }
    var lastEvent = ""

    private var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "TwitchClientID") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    var isConfigured: Bool { !clientID.isEmpty }
    private let scopes = "clips:edit editor:manage:clips channel:manage:clips"
    private var token: (value: String, exp: Date)?
    private var socket: URLSessionWebSocketTask?
    private var times: [Date] = []
    private var keywordHits: [Date] = []
    private var baseline = 3.0
    private var lastClip = Date.distantPast
    private var broadcasterID: String?
    private var statusTimer: Timer?

    override init() {
        super.init()
        login = UserDefaults.standard.string(forKey: "twitch.login")
        userID = UserDefaults.standard.string(forKey: "twitch.id")
        if let d = UserDefaults.standard.data(forKey: "twitch.clips"), let c = try? JSONDecoder().decode([Clip].self, from: d) { clips = c }
        channel = login ?? ""
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(Array(clips.prefix(200))), forKey: "twitch.clips") }

    // MARK: Conectar (Device Code Flow: código en twitch.tv/activate)

    func connect() async throws {
        guard isConfigured else { throw YTError(message: "Falta el Client ID de Twitch (TWITCH_CLIENT_ID) en la configuración de la app.") }
        let start = try await form("https://id.twitch.tv/oauth2/device", ["client_id": clientID, "scopes": scopes])
        guard let device = start["device_code"] as? String, let code = start["user_code"] as? String else {
            throw YTError(message: "Twitch no devolvió un código. Revisa que tu app de Twitch sea de tipo «Pública».")
        }
        userCode = code
        verifyURL = URL(string: start["verification_uri"] as? String ?? "https://www.twitch.tv/activate")
        if let verifyURL { await UIApplication.shared.open(verifyURL) }
        let interval = Double(start["interval"] as? Int ?? 5)
        let deadline = Date.now.addingTimeInterval(Double(start["expires_in"] as? Int ?? 1800))
        defer { userCode = nil; verifyURL = nil }
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let r = try? await form("https://id.twitch.tv/oauth2/token", [
                "client_id": clientID, "scopes": scopes, "device_code": device,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let access = r?["access_token"] as? String {
                if let refresh = r?["refresh_token"] as? String { Keychain.set(refresh, for: "twitch.refresh") }
                token = (access, Date.now.addingTimeInterval(Double(r?["expires_in"] as? Int ?? 3600) - 60))
                let me = try await helix("GET", "users")
                let u = (me["data"] as? [[String: Any]])?.first
                login = u?["login"] as? String
                userID = u?["id"] as? String
                UserDefaults.standard.set(login, forKey: "twitch.login")
                UserDefaults.standard.set(userID, forKey: "twitch.id")
                if channel.isEmpty { channel = login ?? "" }
                return
            }
        }
        throw YTError(message: "Se venció el código de Twitch. Vuelve a intentarlo.")
    }

    func disconnect() {
        stopWatching()
        Keychain.delete("twitch.refresh")
        token = nil
        login = nil; userID = nil
        UserDefaults.standard.removeObject(forKey: "twitch.login")
        UserDefaults.standard.removeObject(forKey: "twitch.id")
    }

    // MARK: HTTP

    private func form(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func accessToken() async throws -> String {
        if let token, Date.now < token.exp { return token.value }
        guard let refresh = Keychain.get("twitch.refresh") else { throw YTError(message: "Conecta Twitch primero.") }
        let r = try await form("https://id.twitch.tv/oauth2/token", ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        guard let access = r["access_token"] as? String else { throw YTError(message: "La sesión de Twitch caducó. Vuelve a conectar Twitch.") }
        if let newRefresh = r["refresh_token"] as? String { Keychain.set(newRefresh, for: "twitch.refresh") }
        token = (access, Date.now.addingTimeInterval(Double(r["expires_in"] as? Int ?? 3600) - 60))
        return access
    }

    private func helix(_ method: String, _ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = json["message"] as? String ?? "error \(status)"
            if status == 403 { throw YTError(message: "Twitch no dejó hacer el clip: \(msg) (el canal puede tener los clips desactivados).") }
            if status == 404 { throw YTError(message: "Twitch: el canal no está en vivo o no existe.") }
            throw YTError(message: "Twitch: \(msg)")
        }
        return json
    }

    // MARK: Clips

    @discardableResult
    func createClip(reason: String) async throws -> Clip {
        guard let bid = broadcasterID else { throw YTError(message: "Elige un canal en vivo primero.") }
        let r = try await helix("POST", "clips?broadcaster_id=\(bid)")
        guard let id = (r["data"] as? [[String: Any]])?.first?["id"] as? String else { throw YTError(message: "Twitch no devolvió el clip.") }
        lastClip = .now
        let clip = Clip(id: id, channel: channel, broadcasterID: bid, created: .now, reason: reason)
        clips.insert(clip, at: 0)
        lastEvent = "✂️ Clip creado (\(reason))"
        Notifier.send("✂️ Clip de Twitch", "\(channel): \(reason)")
        // Twitch tarda unos segundos en procesarlo; luego se piden los detalles
        Task {
            try? await Task.sleep(for: .seconds(15))
            await self.refreshDetails(id)
        }
        return clip
    }

    func refreshDetails(_ id: String) async {
        guard let r = try? await helix("GET", "clips?id=\(id)"),
              let d = (r["data"] as? [[String: Any]])?.first,
              let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].url = d["url"] as? String
        clips[i].thumbnail = d["thumbnail_url"] as? String
        clips[i].title = d["title"] as? String
    }

    /// Solo en tu canal (o donde eres editor): baja el MP4 del clip.
    func download(_ clip: Clip) async throws -> URL {
        guard let me = userID else { throw YTError(message: "Conecta Twitch primero.") }
        let r = try await helix("GET", "clips/downloads?editor_id=\(me)&broadcaster_id=\(clip.broadcasterID)&clip_id=\(clip.id)")
        let d = (r["data"] as? [[String: Any]])?.first
        guard let s = (d?["landscape_download_url"] as? String) ?? (d?["portrait_download_url"] as? String), let url = URL(string: s) else {
            throw YTError(message: "No tienes permiso para bajar clips de este canal. Pídele al streamer que te haga «Editor» en Twitch (Panel de control → Comunidad → Roles).")
        }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dest = AppStore.videosDir.appendingPathComponent("twitch-\(clip.id).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: Vigilar el chat (detecta cuando el chat explota)

    private static let hype = ["jaja", "jsjs", "lol", "lmao", "kekw", "lul", "omg", "🔥", "😂", "🤣", "💀", "clip", "wtf", "que lo que", "klk", "diache", "coño"]

    func startWatching() async throws {
        let ch = channel.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard !ch.isEmpty else { throw YTError(message: "Escribe el canal de Twitch.") }
        channel = ch
        let u = try await helix("GET", "users?login=\(ch)")
        guard let bid = (u["data"] as? [[String: Any]])?.first?["id"] as? String else { throw YTError(message: "No existe el canal «\(ch)» en Twitch.") }
        broadcasterID = bid
        await refreshStatus()
        stopWatching()
        watching = true
        times = []; keywordHits = []; baseline = 3
        let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket = task
        task.resume()
        try await task.send(.string("NICK justinfan\(Int.random(in: 10000...99999))"))   // lectura anónima del chat
        try await task.send(.string("JOIN #\(ch)"))
        lastEvent = "Vigilando el chat de \(ch)…"
        listen(task)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshStatus() } }
        }
        Task { while self.watching { try? await Task.sleep(for: .seconds(5)); self.evaluate() } }
    }

    func stopWatching() {
        watching = false
        statusTimer?.invalidate()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func refreshStatus() async {
        guard let bid = broadcasterID, let r = try? await helix("GET", "streams?user_id=\(bid)") else { return }
        let s = (r["data"] as? [[String: Any]])?.first
        isLive = s != nil
        viewers = s?["viewer_count"] as? Int ?? 0
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.watching else { return }
                if case .success(.string(let text)) = result {
                    for line in text.split(separator: "\r\n") {
                        if line.hasPrefix("PING") { try? await task.send(.string("PONG :tmi.twitch.tv")); continue }
                        guard line.contains(" PRIVMSG ") else { continue }
                        let msg = line.split(separator: ":", maxSplits: 2).last.map(String.init)?.lowercased() ?? ""
                        self.times.append(.now)
                        if Self.hype.contains(where: { msg.contains($0) }) { self.keywordHits.append(.now) }
                    }
                }
                if case .failure = result { self.lastEvent = "Se cortó el chat; vuelve a tocar «Vigilar»."; self.watching = false; return }
                self.listen(task)
            }
        }
    }

    /// Cada 5 s: si el ritmo del chat se dispara (≥3× lo normal) o hay muchas risas/🔥, crea un clip.
    private func evaluate() {
        let now = Date.now
        times.removeAll { now.timeIntervalSince($0) > 60 }
        keywordHits.removeAll { now.timeIntervalSince($0) > 15 }
        let last10 = Double(times.filter { now.timeIntervalSince($0) <= 10 }.count)
        perMinute = times.count
        let rate = last10 / 10                  // mensajes por segundo ahora
        let spike = rate >= max(baseline * 3, 0.8)
        let hype = keywordHits.count >= 6
        baseline = baseline * 0.95 + max(rate, 0.05) * 0.05
        guard isLive, spike || hype, now.timeIntervalSince(lastClip) > 60 else { return }
        Task {
            do { try await createClip(reason: spike ? "el chat explotó (\(Int(rate * 60)) msj/min)" : "muchas reacciones en el chat") }
            catch { lastEvent = error.localizedDescription }
        }
    }
}
