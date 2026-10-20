import SwiftUI

/// Die Konnektoren, die der Hub verbindet.
enum Connector: String, CaseIterable, Identifiable, Hashable {
    case calendar
    case gmail
    case spotify

    var id: String { rawValue }

    var name: String {
        switch self {
        case .calendar: "Google Kalender"
        case .gmail: "Gmail"
        case .spotify: "Spotify"
        }
    }

    var shortName: String {
        switch self {
        case .calendar: "Kalender"
        case .gmail: "Gmail"
        case .spotify: "Spotify"
        }
    }

    var tagline: String {
        switch self {
        case .calendar: "Termine & Erinnerungen"
        case .gmail: "Posteingang & Entwürfe"
        case .spotify: "Wiedergabe & Playlists"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .gmail: "envelope.fill"
        case .spotify: "music.note"
        }
    }

    var tint: Color {
        switch self {
        case .calendar: Color(hex: 0x4C8DF6)
        case .gmail: Color(hex: 0xEA4335)
        case .spotify: Color(hex: 0x1ED760)
        }
    }

    var permissions: [String] {
        switch self {
        case .calendar:
            ["Termine der nächsten 7 Tage anzeigen", "Neue Termine anlegen", "Teilnehmende per E-Mail anschreiben"]
        case .gmail:
            ["Posteingang & ungelesene Mails anzeigen", "Nur Lesezugriff – nichts wird gelöscht", "Neue E-Mails in Gmail verfassen"]
        case .spotify:
            ["Aktuellen Titel anzeigen", "Wiedergabe steuern (Premium)", "Zuletzt gehört & Playlists lesen"]
        }
    }

    /// OAuth-Anbieter, falls der Konnektor eine Anmeldung braucht.
    var provider: OAuthProvider? {
        switch self {
        case .calendar: nil
        case .gmail: .google
        case .spotify: .spotify
        }
    }
}
