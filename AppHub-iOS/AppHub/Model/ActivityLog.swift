import Foundation

/// Ein Eintrag im Verlauf „Aktivität“: Nachrichten, Discord-Posts, Flow-Läufe, Fehler.
struct ActivityEntry: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case message, discord, spotify, reminder, mail, run, error
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var title: String
    var detail: String
    var flowName: String?
    /// Kennung der iOS-Mitteilung, damit zugestellte Mitteilungen nur einmal erscheinen.
    var notificationID: String?

    var symbol: String {
        switch kind {
        case .message: "bell.badge.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .spotify: "music.note"
        case .reminder: "alarm.fill"
        case .mail: "envelope.fill"
        case .run: "bolt.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    /// Konnektor, dessen Logo neben dem Eintrag erscheint.
    var connector: Connector? {
        switch kind {
        case .discord: .discord
        case .spotify: .spotify
        case .mail: .gmail
        case .message, .reminder, .run, .error: nil
        }
    }
}

/// Speichert die letzten 200 Aktivitäten lokal.
@MainActor
@Observable
final class ActivityLog {
    private static let limit = 200
    private static let lastSeenKey = "activity.lastSeen"

    private(set) var entries: [ActivityEntry] = []
    private var lastSeen: Date

    /// Einträge seit dem letzten Öffnen des Tabs „Aktivität“.
    var unseenCount: Int { entries.filter { $0.date > lastSeen }.count }

    init() {
        lastSeen = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date ?? .distantPast
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ kind: ActivityEntry.Kind, title: String, detail: String = "", flowName: String? = nil, notificationID: String? = nil, date: Date = .now) {
        if let notificationID, contains(notificationID: notificationID) { return }
        let entry = ActivityEntry(date: date, kind: kind, title: title, detail: detail, flowName: flowName, notificationID: notificationID)
        let index = entries.firstIndex { $0.date < date } ?? entries.endIndex
        entries.insert(entry, at: index)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        persist()
    }

    func contains(notificationID: String) -> Bool {
        entries.contains { $0.notificationID == notificationID }
    }

    func markAllSeen() {
        lastSeen = .now
        UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey)
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("aktivitaet.json")
    }
}

#if DEBUG
extension ActivityLog {
    func applyDemo() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: calendar.date(byAdding: .day, value: day, to: today)!)!
        }
        entries = [
            ActivityEntry(date: at(0, 8, 50), kind: .discord, title: "Discord: #team", detail: "Bin bis 09:30 im Meeting „Wochenplanung“.", flowName: "Meeting-Modus"),
            ActivityEntry(date: at(0, 8, 50), kind: .spotify, title: "Spotify pausiert", detail: "Fokus-Mix", flowName: "Meeting-Modus"),
            ActivityEntry(date: at(0, 8, 50), kind: .message, title: "Wochenplanung in 10 Minuten", detail: "09:00–09:30 Raum 4.12", flowName: "Meeting-Modus"),
            ActivityEntry(date: at(0, 8, 12), kind: .mail, title: "Neue Mail von Lea Berg", detail: "Agenda für die Wochenplanung", flowName: "Mail-Wächter"),
            ActivityEntry(date: at(0, 7, 30), kind: .message, title: "Guten Morgen! Dienstag, 20. Oktober", detail: "3 Termine: 09:00 Wochenplanung, 13:00 Mittagessen mit Lea, 18:00 Laufrunde · 3 ungelesene Mails", flowName: "Morgen-Briefing"),
            ActivityEntry(date: at(-1, 17, 30), kind: .discord, title: "Discord: #team", detail: "Feierabend für heute – bis morgen!", flowName: "Feierabend"),
            ActivityEntry(date: at(-1, 15, 10), kind: .reminder, title: "Fokuszeit vorbei", detail: "Zeit für eine Pause.", flowName: "Fokuszeit"),
            ActivityEntry(date: at(-1, 14, 20), kind: .run, title: "Fokuszeit gestartet", detail: "3 von 3 Aktionen ausgeführt", flowName: "Fokuszeit")
        ]
        lastSeen = at(0, 8, 0)
    }
}
#endif
