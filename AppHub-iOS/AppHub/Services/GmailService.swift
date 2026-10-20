import Foundation

struct GmailMessage: Identifiable {
    let id: String
    let threadID: String
    let sender: String
    let senderAddress: String
    let subject: String
    let snippet: String
    let date: Date
    let isUnread: Bool

    var webURL: URL? { URL(string: "https://mail.google.com/mail/u/0/#all/\(threadID)") }

    var initials: String {
        let letters = sender.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Gmail über die offizielle Gmail-API (nur Lesezugriff).
@MainActor
@Observable
final class GmailService {
    let auth = OAuthSession(provider: .google)
    private(set) var email: String?
    private(set) var unreadCount: Int?
    private(set) var messages: [GmailMessage] = []
    private(set) var isLoading = false
    private(set) var lastSync: Date?
    private(set) var isDemo = false
    var errorMessage: String?

    var isConnected: Bool { isDemo || auth.isConnected }

    private let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    func refresh() async {
        guard auth.isConnected, !isDemo, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let profile: Profile = try await get("profile")
            let inbox: Label = try await get("labels/INBOX")
            let list: MessageList = try await get("messages", query: [
                URLQueryItem(name: "labelIds", value: "INBOX"),
                URLQueryItem(name: "maxResults", value: "15")
            ])
            let ids = (list.messages ?? []).map(\.id)
            let loaded = try await withThrowingTaskGroup(of: (Int, GmailMessage?).self) { group in
                for (index, id) in ids.enumerated() {
                    group.addTask {
                        let message = try await self.message(id)
                        return (index, message)
                    }
                }
                var result = [GmailMessage?](repeating: nil, count: ids.count)
                for try await (index, message) in group { result[index] = message }
                return result.compactMap { $0 }
            }
            email = profile.emailAddress
            unreadCount = inbox.messagesUnread
            messages = loaded
            lastSync = .now
            errorMessage = nil
        } catch OAuthError.notConnected {
            disconnect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        if let token = auth.token?.refreshToken ?? auth.token?.accessToken,
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(FormEncoding.escape(token))") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }
        auth.signOut()
        email = nil
        unreadCount = nil
        messages = []
        errorMessage = nil
    }

    /// Öffnet eine neue Mail in der Gmail-App, sonst im Standard-Mailprogramm.
    static func composeURLs(to recipients: [String], subject: String = "") -> [URL] {
        let to = recipients.joined(separator: ",")
        let gmail = "googlegmail://co?to=\(FormEncoding.escape(to))&subject=\(FormEncoding.escape(subject))"
        let mailto = "mailto:\(to)?subject=\(FormEncoding.escape(subject))"
        return [URL(string: gmail), URL(string: mailto)].compactMap { $0 }
    }

    static let appURLs: [URL] = [URL(string: "googlegmail://")!, URL(string: "https://mail.google.com/")!]

    // MARK: - API

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        let (data, response) = try await auth.send(URLRequest(url: components.url!))
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func message(_ id: String) async throws -> GmailMessage? {
        let raw: RawMessage = try await get("messages/\(id)", query: [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject")
        ])
        let headers = raw.payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let (sender, address) = Self.parseSender(header("From") ?? "")
        let milliseconds = Double(raw.internalDate ?? "") ?? 0
        return GmailMessage(
            id: raw.id,
            threadID: raw.threadId ?? raw.id,
            sender: sender,
            senderAddress: address,
            subject: (header("Subject") ?? "").isEmpty ? "(Kein Betreff)" : header("Subject")!,
            snippet: Self.decodeEntities(raw.snippet ?? ""),
            date: Date(timeIntervalSince1970: milliseconds / 1000),
            isUnread: raw.labelIds?.contains("UNREAD") ?? false
        )
    }

    /// `"Lea Berg" <lea@example.com>` → ("Lea Berg", "lea@example.com")
    static func parseSender(_ value: String) -> (String, String) {
        guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close else {
            return (value, value)
        }
        let address = String(value[value.index(after: open)..<close])
        let name = value[..<open]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name.isEmpty ? address : name, address)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    private struct Profile: Decodable { let emailAddress: String }
    private struct Label: Decodable { let messagesUnread: Int? }
    private struct MessageList: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
    }
    private struct RawMessage: Decodable {
        struct Payload: Decodable { let headers: [Header]? }
        struct Header: Decodable { let name: String; let value: String }
        let id: String
        let threadId: String?
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Payload?
    }
}

#if DEBUG
extension GmailService {
    func applyDemo() {
        isDemo = true
        email = "du@gmail.com"
        unreadCount = 3
        let now = Date.now
        messages = [
            GmailMessage(id: "1", threadID: "1", sender: "Lea Berg", senderAddress: "lea@example.com", subject: "Agenda für die Wochenplanung", snippet: "Hi! Anbei die Punkte für gleich – schau kurz drüber, bevor wir starten.", date: now.addingTimeInterval(-600), isUnread: true),
            GmailMessage(id: "2", threadID: "2", sender: "Deutsche Bahn", senderAddress: "noreply@example.com", subject: "Deine Fahrkarte nach Hamburg", snippet: "Gute Reise! Deine Buchung ist bestätigt.", date: now.addingTimeInterval(-5400), isUnread: true),
            GmailMessage(id: "3", threadID: "3", sender: "Jonas Weber", senderAddress: "jonas@example.com", subject: "Fotos vom Wochenende", snippet: "Hab sie dir in ein Album gepackt, der Link ist unten.", date: now.addingTimeInterval(-86_400), isUnread: true),
            GmailMessage(id: "4", threadID: "4", sender: "Spotify", senderAddress: "no-reply@example.com", subject: "Dein Mix der Woche ist da", snippet: "30 neue Titel, ausgewählt für dich.", date: now.addingTimeInterval(-172_800), isUnread: false)
        ]
        lastSync = now
    }
}
#endif
