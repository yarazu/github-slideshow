import Foundation

struct SpotifyImage: Decodable {
    let url: String
}

struct SpotifyItem: Decodable {
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let name: String?; let images: [SpotifyImage]? }
    struct Show: Decodable { let name: String?; let images: [SpotifyImage]? }

    let name: String
    let uri: String?
    let duration_ms: Int?
    let artists: [Artist]?
    let album: Album?
    let show: Show?
    let images: [SpotifyImage]?
    let external_urls: [String: String]?

    var subtitle: String {
        if let artists, !artists.isEmpty { return artists.map(\.name).joined(separator: ", ") }
        return show?.name ?? ""
    }

    var artworkURL: URL? {
        (album?.images ?? images ?? show?.images)?.first.flatMap { URL(string: $0.url) }
    }

    /// Öffnet den Titel in der Spotify-App, sonst im Web.
    var openURLs: [URL] {
        [uri.flatMap(URL.init(string:)), external_urls?["spotify"].flatMap(URL.init(string:))].compactMap { $0 }
    }
}

struct SpotifyPlayback: Decodable {
    struct Device: Decodable { let name: String? }

    var is_playing: Bool
    let progress_ms: Int?
    let item: SpotifyItem?
    let device: Device?
}

struct SpotifyRecent: Identifiable {
    let id: String
    let item: SpotifyItem
}

struct SpotifyPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let uri: String?
    let images: [SpotifyImage]?
    let external_urls: [String: String]?

    var artworkURL: URL? { images?.first.flatMap { URL(string: $0.url) } }

    var openURLs: [URL] {
        [uri.flatMap(URL.init(string:)), external_urls?["spotify"].flatMap(URL.init(string:))].compactMap { $0 }
    }
}

struct SpotifyNotice: Equatable {
    let text: String
    let suggestsOpeningApp: Bool
}

/// Spotify über die Web-API: aktueller Titel, Steuerung, Verlauf und Playlists.
@MainActor
@Observable
final class SpotifyService {
    let auth = OAuthSession(provider: .spotify)
    private(set) var playback: SpotifyPlayback?
    private(set) var playbackFetchedAt = Date.now
    private(set) var recent: [SpotifyRecent] = []
    private(set) var playlists: [SpotifyPlaylist] = []
    private(set) var displayName: String?
    private(set) var isDemo = false
    var notice: SpotifyNotice?

    var isConnected: Bool { isDemo || auth.isConnected }
    var isPlaying: Bool { playback?.is_playing ?? false }

    static let appURLs: [URL] = [URL(string: "spotify:")!, URL(string: "https://open.spotify.com/")!]

    private let base = "https://api.spotify.com/v1/"

    func refreshAll() async {
        await refreshPlayback()
        await refreshLibrary()
    }

    func refreshPlayback() async {
        guard auth.isConnected, !isDemo else { return }
        do {
            let (data, status) = try await request("me/player")
            if status == 204 || data.isEmpty {
                playback = nil
            } else {
                playback = try JSONDecoder().decode(SpotifyPlayback.self, from: data)
            }
            playbackFetchedAt = .now
        } catch {
            handle(error)
        }
    }

    func refreshLibrary() async {
        guard auth.isConnected, !isDemo else { return }
        do {
            struct Profile: Decodable { let display_name: String? }
            struct RecentPage: Decodable {
                struct Entry: Decodable { let track: SpotifyItem; let played_at: String }
                let items: [Entry]
            }
            struct PlaylistPage: Decodable { let items: [SpotifyPlaylist?] }

            let profile: Profile = try await decode("me")
            let recentPage: RecentPage = try await decode("me/player/recently-played", query: [URLQueryItem(name: "limit", value: "10")])
            let playlistPage: PlaylistPage = try await decode("me/playlists", query: [URLQueryItem(name: "limit", value: "12")])
            displayName = profile.display_name
            recent = recentPage.items.map { SpotifyRecent(id: $0.played_at, item: $0.track) }
            playlists = playlistPage.items.compactMap { $0 }
        } catch {
            handle(error)
        }
    }

    func togglePlay() async {
        let wasPlaying = isPlaying
        playback?.is_playing = !wasPlaying
        guard !isDemo else { return }
        do {
            _ = try await request(wasPlaying ? "me/player/pause" : "me/player/play", method: "PUT")
            notice = nil
        } catch {
            playback?.is_playing = wasPlaying
            handle(error)
        }
        await refreshSoon()
    }

    func skip(forward: Bool) async {
        guard !isDemo else { return }
        do {
            _ = try await request(forward ? "me/player/next" : "me/player/previous", method: "POST")
            notice = nil
        } catch {
            handle(error)
        }
        await refreshSoon()
    }

    func play(_ playlist: SpotifyPlaylist) async -> Bool {
        guard let uri = playlist.uri, !isDemo else { return false }
        do {
            _ = try await request("me/player/play", method: "PUT", json: ["context_uri": uri])
            notice = nil
            await refreshSoon()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: - Befehle für Flows (werfen Fehler, damit der Verlauf sie zeigen kann)

    func pause() async throws {
        if !isDemo {
            _ = try await request("me/player/pause", method: "PUT")
        }
        playback?.is_playing = false
    }

    func resume() async throws {
        if !isDemo {
            _ = try await request("me/player/play", method: "PUT")
        }
        playback?.is_playing = true
    }

    func play(contextURI: String) async throws {
        if !isDemo {
            _ = try await request("me/player/play", method: "PUT", json: ["context_uri": contextURI])
        }
        playback?.is_playing = true
    }

    func disconnect() {
        auth.signOut()
        playback = nil
        recent = []
        playlists = []
        displayName = nil
        notice = nil
    }

    /// Fortschritt 0…1, läuft zwischen den Abfragen weiter.
    func progress(at date: Date) -> Double {
        guard let playback, let duration = playback.item?.duration_ms, duration > 0 else { return 0 }
        var elapsed = Double(playback.progress_ms ?? 0)
        if playback.is_playing { elapsed += date.timeIntervalSince(playbackFetchedAt) * 1000 }
        return min(max(elapsed / Double(duration), 0), 1)
    }

    // MARK: - API

    private func refreshSoon() async {
        try? await Task.sleep(for: .milliseconds(700))
        await refreshPlayback()
    }

    private func decode<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await request(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> (Data, Int) {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            request.httpBody = Data()
        }
        let (data, response) = try await auth.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SpotifyAPIError(status: response.statusCode, body: data)
        }
        return (data, response.statusCode)
    }

    private func handle(_ error: Error) {
        if let oauthError = error as? OAuthError, case .notConnected = oauthError {
            disconnect()
            return
        }
        if let apiError = error as? SpotifyAPIError {
            notice = apiError.notice
        } else {
            notice = SpotifyNotice(text: error.localizedDescription, suggestsOpeningApp: false)
        }
    }
}

struct SpotifyAPIError: Error {
    let status: Int
    let reason: String?
    let message: String?

    init(status: Int, body: Data) {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String?; let reason: String? }
            let error: Inner?
        }
        let inner = (try? JSONDecoder().decode(Envelope.self, from: body))?.error
        self.status = status
        reason = inner?.reason
        message = inner?.message
    }

    var notice: SpotifyNotice {
        if reason == "NO_ACTIVE_DEVICE" || status == 404 {
            return SpotifyNotice(text: "Kein aktives Gerät gefunden. Öffne Spotify und starte kurz die Wiedergabe.", suggestsOpeningApp: true)
        }
        if reason == "PREMIUM_REQUIRED" || status == 403 {
            return SpotifyNotice(text: "Die Steuerung der Wiedergabe erfordert Spotify Premium.", suggestsOpeningApp: true)
        }
        if status == 429 {
            return SpotifyNotice(text: "Zu viele Anfragen – bitte warte einen Moment.", suggestsOpeningApp: false)
        }
        return SpotifyNotice(text: message ?? "Spotify meldet Fehler \(status).", suggestsOpeningApp: false)
    }
}

#if DEBUG
extension SpotifyService {
    func applyDemo() {
        isDemo = true
        displayName = "Du"
        func item(_ name: String, _ artist: String, duration: Int = 214_000) -> SpotifyItem {
            SpotifyItem(name: name, uri: nil, duration_ms: duration, artists: [.init(name: artist)], album: nil, show: nil, images: nil, external_urls: nil)
        }
        playback = SpotifyPlayback(is_playing: true, progress_ms: 81_000, item: item("Fokus-Mix", "Lo-Fi Lounge"), device: .init(name: "iPhone"))
        playbackFetchedAt = .now
        recent = [
            SpotifyRecent(id: "1", item: item("Morning Coffee", "Kaffeehaus Trio")),
            SpotifyRecent(id: "2", item: item("Nordlicht", "Sophie Hunger")),
            SpotifyRecent(id: "3", item: item("Deep Work", "Focus Lab"))
        ]
        playlists = [
            SpotifyPlaylist(id: "1", name: "Fokus", uri: nil, images: nil, external_urls: nil),
            SpotifyPlaylist(id: "2", name: "Laufen", uri: nil, images: nil, external_urls: nil),
            SpotifyPlaylist(id: "3", name: "Sonntag", uri: nil, images: nil, external_urls: nil)
        ]
    }
}
#endif
