import EventKit
import EventKitUI
import SwiftUI

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
    let color: Color
    let attendees: [String]

    init(_ event: EKEvent) {
        start = event.startDate
        end = event.endDate
        id = (event.eventIdentifier ?? UUID().uuidString) + "-\(start.timeIntervalSince1970)"
        if let title = event.title, !title.isEmpty {
            self.title = title
        } else {
            self.title = "Ohne Titel"
        }
        isAllDay = event.isAllDay
        if let location = event.location, !location.isEmpty {
            self.location = location
        } else {
            self.location = nil
        }
        calendarTitle = event.calendar?.title ?? ""
        color = event.calendar.map { Color(cgColor: $0.cgColor) } ?? .accentColor
        attendees = (event.attendees ?? []).compactMap { participant -> String? in
            guard !participant.isCurrentUser else { return nil }
            let link = participant.url.absoluteString
            guard link.lowercased().hasPrefix("mailto:") else { return nil }
            return String(link.dropFirst("mailto:".count)).removingPercentEncoding
        }
    }

    init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, calendarTitle: String, color: Color, attendees: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendarTitle = calendarTitle
        self.color = color
        self.attendees = attendees
    }

    var isOngoing: Bool { start <= .now && end > .now }

    var timeText: String {
        isAllDay ? "Ganztägig" : "\(Fmt.time(start)) – \(Fmt.time(end))"
    }

    var relativeText: String {
        if isOngoing { return isAllDay ? "Heute" : "Läuft gerade · bis \(Fmt.time(end))" }
        let text = Fmt.relative(start)
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }

    /// Öffnet den Termin in der Kalender-App.
    var calendarAppURL: URL? {
        URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)")
    }

    var mapsURL: URL? {
        guard let location, let query = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://maps.apple.com/?q=\(query)")
    }
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

/// Liest die Kalender des iPhones (inkl. Google-Konten aus den iOS-Einstellungen) über EventKit.
@MainActor
@Observable
final class CalendarService {
    private enum Keys {
        static let enabled = "calendar.enabled"
        static let hidden = "calendar.hidden"
    }

    let store = EKEventStore()
    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    private(set) var events: [CalendarEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastSync: Date?
    private(set) var isDemo = false
    private(set) var hiddenCalendarIDs: Set<String>
    private var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    var hasAccess: Bool { authorization == .fullAccess }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isConnected: Bool { isDemo || (hasAccess && isEnabled) }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Fragt den Vollzugriff an und aktiviert den Konnektor.
    func connect() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        authorization = EKEventStore.authorizationStatus(for: .event)
        if granted {
            isEnabled = true
            reload()
        }
        return granted
    }

    func disconnect() {
        isEnabled = false
        events = []
        calendars = []
    }

    func isVisible(_ calendarID: String) -> Bool {
        !hiddenCalendarIDs.contains(calendarID)
    }

    func setVisible(_ visible: Bool, calendarID: String) {
        if visible { hiddenCalendarIDs.remove(calendarID) } else { hiddenCalendarIDs.insert(calendarID) }
        UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Keys.hidden)
        reload()
    }

    func reload() {
        guard !isDemo else { return }
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess && isEnabled else {
            events = []
            calendars = []
            return
        }
        let all = store.calendars(for: .event)
        calendars = all
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "", color: Color(cgColor: $0.cgColor)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }

        let visible = all.filter { isVisible($0.calendarIdentifier) }
        guard !visible.isEmpty, let end = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now)) else {
            events = []
            return
        }
        let predicate = store.predicateForEvents(withStart: .now, end: end, calendars: visible)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { CalendarEvent($0) }
        lastSync = .now
    }

    /// Der nächste Termin, laufende ganztägige Termine zählen nicht.
    var nextEvent: CalendarEvent? {
        events.first { !($0.isAllDay && $0.isOngoing) } ?? events.first
    }
}

/// Der native Termin-Editor von iOS.
struct EventEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onDone()
        }
    }
}

#if DEBUG
extension CalendarService {
    func applyDemo() {
        isDemo = true
        let now = Date.now
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: now))!
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let work = Color(hex: 0x4C8DF6)
        let home = Color(hex: 0xF5A623)
        calendars = [
            CalendarInfo(id: "work", title: "Arbeit", account: "Google", color: work),
            CalendarInfo(id: "home", title: "Privat", account: "Google", color: home),
            CalendarInfo(id: "birthdays", title: "Geburtstage", account: "iCloud", color: Color(hex: 0xC9A7FF))
        ]
        events = [
            CalendarEvent(id: "1", title: "Wochenplanung", start: now.addingTimeInterval(25 * 60), end: now.addingTimeInterval(55 * 60), location: "Raum 4.12", calendarTitle: "Arbeit", color: work, attendees: ["team@example.com"]),
            CalendarEvent(id: "2", title: "Mittagessen mit Lea", start: at(0, 13), end: at(0, 14), location: "Markthalle", calendarTitle: "Privat", color: home),
            CalendarEvent(id: "3", title: "Design-Review", start: at(1, 10, 30), end: at(1, 11, 30), calendarTitle: "Arbeit", color: work, attendees: ["design@example.com"]),
            CalendarEvent(id: "4", title: "Laufrunde", start: at(1, 18), end: at(1, 19), calendarTitle: "Privat", color: home),
            CalendarEvent(id: "5", title: "Zahnarzt", start: at(3, 8, 15), end: at(3, 9), location: "Hauptstraße 3", calendarTitle: "Privat", color: home)
        ]
        lastSync = now
    }
}
#endif
