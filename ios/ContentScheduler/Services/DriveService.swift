import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Google Drive: guarda los clips y deja elegir videos tuyos para clipear.
/// Solo puede escribir en lo que ella misma crea; de lo tuyo, solo leer.
@Observable
@MainActor
final class DriveService: NSObject {
    static let shared = DriveService()

    private(set) var email: String?
    var isConnected: Bool { email != nil && Keychain.get("drive.refresh") != nil }
    /// Guardar los clips en Drive en vez de en el iPhone.
    var useDrive: Bool {
        get { UserDefaults.standard.object(forKey: "drive.use") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "drive.use") }
    }

    private var token: (value: String, exp: Date)?
    private var authSession: ASWebAuthenticationSession?
    /// `drive.file` para guardar lo que crea la app, y `drive.readonly` para
    /// poder enseñarte tus videos y bajarlos. Nunca borra ni cambia nada tuyo.
    private let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/drive.readonly openid email"

    private var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    private var redirectScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    override init() {
        super.init()
        email = UserDefaults.standard.string(forKey: "drive.email")
    }

    // MARK: Conectar

    func connect() async throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com") else { throw YTError(message: "Falta el ID de cliente de Google para iOS.") }
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    cont.resume(throwing: YTError(message: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "Se cerró la ventana de Google." : "No se pudo abrir Google."))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            authSession = s
            s.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw YTError(message: "No se dio permiso para Google Drive.")
        }
        let t = try await tokenRequest(["client_id": clientID, "code": code, "code_verifier": verifier,
                                        "grant_type": "authorization_code", "redirect_uri": redirectURI])
        guard let refresh = t.refresh_token else { throw YTError(message: "Google no devolvió el permiso de Drive. Inténtalo otra vez.") }
        Keychain.set(refresh, for: "drive.refresh")
        token = (t.access_token, Date.now.addingTimeInterval(Double(t.expires_in - 60)))
        // Correo de la cuenta, para mostrarlo en Ajustes
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)
        req.setValue("Bearer \(t.access_token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let mail = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["user"] as? [String: Any])?["emailAddress"] as? String
        email = mail ?? "Google Drive"
        UserDefaults.standard.set(email, forKey: "drive.email")
    }

    func disconnect() {
        if let r = Keychain.get("drive.refresh") {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(r)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.delete("drive.refresh")
        UserDefaults.standard.removeObject(forKey: "drive.email")
        UserDefaults.standard.removeObject(forKey: "drive.folder")
        email = nil
        token = nil
    }

    private struct TokenResponse: Decodable { let access_token: String; let expires_in: Int; let refresh_token: String? }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let t = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw YTError(message: "Google Drive no aceptó la conexión. Vuelve a conectarlo en Ajustes.")
        }
        return t
    }

    func accessToken() async throws -> String {
        if let token, Date.now < token.exp { return token.value }
        guard let r = Keychain.get("drive.refresh") else { throw YTError(message: "Conecta Google Drive en Ajustes.") }
        let t = try await tokenRequest(["client_id": clientID, "refresh_token": r, "grant_type": "refresh_token"])
        token = (t.access_token, Date.now.addingTimeInterval(Double(t.expires_in - 60)))
        return t.access_token
    }

    private func check(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "error \(status)"
            if status == 403 && msg.contains("has not been used") { throw YTError(message: "La API de Google Drive no está activada en Google Cloud.") }
            if status == 403 && msg.lowercased().contains("quota") { throw YTError(message: "Tu Google Drive está lleno.") }
            // La conexión de antes no pedía permiso para leer tus videos.
            if status == 403 || msg.lowercased().contains("insufficient") {
                throw YTError(message: "Para ver tus videos hay que reconectar Drive: Ajustes → Google Drive → desconectar y conectar otra vez.")
            }
            throw YTError(message: "Google Drive: \(msg)")
        }
        return json
    }

    // MARK: Carpeta, subir y bajar

    private func folderID() async throws -> String {
        if let id = UserDefaults.standard.string(forKey: "drive.folder") { return id }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": "Content Scheduler", "mimeType": "application/vnd.google-apps.folder"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let id = try check(data, resp)["id"] as? String else { throw YTError(message: "No se pudo crear la carpeta en Drive.") }
        UserDefaults.standard.set(id, forKey: "drive.folder")
        return id
    }

    /// Sube un video a la carpeta «Content Scheduler» y devuelve su id en Drive.
    func upload(_ file: URL, name: String) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [try await folderID()]])
        let (d1, r1) = try await URLSession.shared.data(for: start)
        _ = try check(d1, r1)
        guard let loc = (r1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) else {
            throw YTError(message: "Google Drive no devolvió dónde subir el video.")
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (d2, r2) = try await URLSession.shared.upload(for: put, fromFile: file)
        guard let id = try check(d2, r2)["id"] as? String else { throw YTError(message: "No se pudo guardar el video en Drive.") }
        return id
    }

    // MARK: Mirar lo que tienes

    /// Un archivo o una carpeta de tu Drive.
    struct Item: Identifiable, Hashable {
        let id: String
        let name: String
        let isFolder: Bool
        let size: Int
        /// Cuándo se subió, para poder ordenar por lo más reciente.
        let date: Date?

        var sizeLabel: String {
            guard size > 0 else { return "" }
            let mb = Double(size) / 1_048_576
            return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
        }
    }

    /// Lo que hay en una carpeta: primero las carpetas, luego los videos.
    /// Sin carpeta, lo de la raíz de tu Drive.
    func list(in folder: String? = nil, search: String = "") async throws -> [Item] {
        var condiciones = ["trashed = false"]
        let limpio = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty {
            condiciones.append("'\(folder ?? "root")' in parents")
        } else {
            // Al buscar se mira todo el Drive, no solo esta carpeta.
            condiciones.append("name contains '\(limpio.replacingOccurrences(of: "'", with: "\\'"))'")
        }
        condiciones.append("(mimeType contains 'video/' or mimeType = 'application/vnd.google-apps.folder')")

        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: condiciones.joined(separator: " and ")),
            .init(name: "fields", value: "files(id,name,mimeType,size,modifiedTime)"),
            .init(name: "orderBy", value: "folder,modifiedTime desc"),
            .init(name: "pageSize", value: "200"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try check(data, resp)
        let fechas = ISO8601DateFormatter()
        return ((json["files"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["id"] as? String, let nombre = f["name"] as? String else { return nil }
            let tipo = (f["mimeType"] as? String) ?? ""
            return Item(id: id,
                        name: nombre,
                        isFolder: tipo == "application/vnd.google-apps.folder",
                        size: Int((f["size"] as? String) ?? "") ?? 0,
                        date: fechas.date(from: (f["modifiedTime"] as? String) ?? ""))
        }
    }

    /// Baja un video de Drive a la carpeta de videos de la app (solo mientras se publica).
    func download(_ id: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw YTError(message: "No se pudo bajar el video de Drive (¿lo borraste de la carpeta?).")
        }
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

extension DriveService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
