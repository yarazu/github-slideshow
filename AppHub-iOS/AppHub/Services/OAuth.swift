import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

/// Beschreibt einen OAuth-2.0-Anbieter mit PKCE (ohne Client-Secret).
struct OAuthProvider {
    let id: String
    let displayName: String
    let authorizeURL: URL
    let tokenURL: URL
    let scopes: [String]
    let clientIDKey: String
    let extraParameters: [String: String]
    /// Redirect-URI und Callback-Schema, abgeleitet aus der Client-ID.
    let redirect: (String) -> (uri: String, scheme: String)

    var clientID: String {
        (UserDefaults.standard.string(forKey: clientIDKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let google = OAuthProvider(
        id: "google",
        displayName: "Google",
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scopes: ["https://www.googleapis.com/auth/gmail.readonly"],
        clientIDKey: "google.clientID",
        extraParameters: ["access_type": "offline"],
        redirect: { clientID in
            // iOS-Clients von Google nutzen die umgekehrte Client-ID als URL-Schema.
            let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
            return (scheme + ":/oauth2redirect", scheme)
        }
    )

    static let spotify = OAuthProvider(
        id: "spotify",
        displayName: "Spotify",
        authorizeURL: URL(string: "https://accounts.spotify.com/authorize")!,
        tokenURL: URL(string: "https://accounts.spotify.com/api/token")!,
        scopes: [
            "user-read-playback-state",
            "user-modify-playback-state",
            "user-read-currently-playing",
            "user-read-recently-played",
            "playlist-read-private"
        ],
        clientIDKey: "spotify.clientID",
        extraParameters: [:],
        redirect: { _ in ("apphub://spotify-callback", "apphub") }
    )
}

enum OAuthError: LocalizedError {
    case missingClientID
    case invalidCallback
    case stateMismatch
    case denied(String)
    case http(Int, String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Bitte trage zuerst deine Client-ID ein."
        case .invalidCallback, .stateMismatch:
            "Die Anmeldung konnte nicht abgeschlossen werden. Bitte versuche es erneut."
        case .denied(let reason):
            reason == "access_denied" ? "Du hast den Zugriff abgelehnt." : "Anmeldung abgelehnt (\(reason))."
        case .http(let status, let body):
            Self.message(status: status, body: body)
        case .notConnected:
            "Die Verbindung ist abgelaufen. Bitte verbinde den Konnektor neu."
        }
    }

    private static func message(status: Int, body: String) -> String {
        if body.contains("SERVICE_DISABLED") || body.contains("has not been used in project") {
            return "Die Gmail-API ist in deinem Google-Cloud-Projekt noch nicht aktiviert."
        }
        if body.contains("invalid_client") || body.contains("INVALID_CLIENT") {
            return "Die Client-ID wurde nicht akzeptiert. Prüfe sie in den Einstellungen."
        }
        if body.contains("redirect_uri") {
            return "Die Redirect-URI stimmt nicht mit der im Entwickler-Dashboard überein."
        }
        return "Serverfehler \(status). Bitte versuche es später erneut."
    }
}

/// Anmeldung, Token-Speicherung (Schlüsselbund) und autorisierte Anfragen für einen Anbieter.
@MainActor
@Observable
final class OAuthSession {
    let provider: OAuthProvider
    private(set) var token: OAuthToken?
    @ObservationIgnored private var refreshTask: Task<OAuthToken, Error>?

    var isConnected: Bool { token != nil }

    init(provider: OAuthProvider) {
        self.provider = provider
        if let data = Keychain.read(provider.id) {
            token = try? JSONDecoder().decode(OAuthToken.self, from: data)
        }
    }

    func signIn(using session: WebAuthenticationSession) async throws {
        let clientID = provider.clientID
        guard !clientID.isEmpty else { throw OAuthError.missingClientID }
        let redirect = provider.redirect(clientID)
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString

        var parameters = provider.extraParameters
        parameters["client_id"] = clientID
        parameters["response_type"] = "code"
        parameters["redirect_uri"] = redirect.uri
        parameters["scope"] = provider.scopes.joined(separator: " ")
        parameters["code_challenge_method"] = "S256"
        parameters["code_challenge"] = PKCE.challenge(for: verifier)
        parameters["state"] = state

        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(parameters)
        let callback = try await session.authenticate(using: components.url!, callbackURLScheme: redirect.scheme)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw OAuthError.denied(error) }
        guard value("state") == state else { throw OAuthError.stateMismatch }
        guard let code = value("code") else { throw OAuthError.invalidCallback }

        let token = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect.uri,
            "client_id": clientID,
            "code_verifier": verifier
        ], keepingRefreshToken: nil)
        store(token)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        Keychain.delete(provider.id)
        token = nil
    }

    /// Führt eine Anfrage mit gültigem Zugriffstoken aus; erneuert es bei Bedarf einmal.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        var (data, response) = try await perform(request)
        if response.statusCode == 401 {
            let fresh = try await refresh()
            request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await perform(request)
        }
        return (data, response)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func validAccessToken() async throws -> String {
        guard let token else { throw OAuthError.notConnected }
        if !token.isExpired { return token.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> OAuthToken {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = token?.refreshToken else {
            signOut()
            throw OAuthError.notConnected
        }
        let clientID = provider.clientID
        let task = Task { () throws -> OAuthToken in
            try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID
            ], keepingRefreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh
        } catch OAuthError.http(let status, _) where status == 400 || status == 401 {
            // Refresh-Token wurde widerrufen oder ist abgelaufen.
            signOut()
            throw OAuthError.notConnected
        }
    }

    private func requestToken(_ parameters: [String: String], keepingRefreshToken previous: String?) async throws -> OAuthToken {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(parameters).utf8)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? previous,
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600)
        )
    }

    private func store(_ token: OAuthToken) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, for: provider.id)
        }
    }
}

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ parameters: [String: String]) -> String {
        parameters
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .sorted()
            .joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Keychain {
    private static let service = "AppHub"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, for account: String) {
        delete(account)
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
