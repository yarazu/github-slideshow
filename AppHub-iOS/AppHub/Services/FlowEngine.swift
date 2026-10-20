import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Flow-Engine

/// Führt Flows aus, plant ihre Mitteilungen und prüft nach jeder Aktualisierung auf neue Mails.
///
/// iOS erlaubt Apps keine dauerhafte Hintergrundausführung. Zeit- und Termin-Flows werden deshalb als
/// lokale Mitteilungen für die nächsten 7 Tage geplant. Schritte wie „Spotify pausieren“ laufen über den
/// Mitteilungs-Button „Aktionen ausführen“, über Kurzbefehle oder direkt in der App.
@MainActor
@Observable
final class FlowEngine {
    nonisolated static let backgroundTaskIdentifier = "com.yarazu.AppHub.refresh"
    /// Kategorie für Mitteilungen mit dem Button „Aktionen ausführen“.
    nonisolated static let categoryIdentifier = "ORBIT_FLOW"
    nonisolated static let runActionsIdentifier = "RUN_ACTIONS"
    /// Jede Mitteilung, die die Engine plant, beginnt mit diesem Präfix.
    nonisolated static let notificationPrefix = "flow."

    /// Geplante Zeit- und Termin-Mitteilungen; nur diese werden beim Neuplanen ersetzt.
    private static let planPrefix = "flow.plan."
    private static let seenMailKey = "flows.seenMailIDs"
    private static let maxScheduled = 60

    private(set) var flows: [Flow] = []
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Nächste geplante Mitteilung je Flow (für die Oberfläche).
    private(set) var nextRuns: [UUID: Date] = [:]
    private(set) var isDemo = false

    @ObservationIgnored private weak var hub: HubStore?
    @ObservationIgnored private var rescheduleTask: Task<Void, Never>?
    @ObservationIgnored private var statusKnown = false
    @ObservationIgnored private var didUpdateShortcuts = false
    /// Die Datei existiert, war aber nicht lesbar (z. B. vor dem ersten Entsperren) – dann nicht überschreiben.
    @ObservationIgnored private var isReadOnly = false

    var hasNotificationPermission: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    // MARK: Laden & Speichern

    /// Verbindet die Engine mit dem Store und lädt die gespeicherten Flows.
    func attach(to hub: HubStore) {
        self.hub = hub
        load()
    }

    private func load() {
        isReadOnly = false
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Allererster Start: drei Vorlagen zum Ausprobieren, noch ausgeschaltet.
            flows = ["morning", "meeting", "mail"].compactMap { key -> Flow? in
                guard var flow = FlowTemplates.make(key) else { return nil }
                flow.isEnabled = false
                return flow
            }
            persist()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            isReadOnly = true
            return
        }
        flows = (try? JSONDecoder().decode([Flow].self, from: data)) ?? []
    }

    private func persist() {
        guard !isDemo, !isReadOnly, let data = try? JSONEncoder().encode(flows) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("flows.json")
    }

    // MARK: Flows verwalten

    /// Fügt den Flow hinzu oder ersetzt ihn (gleiche `id`) und plant neu.
    func save(_ flow: Flow) {
        if let index = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[index] = flow
        } else {
            flows.append(flow)
        }
        flowsDidChange()
    }

    func delete(_ id: UUID) {
        flows.removeAll { $0.id == id }
        nextRuns[id] = nil
        flowsDidChange()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        flows.move(fromOffsets: source, toOffset: destination)
        persist()
        updateShortcuts()
    }

    /// Schaltet einen Flow ein oder aus; beim Einschalten wird bei Bedarf die Mitteilungs-Erlaubnis angefragt.
    func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard let index = flows.firstIndex(where: { $0.id == id }) else { return }
        flows[index].isEnabled = enabled
        let flow = flows[index]
        persist()
        if enabled {
            let alreadyScheduled = await askPermissionIfNeeded(for: flow)
            if alreadyScheduled { return }
        }
        await reschedule()
    }

    /// Fügt eine Kopie der Vorlage hinzu und gibt sie zurück.
    @discardableResult
    func addTemplate(_ key: String) -> Flow? {
        guard let flow = FlowTemplates.make(key) else { return nil }
        flows.append(flow)
        flowsDidChange()
        return flow
    }

    func hasTemplate(_ key: String) -> Bool {
        flows.contains { $0.templateKey == key }
    }

    func flow(id: UUID) -> Flow? {
        flows.first { $0.id == id }
    }

    /// Speichern, Kurzbefehle aktualisieren, neu planen. Fragt nie selbst nach Mitteilungen.
    private func flowsDidChange() {
        persist()
        updateShortcuts()
        Task { await self.reschedule() }
    }

    private func updateShortcuts() {
        guard !isDemo else { return }
        OrbitShortcuts.updateAppShortcutParameters()
    }

    // MARK: Ausführen

    /// Führt alle Schritte des Flows jetzt aus, schreibt jeden Schritt in den Verlauf und gibt eine Zusammenfassung zurück.
    @discardableResult
    func run(_ flow: Flow, context: FlowContext? = nil, includeMessages: Bool = true) async -> String {
        let resolved: FlowContext
        if let context {
            resolved = context
        } else {
            resolved = makeContext()
        }
        return await execute(flow, context: resolved, includeMessages: includeMessages, logSummary: true)
    }

    @discardableResult
    func run(id: UUID) async -> String {
        guard let flow = self.flow(id: id) else { return "Flow nicht gefunden" }
        await prepareData()
        return await run(flow)
    }

    /// Die Daten für Platzhalter: Termine des Tages und des Folgetags, ungelesene Mails, ggf. Termin oder Mail des Auslösers.
    func makeContext(date: Date = .now, event: CalendarEvent? = nil, mail: GmailMessage? = nil) -> FlowContext {
        let calendar = Calendar.current
        let events = hub?.calendar.events ?? []
        let today = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        var unread: Int?
        if let hub, hub.gmail.isConnected {
            unread = hub.gmail.unreadCount
        }
        return FlowContext(
            date: date,
            eventsToday: Self.events(events, on: today, calendar: calendar),
            eventsTomorrow: Self.events(events, on: tomorrow, calendar: calendar),
            event: event,
            mail: mail,
            unreadCount: unread
        )
    }

    @discardableResult
    private func execute(_ flow: Flow, context: FlowContext, includeMessages: Bool, logSummary: Bool) async -> String {
        let steps = flow.steps.filter { step in
            if case .notify = step.action { return includeMessages }
            return true
        }
        var done = 0
        for step in steps {
            let succeeded = await perform(step.action, of: flow, context: context)
            if succeeded { done += 1 }
        }
        markRun(flow.id)
        let summary = Self.summary(done: done, total: steps.count)
        if logSummary {
            hub?.activity.add(.run, title: "\(flow.name) gestartet", detail: summary, flowName: flow.name)
        }
        return summary
    }

    /// Führt einen Schritt aus und schreibt das Ergebnis in den Verlauf. `true` = erfolgreich.
    private func perform(_ action: FlowAction, of flow: Flow, context: FlowContext) async -> Bool {
        guard let hub else { return false }
        if let connector = action.connector, !hub.isConnected(connector) {
            hub.activity.add(
                Self.kind(for: connector),
                title: "\(connector.name) nicht verbunden",
                detail: "„\(action.title)“ wurde übersprungen.",
                flowName: flow.name
            )
            return false
        }

        switch action {
        case .notify(let title, let body):
            let text = Self.texts(title: context.render(title), body: context.render(body), fallback: flow.name)
            let kind: ActivityEntry.Kind = context.mail == nil ? .message : .mail
            var identifier: String?
            if !isDemo {
                identifier = await deliver(title: text.title, body: text.body, kind: kind, flow: flow, context: context, prefix: "now", delay: 1)
            }
            hub.activity.add(kind, title: text.title, detail: text.body, flowName: flow.name, notificationID: identifier)
            return true

        case .discord(let message):
            let text = context.render(message)
            guard !text.isEmpty else {
                hub.activity.add(.error, title: "Discord-Nachricht ist leer", detail: "Trage im Flow einen Text ein.", flowName: flow.name)
                return false
            }
            do {
                if !isDemo || hub.discord.isDemo {
                    try await hub.discord.send(text, flowName: flow.name)
                }
                hub.activity.add(.discord, title: "Discord: \(hub.discord.channelLabel)", detail: text, flowName: flow.name)
                return true
            } catch {
                hub.activity.add(.error, title: "Discord-Nachricht fehlgeschlagen", detail: Self.describe(error), flowName: flow.name)
                return false
            }

        case .spotifyPause:
            let track = hub.spotify.playback?.item?.name ?? ""
            if hub.spotify.playback != nil && !hub.spotify.isPlaying {
                hub.activity.add(.spotify, title: "Spotify war bereits pausiert", detail: track, flowName: flow.name)
                return true
            }
            do {
                if !isDemo || hub.spotify.isDemo {
                    try await hub.spotify.pause()
                }
                hub.activity.add(.spotify, title: "Spotify pausiert", detail: track, flowName: flow.name)
                return true
            } catch {
                hub.activity.add(.error, title: "Spotify konnte nicht pausieren", detail: Self.describe(error), flowName: flow.name)
                return false
            }

        case .spotifyPlay(let uri, let name):
            do {
                if !isDemo || hub.spotify.isDemo {
                    if let uri, !uri.isEmpty {
                        try await hub.spotify.play(contextURI: uri)
                    } else {
                        try await hub.spotify.resume()
                    }
                }
                let title: String
                if let name {
                    title = "Spotify: \(name)"
                } else {
                    title = uri == nil ? "Spotify fortgesetzt" : "Spotify-Playlist gestartet"
                }
                hub.activity.add(.spotify, title: title, detail: hub.spotify.playback?.item?.name ?? "", flowName: flow.name)
                return true
            } catch {
                hub.activity.add(.error, title: "Spotify konnte nicht abspielen", detail: Self.describe(error), flowName: flow.name)
                return false
            }

        case .reminder(let minutes, let text):
            let body = context.render(text)
            let delay = max(minutes, 1)
            if !isDemo {
                await deliver(title: flow.name, body: body, kind: .reminder, flow: flow, context: context, prefix: "reminder", delay: TimeInterval(delay * 60))
            }
            hub.activity.add(.reminder, title: "Erinnerung in \(delay) Min.", detail: body, flowName: flow.name)
            return true
        }
    }

    private func markRun(_ id: UUID) {
        guard let index = flows.firstIndex(where: { $0.id == id }) else { return }
        flows[index].lastRun = .now
        persist()
    }

    /// Lädt fehlende Daten nach, wenn die App nur im Hintergrund läuft (Kurzbefehl, Mitteilungs-Button).
    private func prepareData() async {
        guard let hub, !isDemo else { return }
        if hub.calendar.lastSync == nil {
            hub.calendar.reload()
        }
        if hub.gmail.isConnected && hub.gmail.lastSync == nil {
            await hub.gmail.refresh()
        }
    }

    /// Stellt eine Mitteilung nach `delay` Sekunden zu und gibt ihre Kennung zurück.
    @discardableResult
    private func deliver(title: String, body: String, kind: ActivityEntry.Kind, flow: Flow, context: FlowContext, prefix: String, delay: TimeInterval) async -> String {
        let identifier = "\(Self.notificationPrefix)\(prefix).\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = Self.notificationPrefix + flow.id.uuidString
        content.userInfo = userInfo(flow: flow, kind: kind, context: context)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        _ = try? await UNUserNotificationCenter.current().add(request)
        return identifier
    }

    private func userInfo(flow: Flow, kind: ActivityEntry.Kind, context: FlowContext?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "flowID": flow.id.uuidString,
            "flowName": flow.name,
            "kind": kind.rawValue
        ]
        if let event = context?.event {
            info["eventID"] = event.id
            info["eventTitle"] = event.title
            info["eventStart"] = event.start.timeIntervalSince1970
            info["eventEnd"] = event.end.timeIntervalSince1970
            if let location = event.location {
                info["eventLocation"] = location
            }
        }
        if let mail = context?.mail {
            info["mailID"] = mail.id
            info["mailSender"] = mail.sender
            info["mailAddress"] = mail.senderAddress
            info["mailSubject"] = mail.subject
        }
        return info
    }

    // MARK: Mitteilungen

    func refreshNotificationStatus() async {
        guard !isDemo else { return }
        let wasPermitted = hasNotificationPermission
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
        // Erlaubnis wurde z. B. in den iOS-Einstellungen erteilt → sofort planen.
        let shouldReschedule = statusKnown && !wasPermitted && hasNotificationPermission
        statusKnown = true
        if shouldReschedule {
            await reschedule()
        }
    }

    /// Fragt die Mitteilungs-Erlaubnis an (nur auf Nutzeraktion aufrufen) und plant danach neu.
    func requestNotificationPermission() async -> Bool {
        guard !isDemo else { return true }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        let settings = await center.notificationSettings()
        notificationStatus = settings.authorizationStatus
        statusKnown = true
        if granted {
            await reschedule()
        }
        return granted
    }

    /// Fragt die Erlaubnis an, wenn der Flow Mitteilungen braucht und noch nie gefragt wurde.
    /// Gibt `true` zurück, wenn dabei schon neu geplant wurde.
    private func askPermissionIfNeeded(for flow: Flow) async -> Bool {
        guard !isDemo, flow.isEnabled, Self.needsNotifications(flow), notificationStatus == .notDetermined else { return false }
        return await requestNotificationPermission()
    }

    /// Ersetzt alle geplanten Zeit- und Termin-Mitteilungen. Aufrufe laufen nacheinander, nie parallel.
    func reschedule() async {
        let previous = rescheduleTask
        let task = Task {
            if let previous {
                await previous.value
            }
            await self.performReschedule()
        }
        rescheduleTask = task
        await task.value
    }

    private func performReschedule() async {
        guard !isDemo else {
            nextRuns = Self.firstRuns(in: makePlan())
            return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationStatus = settings.authorizationStatus
        statusKnown = true

        let pending = await center.pendingNotificationRequests()
        let planned = pending.map { $0.identifier }.filter { $0.hasPrefix(Self.planPrefix) }
        guard hasNotificationPermission else {
            if !planned.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: planned)
            }
            nextRuns = [:]
            return
        }

        let plan = makePlan()
        let keep = Set(plan.map { $0.identifier })
        let stale = planned.filter { !keep.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        // Gleiche Kennung ersetzt die bestehende Anfrage – so bleiben Inhalte aktuell.
        for item in plan {
            let request = UNNotificationRequest(identifier: item.identifier, content: notificationContent(for: item), trigger: item.trigger)
            _ = try? await center.add(request)
        }
        nextRuns = Self.firstRuns(in: plan)
    }

    /// Alle anstehenden Mitteilungen der nächsten 7 Tage, nach Zeit sortiert, höchstens 60.
    private func makePlan(now: Date = .now) -> [PlannedRun] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let events = hub?.calendar.events ?? []
        var plan: [PlannedRun] = []
        for flow in flows where flow.isEnabled {
            switch flow.trigger {
            case .manual, .newMail:
                continue
            case .daily(let hour, let minute, let weekdays):
                for offset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
                    if !weekdays.isEmpty && !weekdays.contains(calendar.component(.weekday, from: day)) { continue }
                    guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), date > now else { continue }
                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    let stamp = String(
                        format: "%04d%02d%02d%02d%02d",
                        components.year ?? 0, components.month ?? 0, components.day ?? 0, components.hour ?? 0, components.minute ?? 0
                    )
                    plan.append(PlannedRun(
                        flow: flow,
                        date: date,
                        event: nil,
                        components: components,
                        identifier: "\(Self.planPrefix)\(flow.id.uuidString).\(stamp)"
                    ))
                }
            case .beforeEvent(let minutes):
                for event in events where !event.isAllDay {
                    let date = event.start.addingTimeInterval(-TimeInterval(max(minutes, 0) * 60))
                    guard date > now else { continue }
                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    plan.append(PlannedRun(
                        flow: flow,
                        date: date,
                        event: event,
                        components: components,
                        identifier: "\(Self.planPrefix)\(flow.id.uuidString).\(minutes).\(event.id)"
                    ))
                }
            }
        }
        plan.sort { $0.date < $1.date }
        return Array(plan.prefix(Self.maxScheduled))
    }

    private func notificationContent(for item: PlannedRun) -> UNMutableNotificationContent {
        let flow = item.flow
        let context = makeContext(date: item.date, event: item.event)
        let content = UNMutableNotificationContent()
        if let message = flow.firstMessage {
            let text = Self.texts(title: context.render(message.title), body: context.render(message.body), fallback: flow.name)
            content.title = text.title
            content.body = text.body
        } else {
            content.title = flow.name
            content.body = Self.actionHint(for: flow)
        }
        content.sound = .default
        content.threadIdentifier = Self.notificationPrefix + flow.id.uuidString
        if flow.hasActionSteps {
            content.categoryIdentifier = Self.categoryIdentifier
        }
        content.userInfo = userInfo(flow: flow, kind: .message, context: context)
        return content
    }

    // MARK: Nach jeder Aktualisierung

    /// Neue Mails prüfen, zugestellte Mitteilungen in den Verlauf übernehmen, neu planen.
    func afterRefresh() async {
        guard !isDemo else { return }
        if isReadOnly { load() }
        await checkNewMail()
        await collectDelivered()
        await reschedule()
        scheduleBackgroundRefresh()
        if !didUpdateShortcuts {
            didUpdateShortcuts = true
            OrbitShortcuts.updateAppShortcutParameters()
        }
    }

    private func checkNewMail() async {
        guard let hub, hub.gmail.isConnected, hub.gmail.lastSync != nil else { return }
        let messages = hub.gmail.messages
        let defaults = UserDefaults.standard
        let storedIDs = defaults.stringArray(forKey: Self.seenMailKey)

        let currentIDs = messages.map { $0.id }
        let current = Set(currentIDs)
        let remembered = currentIDs + (storedIDs ?? []).filter { !current.contains($0) }
        defaults.set(Array(remembered.prefix(300)), forKey: Self.seenMailKey)

        // Beim allerersten Abgleich nur merken, damit alte Mails keine Flows auslösen.
        guard let known = storedIDs else { return }
        let seen = Set(known)
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        let fresh = messages.filter { $0.isUnread && !seen.contains($0.id) && $0.date > cutoff }.prefix(5)
        guard !fresh.isEmpty else { return }

        let mailFlows = flows.filter { flow in
            guard flow.isEnabled, case .newMail = flow.trigger else { return false }
            return true
        }
        guard !mailFlows.isEmpty else { return }
        // Älteste zuerst, damit der Verlauf die richtige Reihenfolge hat.
        for mail in fresh.reversed() {
            for flow in mailFlows where Self.matches(flow.trigger, mail) {
                await execute(flow, context: makeContext(mail: mail), includeMessages: true, logSummary: false)
            }
        }
    }

    private func collectDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        for notification in delivered {
            if let message = DeliveredFlowMessage(notification) {
                record(message)
            }
        }
    }

    /// Übernimmt eine zugestellte Mitteilung in den Verlauf (doppelte Kennungen werden ignoriert).
    func record(_ message: DeliveredFlowMessage) {
        guard !isDemo, let hub else { return }
        hub.activity.add(
            message.kind,
            title: message.title,
            detail: message.body,
            flowName: message.flowName,
            notificationID: message.identifier,
            date: message.date
        )
    }

    /// Reaktion auf eine angetippte Mitteilung: „Aktionen ausführen“ startet die übrigen Schritte des Flows.
    func handle(response: UNNotificationResponse) async {
        let notification = response.notification
        if let message = DeliveredFlowMessage(notification) {
            record(message)
        }
        switch response.actionIdentifier {
        case Self.runActionsIdentifier:
            guard !isDemo else { return }
            let info = notification.request.content.userInfo
            guard let raw = info["flowID"] as? String, let id = UUID(uuidString: raw), let flow = self.flow(id: id) else {
                hub?.activity.add(.error, title: "Flow nicht gefunden", detail: "Der Flow wurde inzwischen gelöscht.")
                return
            }
            await prepareData()
            let context = makeContext(event: self.event(from: info), mail: self.mail(from: info))
            await execute(flow, context: context, includeMessages: false, logSummary: true)
        case UNNotificationDefaultActionIdentifier:
            hub?.selectedTab = .activity
        default:
            break
        }
    }

    /// Termin aus den Mitteilungsdaten – bevorzugt der aktuelle Stand aus dem Kalender.
    private func event(from info: [AnyHashable: Any]) -> CalendarEvent? {
        guard let title = info["eventTitle"] as? String,
              let start = info["eventStart"] as? Double,
              let end = info["eventEnd"] as? Double else { return nil }
        let id = (info["eventID"] as? String) ?? UUID().uuidString
        if let live = hub?.calendar.events.first(where: { $0.id == id }) {
            return live
        }
        return CalendarEvent(
            id: id,
            title: title,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            isAllDay: false,
            location: info["eventLocation"] as? String,
            calendarTitle: "",
            color: .accentColor,
            attendees: []
        )
    }

    private func mail(from info: [AnyHashable: Any]) -> GmailMessage? {
        guard let sender = info["mailSender"] as? String else { return nil }
        let id = (info["mailID"] as? String) ?? ""
        return GmailMessage(
            id: id,
            threadID: id,
            sender: sender,
            senderAddress: (info["mailAddress"] as? String) ?? "",
            subject: (info["mailSubject"] as? String) ?? "",
            snippet: "",
            date: .now,
            isUnread: true
        )
    }

    /// Bittet iOS, die App in frühestens 30 Minuten im Hintergrund zu aktualisieren.
    func scheduleBackgroundRefresh() {
        guard !isDemo else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Hilfen

    private static func events(_ events: [CalendarEvent], on day: Date, calendar: Calendar) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { $0.start < end && $0.end > start }
            .sorted { $0.start < $1.start }
    }

    private static func firstRuns(in plan: [PlannedRun]) -> [UUID: Date] {
        var runs: [UUID: Date] = [:]
        for item in plan where runs[item.flow.id] == nil {
            runs[item.flow.id] = item.date
        }
        return runs
    }

    private static func matches(_ trigger: FlowTrigger, _ mail: GmailMessage) -> Bool {
        guard case .newMail(let sender) = trigger else { return false }
        let filter = sender.trimmingCharacters(in: .whitespaces)
        if filter.isEmpty { return true }
        return mail.sender.localizedCaseInsensitiveContains(filter) || mail.senderAddress.localizedCaseInsensitiveContains(filter)
    }

    private static func needsNotifications(_ flow: Flow) -> Bool {
        if flow.trigger.kind != .manual { return true }
        return flow.steps.contains { step in
            if case .notify = step.action { return true }
            if case .reminder = step.action { return true }
            return false
        }
    }

    private static func texts(title: String, body: String, fallback: String) -> (title: String, body: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanTitle.isEmpty ? fallback : cleanTitle, cleanBody)
    }

    private static func actionHint(for flow: Flow) -> String {
        let actions = flow.steps.map { $0.action.title }.joined(separator: ", ")
        if actions.isEmpty { return "Dein Flow ist dran." }
        return "Gedrückt halten und „Aktionen ausführen“ wählen: \(actions)"
    }

    private static func summary(done: Int, total: Int) -> String {
        if total == 0 { return "Keine Aktionen" }
        let noun = total == 1 ? "Aktion" : "Aktionen"
        return "\(done) von \(total) \(noun) ausgeführt"
    }

    private static func kind(for connector: Connector) -> ActivityEntry.Kind {
        switch connector {
        case .discord: .discord
        case .spotify: .spotify
        case .gmail: .mail
        case .calendar: .error
        }
    }

    private static func describe(_ error: Error) -> String {
        if let spotify = error as? SpotifyAPIError {
            return spotify.notice.text
        }
        return error.localizedDescription
    }

    // MARK: Demo

    #if DEBUG
    /// Beispiel-Flows für Simulator-Screenshots – plant keine echten Mitteilungen.
    func applyDemo() {
        isDemo = true
        notificationStatus = .authorized
        statusKnown = true
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: day, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        var demo: [Flow] = []
        for key in ["morning", "meeting", "mail", "focus", "evening"] {
            guard var flow = FlowTemplates.make(key) else { continue }
            flow.isEnabled = (key != "evening")
            switch key {
            case "morning": flow.lastRun = at(0, 7, 30)
            case "meeting": flow.lastRun = at(0, 8, 50)
            case "mail": flow.lastRun = at(0, 8, 12)
            case "focus": flow.lastRun = at(-1, 14, 20)
            default: break
            }
            demo.append(flow)
        }
        flows = demo
        nextRuns = Self.firstRuns(in: makePlan())
    }
    #endif
}

/// Eine geplante Mitteilung eines Flows.
private struct PlannedRun {
    let flow: Flow
    let date: Date
    let event: CalendarEvent?
    let components: DateComponents
    let identifier: String

    var trigger: UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
}

/// Die Teile einer zugestellten Orbit-Mitteilung, die im Verlauf landen.
struct DeliveredFlowMessage: Sendable {
    let identifier: String
    let title: String
    let body: String
    let flowName: String?
    let kind: ActivityEntry.Kind
    let date: Date

    /// `nil`, wenn die Mitteilung nicht von der Flow-Engine stammt.
    init?(_ notification: UNNotification) {
        let request = notification.request
        guard request.identifier.hasPrefix(FlowEngine.notificationPrefix) else { return nil }
        let content = request.content
        identifier = request.identifier
        title = content.title
        body = content.body
        flowName = content.userInfo["flowName"] as? String
        kind = (content.userInfo["kind"] as? String).flatMap { ActivityEntry.Kind(rawValue: $0) } ?? .message
        date = notification.date
    }
}

// MARK: - App-Delegate

/// Registriert die Mitteilungs-Kategorie und die Hintergrundaktualisierung und leitet Mitteilungen an die Flow-Engine weiter.
@MainActor
final class OrbitAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.flowCategory])
        // Muss vor dem Ende des App-Starts passieren.
        Self.registerBackgroundRefresh()
        return true
    }

    private static var flowCategory: UNNotificationCategory {
        let run = UNNotificationAction(identifier: FlowEngine.runActionsIdentifier, title: "Aktionen ausführen", options: [])
        return UNNotificationCategory(identifier: FlowEngine.categoryIdentifier, actions: [run], intentIdentifiers: [], options: [])
    }

    nonisolated private static func registerBackgroundRefresh() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: FlowEngine.backgroundTaskIdentifier, using: nil) { task in
            OrbitAppDelegate.runBackgroundRefresh(task)
        }
    }

    nonisolated private static func runBackgroundRefresh(_ task: BGTask) {
        let work = Task { @MainActor in
            let hub = HubStore.shared
            // Gleich den nächsten Lauf anmelden, falls dieser abbricht.
            hub.flows.scheduleBackgroundRefresh()
            await hub.refreshAll()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Auch bei geöffneter App als Banner zeigen und im Verlauf festhalten.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let message = DeliveredFlowMessage(notification) {
            Task { @MainActor in
                HubStore.shared.flows.record(message)
            }
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await HubStore.shared.flows.handle(response: response)
            completionHandler()
        }
    }
}
