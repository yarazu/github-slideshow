import Foundation

/// Eine Nachricht aus dem Discord-Kanal (per Bot gelesen).
struct DiscordMessage: Identifiable, Hashable {
    let id: String
    let author: String
    let content: String
    let date: Date
}

/// Eine Nachricht, die Orbit über den Webhook gesendet hat (lokaler Verlauf).
struct DiscordSentMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    let content: String
    let date: Date
    var flowName: String?
}

enum DiscordError: LocalizedError {
    case invalidWebhook
    case notConnected
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidWebhook:
            "Das ist keine gültige Webhook-URL. Sie beginnt mit „https://discord.com/api/webhooks/“."
        case .notConnected:
            "Discord ist nicht verbunden. Bitte füge zuerst eine Webhook-URL hinzu."
        case .http(let status, let body):
            Self.message(status: status, body: body)
        }
    }

    /// Übersetzt Discord-Fehlercodes in verständliche Hinweise (ohne Secrets anzuzeigen).
    private static func message(status: Int, body: String) -> String {
        struct Payload: Decodable { let code: Int? }
        let payload = try? JSONDecoder().decode(Payload.self, from: Data(body.utf8))
        switch payload?.code ?? 0 {
        case 10015:
            return "Diesen Webhook gibt es nicht mehr. Lege in Discord einen neuen an und verbinde ihn erneut."
        case 50027:
            return "Die Webhook-URL ist unvollständig. Kopiere sie in Discord noch einmal komplett."
        case 10003:
            return "Der Kanal wurde nicht gefunden."
        case 50001, 50013:
            return "Der Bot hat keinen Zugriff auf diesen Kanal. Lade ihn auf deinen Server ein und erlaube „View Channels“ und „Read Message History“."
        case 50006:
            return "Die Nachricht ist leer."
        case 50035:
            return "Discord hat die Nachricht abgelehnt – sie ist vermutlich zu lang (max. 2000 Zeichen)."
        default:
            break
        }
        switch status {
        case 401:
            return "Der Bot-Token wurde nicht akzeptiert. Kopiere ihn im Developer Portal neu."
        case 403:
            return "Discord verweigert den Zugriff. Prüfe die Berechtigungen des Bots."
        case 404:
            return "Webhook oder Kanal wurde nicht gefunden."
        case 429:
            return "Zu viele Anfragen an Discord. Bitte warte einen Moment."
        default:
            return "Discord meldet Fehler \(status). Bitte versuche es später erneut."
        }
    }
}

/// Discord über einen Kanal-Webhook (senden) und optional einen Bot (mitlesen).
/// Webhook-URL und Bot-Token liegen ausschließlich im Schlüsselbund.
@MainActor
@Observable
final class DiscordService {
    private static let webhookKey = "discord.webhook"
    private static let botKey = "discord.bot"
    private static let sentKey = "discord.sent"
    /// Nicht geheime Kanal-Infos (Name, IDs), damit die Oberfläche sofort etwas zeigen kann.
    private static let infoKey = "discord.info"
    private static let sentLimit = 30
    private static let messageLimit = 2000
    private static let apiBase = "https://discord.com/api/v10/"

    /// Name des Webhooks (GET-Antwort „name“).
    private(set) var webhookName: String?
    /// Kanal des Webhooks („channel_id“).
    private(set) var channelID: String?
    /// Server des Webhooks („guild_id“).
    private(set) var guildID: String?
    /// Kanalname, sofern ein Bot ihn lesen darf.
    private(set) var channelName: String?
    /// Per Bot gelesen, neueste zuerst.
    private(set) var messages: [DiscordMessage] = []
    /// Lokaler Verlauf, neueste zuerst, max. 30.
    private(set) var sent: [DiscordSentMessage] = []
    private(set) var isLoading = false
    private(set) var isDemo = false
    private(set) var lastSync: Date?
    var errorMessage: String?

    private var hasWebhook = false
    private var hasBot = false

    var isConnected: Bool { isDemo || hasWebhook }

    /// Ist ein Bot-Token hinterlegt?
    var hasBotToken: Bool { isDemo || hasBot }

    /// Kann Orbit die letzten Nachrichten des Kanals lesen?
    var canReadMessages: Bool { isDemo || (hasBot && channelID != nil) }

    var channelLabel: String {
        if isDemo { return "#team" }
        if let channelName, !channelName.isEmpty { return "#\(channelName)" }
        return webhookName ?? "Discord-Kanal"
    }

    /// Öffnet möglichst direkt den Kanal, sonst die Discord-App bzw. das Web.
    var openURLs: [URL] {
        guard !isDemo, let guildID, let channelID,
              let channel = URL(string: "https://discord.com/channels/\(guildID)/\(channelID)") else {
            return Self.appURLs
        }
        return [channel] + Self.appURLs
    }

    nonisolated static let appURLs: [URL] = [URL(string: "discord://")!, URL(string: "https://discord.com/app")!]

    /// Vorschläge für Ein-Tipp-Nachrichten.
    nonisolated static let quickMessages = ["Bin gleich da", "Bin unterwegs", "Komme etwas später", "Bin im Meeting"]

    init() {
        hasWebhook = Keychain.read(Self.webhookKey) != nil
        hasBot = Keychain.read(Self.botKey) != nil
        if let data = UserDefaults.standard.data(forKey: Self.sentKey),
           let decoded = try? JSONDecoder().decode([DiscordSentMessage].self, from: data) {
            sent = decoded
        }
        if hasWebhook,
           let data = UserDefaults.standard.data(forKey: Self.infoKey),
           let info = try? JSONDecoder().decode(StoredInfo.self, from: data) {
            webhookName = info.webhookName
            channelID = info.channelID
            guildID = info.guildID
            channelName = info.channelName
        }
    }

    // MARK: - Verbinden

    /// Prüft den Webhook (und ggf. den Bot), speichert beides im Schlüsselbund und lädt den Kanal.
    func connect(webhookURL: String, botToken: String?) async throws {
        let address = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidWebhookURL(address), let url = URL(string: address) else {
            throw DiscordError.invalidWebhook
        }
        let token = Self.cleanToken(botToken)
        isLoading = true
        defer { isLoading = false }

        let info = try await fetchInfo(url)
        var name: String?
        var loaded: [DiscordMessage] = []
        if let token, let channel = info.channel_id {
            name = try await fetchChannelName(channel, token: token)
            loaded = try await fetchMessages(channel, token: token)
        }

        Keychain.save(Data(address.utf8), for: Self.webhookKey)
        if let token {
            Keychain.save(Data(token.utf8), for: Self.botKey)
        } else {
            Keychain.delete(Self.botKey)
        }
        isDemo = false
        hasWebhook = true
        hasBot = token != nil
        apply(info)
        channelName = name
        messages = loaded
        lastSync = .now
        errorMessage = nil
        persistInfo()
    }

    /// Fügt nachträglich einen Bot-Token hinzu (geprüft am Kanal des Webhooks) oder entfernt ihn mit `nil`.
    func updateBotToken(_ token: String?) async throws {
        guard let cleaned = Self.cleanToken(token) else {
            Keychain.delete(Self.botKey)
            hasBot = false
            channelName = nil
            messages = []
            persistInfo()
            return
        }
        if isDemo { return }
        guard hasWebhook, let webhook = storedWebhookURL else { throw DiscordError.notConnected }
        isLoading = true
        defer { isLoading = false }

        if channelID == nil {
            let info = try await fetchInfo(webhook)
            apply(info)
        }
        guard let channel = channelID else { throw DiscordError.notConnected }
        let name = try await fetchChannelName(channel, token: cleaned)
        let loaded = try await fetchMessages(channel, token: cleaned)

        Keychain.save(Data(cleaned.utf8), for: Self.botKey)
        hasBot = true
        channelName = name
        messages = loaded
        lastSync = .now
        errorMessage = nil
        persistInfo()
    }

    func disconnect() {
        Keychain.delete(Self.webhookKey)
        Keychain.delete(Self.botKey)
        UserDefaults.standard.removeObject(forKey: Self.infoKey)
        UserDefaults.standard.removeObject(forKey: Self.sentKey)
        isDemo = false
        hasWebhook = false
        hasBot = false
        webhookName = nil
        channelID = nil
        guildID = nil
        channelName = nil
        messages = []
        sent = []
        lastSync = nil
        errorMessage = nil
    }

    // MARK: - Senden & Laden

    /// Postet eine Nachricht als „Orbit“ über den Webhook und merkt sie im Verlauf.
    func send(_ content: String, flowName: String? = nil) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DiscordError.http(400, #"{"code": 50006}"#) }
        let text = String(trimmed.prefix(Self.messageLimit))
        let entry = DiscordSentMessage(content: text, date: .now, flowName: flowName)

        if isDemo {
            record(entry)
            messages.insert(DiscordMessage(id: entry.id.uuidString, author: "Orbit", content: text, date: entry.date), at: 0)
            return
        }
        guard hasWebhook, let webhook = storedWebhookURL else { throw DiscordError.notConnected }
        guard var components = URLComponents(url: webhook, resolvingAgainstBaseURL: false) else {
            throw DiscordError.invalidWebhook
        }
        var items = (components.queryItems ?? []).filter { $0.name != "wait" }
        items.append(URLQueryItem(name: "wait", value: "true"))
        components.queryItems = items
        guard let url = components.url else { throw DiscordError.invalidWebhook }

        // Erwähnungen von @everyone/@here und Rollen werden unterdrückt, damit Flows niemanden versehentlich anpingen.
        let payload = OutgoingMessage(content: text, username: "Orbit", allowed_mentions: .init(parse: ["users"]))
        let body = try JSONEncoder().encode(payload)
        let data = try await perform(url, method: "POST", body: body)

        record(entry)
        if hasBot, let created = try? JSONDecoder().decode(RawMessage.self, from: data),
           !messages.contains(where: { $0.id == created.id }) {
            messages.insert(Self.makeMessage(created), at: 0)
        }
    }

    /// Lädt Webhook-Infos und – falls ein Bot hinterlegt ist – die letzten 15 Nachrichten.
    func refresh() async {
        guard !isDemo, hasWebhook, !isLoading, let webhook = storedWebhookURL else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await fetchInfo(webhook)
            apply(info)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard let token = storedBotToken, let channel = channelID else {
            messages = []
            lastSync = .now
            errorMessage = nil
            persistInfo()
            return
        }
        do {
            if channelName == nil {
                channelName = try await fetchChannelName(channel, token: token)
            }
            messages = try await fetchMessages(channel, token: token)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        lastSync = .now
        persistInfo()
    }

    /// `https://discord.com/api/webhooks/<id>/<token>` (auch discordapp.com, ptb., canary., mit API-Version).
    nonisolated static func isValidWebhookURL(_ string: String) -> Bool {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else { return false }
        let allowedHosts = ["discord.com", "discordapp.com"].flatMap { [$0, "ptb." + $0, "canary." + $0] }
        guard allowedHosts.contains(host) else { return false }

        var parts = components.path.split(separator: "/").map { String($0) }
        guard parts.first == "api" else { return false }
        parts.removeFirst()
        if let version = parts.first, version.count > 1, version.hasPrefix("v"), version.dropFirst().allSatisfy({ $0.isNumber }) {
            parts.removeFirst()
        }
        guard parts.count == 3, parts[0] == "webhooks" else { return false }
        let id = parts[1]
        let token = parts[2]
        let idIsValid = !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
        let tokenIsValid = token.count >= 20 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return idIsValid && tokenIsValid
    }

    // MARK: - Privat

    private var storedWebhookURL: URL? {
        guard let data = Keychain.read(Self.webhookKey) else { return nil }
        return URL(string: String(decoding: data, as: UTF8.self))
    }

    private var storedBotToken: String? {
        guard hasBot, let data = Keychain.read(Self.botKey) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    /// Entfernt Leerzeichen und ein vorangestelltes „Bot “; leer → `nil`.
    private static func cleanToken(_ token: String?) -> String? {
        var value = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bot ") {
            value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }

    private func apply(_ info: WebhookInfo) {
        if info.channel_id != channelID { channelName = nil }
        webhookName = info.name
        channelID = info.channel_id
        guildID = info.guild_id
    }

    private func record(_ entry: DiscordSentMessage) {
        sent.insert(entry, at: 0)
        if sent.count > Self.sentLimit { sent.removeLast(sent.count - Self.sentLimit) }
        guard !isDemo, let data = try? JSONEncoder().encode(sent) else { return }
        UserDefaults.standard.set(data, forKey: Self.sentKey)
    }

    private func persistInfo() {
        guard !isDemo else { return }
        let info = StoredInfo(webhookName: webhookName, channelID: channelID, guildID: guildID, channelName: channelName)
        guard let data = try? JSONEncoder().encode(info) else { return }
        UserDefaults.standard.set(data, forKey: Self.infoKey)
    }

    private func fetchInfo(_ webhook: URL) async throws -> WebhookInfo {
        let data = try await perform(webhook)
        return try JSONDecoder().decode(WebhookInfo.self, from: data)
    }

    private func fetchChannelName(_ channel: String, token: String) async throws -> String? {
        guard Self.isSnowflake(channel), let url = URL(string: Self.apiBase + "channels/\(channel)") else {
            throw DiscordError.notConnected
        }
        let data = try await perform(url, botToken: token)
        return try JSONDecoder().decode(RawChannel.self, from: data).name
    }

    private func fetchMessages(_ channel: String, token: String) async throws -> [DiscordMessage] {
        guard Self.isSnowflake(channel), let url = URL(string: Self.apiBase + "channels/\(channel)/messages?limit=15") else {
            throw DiscordError.notConnected
        }
        let data = try await perform(url, botToken: token)
        let raw = try JSONDecoder().decode([RawMessage].self, from: data)
        return raw.map { Self.makeMessage($0) }.sorted { $0.date > $1.date }
    }

    private func perform(_ url: URL, method: String = "GET", body: Data? = nil, botToken: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("DiscordBot (https://discord.com, 1.0) Orbit", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let botToken {
            request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw DiscordError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private static func isSnowflake(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func makeMessage(_ raw: RawMessage) -> DiscordMessage {
        var author = "Unbekannt"
        if let person = raw.author {
            let display = (person.global_name ?? "").trimmingCharacters(in: .whitespaces)
            author = display.isEmpty ? person.username : display
        }
        return DiscordMessage(id: raw.id, author: author, content: raw.content ?? "", date: parseDate(raw.timestamp))
    }

    /// ISO 8601 mit Sekundenbruchteilen (Discord liefert sechs Stellen), sonst ohne.
    private static func parseDate(_ string: String?) -> Date {
        guard let string, !string.isEmpty else { return .now }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: stripped) ?? .now
    }

    private struct WebhookInfo: Decodable {
        let name: String?
        let channel_id: String?
        let guild_id: String?
    }

    private struct RawChannel: Decodable {
        let name: String?
    }

    private struct RawMessage: Decodable {
        struct Author: Decodable {
            let username: String
            let global_name: String?
        }
        let id: String
        let content: String?
        let timestamp: String?
        let author: Author?
    }

    private struct OutgoingMessage: Encodable {
        struct Mentions: Encodable { let parse: [String] }
        let content: String
        let username: String
        let allowed_mentions: Mentions
    }

    private struct StoredInfo: Codable {
        var webhookName: String?
        var channelID: String?
        var guildID: String?
        var channelName: String?
    }
}

#if DEBUG
extension DiscordService {
    func applyDemo() {
        isDemo = true
        webhookName = "Orbit"
        channelID = "100000000000000001"
        guildID = "100000000000000000"
        channelName = "team"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: calendar.date(byAdding: .day, value: day, to: today)!)!
        }
        messages = [
            DiscordMessage(id: "4", author: "Lea", content: "Alles klar, wir fangen an – ich schick dir danach die Notizen.", date: at(0, 8, 58)),
            DiscordMessage(id: "3", author: "Orbit", content: "Bin bis 09:30 im Meeting „Wochenplanung“.", date: at(0, 8, 50)),
            DiscordMessage(id: "2", author: "Jonas", content: "Wer bringt heute den Beamer mit? Ich hab den Schlüssel für Raum 4.12.", date: at(0, 8, 31)),
            DiscordMessage(id: "1", author: "Mira", content: "Guten Morgen zusammen! Kaffee steht in der Küche.", date: at(0, 7, 55))
        ]
        sent = [
            DiscordSentMessage(content: "Bin bis 09:30 im Meeting „Wochenplanung“.", date: at(0, 8, 50), flowName: "Meeting-Modus"),
            DiscordSentMessage(content: "Feierabend für heute – bis morgen!", date: at(-1, 17, 30), flowName: "Feierabend")
        ]
        lastSync = .now
        errorMessage = nil
    }
}
#endif
