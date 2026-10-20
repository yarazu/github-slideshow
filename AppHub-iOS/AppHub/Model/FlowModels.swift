import SwiftUI

// MARK: - Flow

/// Ein Flow: Auslöser + Schritte, z. B. „10 Min. vor jedem Termin → Nachricht, Spotify pausieren, Discord-Status“.
struct Flow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: FlowColor
    var isEnabled: Bool
    var trigger: FlowTrigger
    var steps: [FlowStep]
    /// Schlüssel der Vorlage, aus der der Flow entstanden ist.
    var templateKey: String?
    var lastRun: Date?

    /// Hat der Flow Schritte außer Nachrichten, die beim Auslösen ausgeführt werden müssen?
    var hasActionSteps: Bool {
        steps.contains { step in
            if case .notify = step.action { return false }
            return true
        }
    }

    /// Die erste Nachricht des Flows, falls vorhanden.
    var firstMessage: (title: String, body: String)? {
        for step in steps {
            if case .notify(let title, let body) = step.action { return (title, body) }
        }
        return nil
    }

    static let symbols = [
        "sun.max.fill", "briefcase.fill", "envelope.badge.fill", "house.fill", "headphones",
        "moon.stars.fill", "cup.and.saucer.fill", "figure.walk", "bolt.fill", "bell.fill",
        "car.fill", "cart.fill", "dumbbell.fill", "book.fill", "heart.fill"
    ]

    static func blank() -> Flow {
        Flow(
            name: "Neuer Flow",
            symbol: "bolt.fill",
            color: .violet,
            isEnabled: true,
            trigger: .manual,
            steps: [FlowStep(action: .notify(title: "Hallo!", body: "Dein Flow wurde ausgeführt."))]
        )
    }
}

struct FlowStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var action: FlowAction
}

enum FlowColor: String, Codable, CaseIterable, Identifiable {
    case sunrise, ocean, violet, mint, rose, amber

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .sunrise: Color(hex: 0xFF9F5A)
        case .ocean: Color(hex: 0x5AB8FF)
        case .violet: Color(hex: 0xA98BFF)
        case .mint: Color(hex: 0x4FE0B0)
        case .rose: Color(hex: 0xFF7A9C)
        case .amber: Color(hex: 0xFFD25A)
        }
    }

    var name: String {
        switch self {
        case .sunrise: "Sonnenaufgang"
        case .ocean: "Ozean"
        case .violet: "Violett"
        case .mint: "Minze"
        case .rose: "Rosé"
        case .amber: "Bernstein"
        }
    }
}

// MARK: - Auslöser

enum FlowTrigger: Codable, Hashable {
    /// Per Button, Siri oder Kurzbefehle-App.
    case manual
    /// Zu einer Uhrzeit. `weekdays` nutzt `Calendar`-Wochentage (1 = So … 7 = Sa); leer = jeden Tag.
    case daily(hour: Int, minute: Int, weekdays: [Int])
    /// X Minuten vor jedem Termin (ganztägige Termine ausgenommen).
    case beforeEvent(minutes: Int)
    /// Bei neuer ungelesener Mail; leerer Filter = jede Mail.
    case newMail(senderContains: String)

    enum Kind: String, CaseIterable, Identifiable {
        case manual, daily, beforeEvent, newMail

        var id: String { rawValue }

        var title: String {
            switch self {
            case .manual: "Manuell"
            case .daily: "Zur Uhrzeit"
            case .beforeEvent: "Vor Terminen"
            case .newMail: "Neue Mail"
            }
        }

        var symbol: String {
            switch self {
            case .manual: "hand.tap.fill"
            case .daily: "clock.fill"
            case .beforeEvent: "calendar.badge.clock"
            case .newMail: "envelope.badge.fill"
            }
        }

        var defaultValue: FlowTrigger {
            switch self {
            case .manual: .manual
            case .daily: .daily(hour: 7, minute: 30, weekdays: [])
            case .beforeEvent: .beforeEvent(minutes: 10)
            case .newMail: .newMail(senderContains: "")
            }
        }

        /// Welcher Konnektor nötig ist, damit der Auslöser funktioniert.
        var requiredConnector: Connector? {
            switch self {
            case .manual, .daily: nil
            case .beforeEvent: .calendar
            case .newMail: .gmail
            }
        }
    }

    var kind: Kind {
        switch self {
        case .manual: .manual
        case .daily: .daily
        case .beforeEvent: .beforeEvent
        case .newMail: .newMail
        }
    }

    var symbol: String { kind.symbol }

    var summary: String {
        switch self {
        case .manual:
            return "Per Tipp, Siri oder Kurzbefehl"
        case .daily(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            return "\(Self.daysText(weekdays)) um \(time)"
        case .beforeEvent(let minutes):
            return "\(minutes) Min. vor jedem Termin"
        case .newMail(let sender):
            let filter = sender.trimmingCharacters(in: .whitespaces)
            return filter.isEmpty ? "Bei jeder neuen Mail" : "Bei neuer Mail von „\(filter)“"
        }
    }

    /// Kurze deutsche Wochentagsnamen, Index = `Calendar`-Wochentag.
    static let weekdayNames = [1: "So", 2: "Mo", 3: "Di", 4: "Mi", 5: "Do", 6: "Fr", 7: "Sa"]
    /// Reihenfolge für die Anzeige, beginnend mit Montag.
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    static func daysText(_ weekdays: [Int]) -> String {
        let set = Set(weekdays)
        if set.isEmpty || set.count == 7 { return "Täglich" }
        if set == [2, 3, 4, 5, 6] { return "Mo–Fr" }
        if set == [1, 7] { return "Am Wochenende" }
        return weekdayOrder.filter(set.contains).compactMap { weekdayNames[$0] }.joined(separator: ", ")
    }
}

// MARK: - Aktionen

enum FlowAction: Codable, Hashable {
    /// Mitteilung aufs iPhone. Texte dürfen Platzhalter wie `{termin}` enthalten.
    case notify(title: String, body: String)
    /// Nachricht über den Discord-Webhook.
    case discord(message: String)
    case spotifyPause
    /// Playlist starten (`contextURI`) oder ohne URI die Wiedergabe fortsetzen.
    case spotifyPlay(contextURI: String?, name: String?)
    /// Erinnerung, die `minutes` nach dem Ausführen erscheint.
    case reminder(minutes: Int, text: String)

    enum Kind: String, CaseIterable, Identifiable {
        case notify, discord, spotifyPause, spotifyPlay, reminder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notify: "Nachricht senden"
            case .discord: "Discord-Nachricht"
            case .spotifyPause: "Spotify pausieren"
            case .spotifyPlay: "Spotify abspielen"
            case .reminder: "Erinnerung später"
            }
        }

        var symbol: String {
            switch self {
            case .notify: "bell.badge.fill"
            case .discord: "bubble.left.and.bubble.right.fill"
            case .spotifyPause: "pause.fill"
            case .spotifyPlay: "play.fill"
            case .reminder: "alarm.fill"
            }
        }

        var connector: Connector? {
            switch self {
            case .notify, .reminder: nil
            case .discord: .discord
            case .spotifyPause, .spotifyPlay: .spotify
            }
        }

        var defaultValue: FlowAction {
            switch self {
            case .notify: .notify(title: "Hinweis", body: "")
            case .discord: .discord(message: "")
            case .spotifyPause: .spotifyPause
            case .spotifyPlay: .spotifyPlay(contextURI: nil, name: nil)
            case .reminder: .reminder(minutes: 30, text: "Zeit für eine Pause.")
            }
        }
    }

    var kind: Kind {
        switch self {
        case .notify: .notify
        case .discord: .discord
        case .spotifyPause: .spotifyPause
        case .spotifyPlay: .spotifyPlay
        case .reminder: .reminder
        }
    }

    var title: String { kind.title }
    var symbol: String { kind.symbol }
    var connector: Connector? { kind.connector }

    /// Eine Zeile, die beschreibt, was die Aktion tut.
    var summary: String {
        switch self {
        case .notify(let title, _):
            return "„\(title)“"
        case .discord(let message):
            return message.isEmpty ? "Noch kein Text" : "„\(message)“"
        case .spotifyPause:
            return "Wiedergabe anhalten"
        case .spotifyPlay(_, let name):
            return name.map { "Playlist „\($0)“" } ?? "Wiedergabe fortsetzen"
        case .reminder(let minutes, let text):
            return "Nach \(minutes) Min.: „\(text)“"
        }
    }
}

// MARK: - Platzhalter

struct FlowToken: Identifiable, Hashable {
    let key: String
    let label: String
    /// Auslöser, bei denen der Platzhalter einen Wert hat; `nil` = immer.
    let triggers: [FlowTrigger.Kind]?

    var id: String { key }

    static let all: [FlowToken] = [
        FlowToken(key: "{datum}", label: "Datum", triggers: nil),
        FlowToken(key: "{uhrzeit}", label: "Uhrzeit", triggers: nil),
        FlowToken(key: "{termine_heute}", label: "Termine heute", triggers: nil),
        FlowToken(key: "{erster_termin}", label: "Erster Termin", triggers: nil),
        FlowToken(key: "{termine_morgen}", label: "Termine morgen", triggers: nil),
        FlowToken(key: "{erster_termin_morgen}", label: "Erster Termin morgen", triggers: nil),
        FlowToken(key: "{ungelesen}", label: "Ungelesene Mails", triggers: nil),
        FlowToken(key: "{termin}", label: "Termin", triggers: [.beforeEvent]),
        FlowToken(key: "{termin_start}", label: "Beginn", triggers: [.beforeEvent]),
        FlowToken(key: "{termin_ende}", label: "Ende", triggers: [.beforeEvent]),
        FlowToken(key: "{ort}", label: "Ort", triggers: [.beforeEvent]),
        FlowToken(key: "{absender}", label: "Absender", triggers: [.newMail]),
        FlowToken(key: "{betreff}", label: "Betreff", triggers: [.newMail])
    ]

    static func available(for kind: FlowTrigger.Kind) -> [FlowToken] {
        all.filter { $0.triggers == nil || $0.triggers!.contains(kind) }
    }
}

/// Die Daten, mit denen Platzhalter in Nachrichten ersetzt werden.
struct FlowContext {
    var date: Date = .now
    var eventsToday: [CalendarEvent] = []
    var eventsTomorrow: [CalendarEvent] = []
    var event: CalendarEvent?
    var mail: GmailMessage?
    var unreadCount: Int?

    func render(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var values: [String: String] = [
            "{datum}": date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.locale)),
            "{uhrzeit}": Fmt.time(date),
            "{termine_heute}": Self.list(eventsToday),
            "{erster_termin}": eventsToday.first.map(Self.line) ?? "kein Termin",
            "{termine_morgen}": Self.list(eventsTomorrow),
            "{erster_termin_morgen}": eventsTomorrow.first.map(Self.line) ?? "kein Termin",
            "{ungelesen}": unreadCount.map { String($0) } ?? "–"
        ]
        if let event {
            values["{termin}"] = event.title
            values["{termin_start}"] = Fmt.time(event.start)
            values["{termin_ende}"] = Fmt.time(event.end)
            values["{ort}"] = event.location ?? ""
        }
        if let mail {
            values["{absender}"] = mail.sender
            values["{betreff}"] = mail.subject
        }
        var result = text
        for (key, value) in values {
            result = result.replacingOccurrences(of: key, with: value)
        }
        // Nicht belegte Platzhalter entfernen, damit keine geschweiften Klammern in Nachrichten landen.
        for token in FlowToken.all where result.contains(token.key) {
            result = result.replacingOccurrences(of: token.key, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func line(_ event: CalendarEvent) -> String {
        event.isAllDay ? "\(event.title) (ganztägig)" : "\(Fmt.time(event.start)) \(event.title)"
    }

    private static func list(_ events: [CalendarEvent]) -> String {
        switch events.count {
        case 0: return "Keine Termine"
        case 1: return "1 Termin: \(line(events[0]))"
        default:
            let shown = events.prefix(3).map(line).joined(separator: ", ")
            let more = events.count > 3 ? " +\(events.count - 3)" : ""
            return "\(events.count) Termine: \(shown)\(more)"
        }
    }
}

// MARK: - Vorlagen

enum FlowTemplates {
    static let keys = ["morning", "meeting", "mail", "evening", "focus", "tomorrow"]

    static func all() -> [Flow] { keys.compactMap(make) }

    static func make(_ key: String) -> Flow? {
        switch key {
        case "morning":
            return Flow(
                name: "Morgen-Briefing",
                symbol: "sun.max.fill",
                color: .sunrise,
                isEnabled: true,
                trigger: .daily(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6]),
                steps: [FlowStep(action: .notify(title: "Guten Morgen! {datum}", body: "{termine_heute} · {ungelesen} ungelesene Mails"))],
                templateKey: key
            )
        case "meeting":
            return Flow(
                name: "Meeting-Modus",
                symbol: "briefcase.fill",
                color: .ocean,
                isEnabled: true,
                trigger: .beforeEvent(minutes: 10),
                steps: [
                    FlowStep(action: .notify(title: "{termin} in 10 Minuten", body: "{termin_start}–{termin_ende} {ort}")),
                    FlowStep(action: .spotifyPause),
                    FlowStep(action: .discord(message: "Bin bis {termin_ende} im Meeting „{termin}“."))
                ],
                templateKey: key
            )
        case "mail":
            return Flow(
                name: "Mail-Wächter",
                symbol: "envelope.badge.fill",
                color: .rose,
                isEnabled: true,
                trigger: .newMail(senderContains: ""),
                steps: [FlowStep(action: .notify(title: "Neue Mail von {absender}", body: "{betreff}"))],
                templateKey: key
            )
        case "evening":
            return Flow(
                name: "Feierabend",
                symbol: "house.fill",
                color: .violet,
                isEnabled: true,
                trigger: .daily(hour: 17, minute: 30, weekdays: [2, 3, 4, 5, 6]),
                steps: [
                    FlowStep(action: .notify(title: "Feierabend!", body: "Morgen: {erster_termin_morgen}")),
                    FlowStep(action: .discord(message: "Feierabend für heute – bis morgen!")),
                    FlowStep(action: .spotifyPlay(contextURI: nil, name: nil))
                ],
                templateKey: key
            )
        case "focus":
            return Flow(
                name: "Fokuszeit",
                symbol: "headphones",
                color: .mint,
                isEnabled: true,
                trigger: .manual,
                steps: [
                    FlowStep(action: .spotifyPlay(contextURI: nil, name: nil)),
                    FlowStep(action: .discord(message: "Bin für 50 Minuten im Fokus und melde mich danach.")),
                    FlowStep(action: .reminder(minutes: 50, text: "Fokuszeit vorbei – Zeit für eine Pause."))
                ],
                templateKey: key
            )
        case "tomorrow":
            return Flow(
                name: "Abendvorschau",
                symbol: "moon.stars.fill",
                color: .amber,
                isEnabled: true,
                trigger: .daily(hour: 21, minute: 0, weekdays: []),
                steps: [FlowStep(action: .notify(title: "Dein Morgen", body: "{termine_morgen}"))],
                templateKey: key
            )
        default:
            return nil
        }
    }

    /// Ein Satz, der erklärt, wobei die Vorlage hilft.
    static func pitch(_ key: String) -> String {
        switch key {
        case "morning": "Jeden Werktag ein Überblick über Termine und Mails."
        case "meeting": "Vor Terminen erinnern, Musik pausieren und Discord Bescheid geben."
        case "mail": "Sofort eine Nachricht, wenn eine neue Mail eintrifft."
        case "evening": "Feierabend-Gruß an Discord, Musik an und Ausblick auf morgen."
        case "focus": "Musik an, Status setzen und nach 50 Minuten an die Pause erinnern."
        case "tomorrow": "Am Abend sehen, was morgen ansteht."
        default: ""
        }
    }
}
