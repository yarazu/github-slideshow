import SwiftUI

/// Die vier Tabs der App.
enum AppTab: Hashable {
    case hub, flows, activity, settings
}

/// Hält alle Konnektoren, Flows, den Verlauf und das Erscheinungsbild zusammen.
@MainActor
@Observable
final class HubStore {
    /// Gemeinsame Instanz für App, Mitteilungen, Hintergrundaktualisierung und Kurzbefehle.
    static let shared = HubStore()

    let calendar = CalendarService()
    let gmail = GmailService()
    let spotify = SpotifyService()
    let discord = DiscordService()
    let appearance = Appearance()
    let activity = ActivityLog()
    let flows = FlowEngine()

    /// Konnektor, dessen Verbinden-Sheet gerade offen ist.
    var connectSheet: Connector?
    var selectedTab: AppTab = .hub
    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    init() {
        flows.attach(to: self)
    }

    func isConnected(_ connector: Connector) -> Bool {
        switch connector {
        case .calendar: calendar.isConnected
        case .gmail: gmail.isConnected
        case .spotify: spotify.isConnected
        case .discord: discord.isConnected
        }
    }

    var connected: [Connector] { Connector.allCases.filter { isConnected($0) } }

    /// Lädt alle Konnektoren neu und lässt danach die Flows prüfen (neue Mails, Mitteilungen planen).
    func refreshAll() async {
        calendar.reload()
        async let mail: Void = gmail.refresh()
        async let music: Void = spotify.refreshAll()
        async let chat: Void = discord.refresh()
        _ = await (mail, music, chat)
        await flows.afterRefresh()
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

#if DEBUG
extension HubStore {
    /// Für Simulator-Screenshots: `-AppHubDemo YES -AppHubScreen flows`
    var isDemo: Bool { UserDefaults.standard.bool(forKey: "AppHubDemo") }

    /// Bildschirm, der beim Start geöffnet werden soll (siehe `RootView`).
    var launchScreen: String? { UserDefaults.standard.string(forKey: "AppHubScreen") }

    func applyDemo() {
        calendar.applyDemo()
        gmail.applyDemo()
        spotify.applyDemo()
        discord.applyDemo()
        activity.applyDemo()
        flows.applyDemo()
    }
}
#endif
