import SwiftUI

/// Hält alle Konnektoren und das Erscheinungsbild zusammen.
@MainActor
@Observable
final class HubStore {
    let calendar = CalendarService()
    let gmail = GmailService()
    let spotify = SpotifyService()
    let appearance = Appearance()

    /// Konnektor, dessen Verbinden-Sheet gerade offen ist.
    var connectSheet: Connector?
    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    func isConnected(_ connector: Connector) -> Bool {
        switch connector {
        case .calendar: calendar.isConnected
        case .gmail: gmail.isConnected
        case .spotify: spotify.isConnected
        }
    }

    var connected: [Connector] { Connector.allCases.filter { isConnected($0) } }

    func refreshAll() async {
        calendar.reload()
        async let mail: Void = gmail.refresh()
        async let music: Void = spotify.refreshAll()
        _ = await (mail, music)
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
    /// Für Simulator-Screenshots: `-AppHubDemo YES -AppHubScreen calendar`
    func applyLaunchArguments() -> Route? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AppHubDemo") {
            calendar.applyDemo()
            gmail.applyDemo()
            spotify.applyDemo()
        }
        switch defaults.string(forKey: "AppHubScreen") {
        case "calendar": return .connector(.calendar)
        case "gmail": return .connector(.gmail)
        case "spotify": return .connector(.spotify)
        case "appearance": return .appearance
        case "setup": return .setup
        case "connect": connectSheet = .gmail; return nil
        default: return nil
        }
    }
}
#endif
