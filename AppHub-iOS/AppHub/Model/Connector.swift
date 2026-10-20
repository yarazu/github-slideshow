import SwiftUI

/// Die Konnektoren, die Orbit verbindet.
enum Connector: String, CaseIterable, Identifiable, Hashable {
    case calendar
    case gmail
    case spotify
    case discord

    var id: String { rawValue }

    var name: String {
        switch self {
        case .calendar: "Google Kalender"
        case .gmail: "Gmail"
        case .spotify: "Spotify"
        case .discord: "Discord"
        }
    }

    var shortName: String {
        switch self {
        case .calendar: "Kalender"
        case .gmail: "Gmail"
        case .spotify: "Spotify"
        case .discord: "Discord"
        }
    }

    var tagline: String {
        switch self {
        case .calendar: "Termine & Erinnerungen"
        case .gmail: "Posteingang & Entwürfe"
        case .spotify: "Wiedergabe & Playlists"
        case .discord: "Kanäle & Nachrichten"
        }
    }

    /// SF Symbol als Ersatz, wo kein Logo passt (z. B. in Menüs).
    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .gmail: "envelope.fill"
        case .spotify: "music.note"
        case .discord: "bubble.left.and.bubble.right.fill"
        }
    }

    /// Name des Logo-Bildes im Asset-Katalog (Vorlage, wird eingefärbt).
    var logoAsset: String {
        switch self {
        case .calendar: "logo-googlecalendar"
        case .gmail: "logo-gmail"
        case .spotify: "logo-spotify"
        case .discord: "logo-discord"
        }
    }

    /// Hintergrund der Kachel – angelehnt an das jeweilige App-Icon.
    var tileColor: Color {
        switch self {
        case .calendar, .gmail: .white
        case .spotify: Color(hex: 0x191414)
        case .discord: Color(hex: 0x5865F2)
        }
    }

    /// Farbe des Logos auf der Kachel.
    var logoColor: Color {
        switch self {
        case .calendar: Color(hex: 0x4285F4)
        case .gmail: Color(hex: 0xEA4335)
        case .spotify: Color(hex: 0x1ED760)
        case .discord: .white
        }
    }

    /// Markenfarbe für Akzente wie Labels und Badges.
    var tint: Color {
        switch self {
        case .calendar: Color(hex: 0x4C8DF6)
        case .gmail: Color(hex: 0xEA4335)
        case .spotify: Color(hex: 0x1ED760)
        case .discord: Color(hex: 0x7984F5)
        }
    }

    var permissions: [String] {
        switch self {
        case .calendar:
            ["Termine der nächsten 7 Tage anzeigen", "Vor Terminen erinnern (Flows)", "Neue Termine anlegen"]
        case .gmail:
            ["Posteingang & ungelesene Mails anzeigen", "Nur Lesezugriff – nichts wird gelöscht", "Bei neuen Mails benachrichtigen (Flows)"]
        case .spotify:
            ["Aktuellen Titel anzeigen", "Wiedergabe steuern (Premium)", "Zuletzt gehört & Playlists lesen"]
        case .discord:
            ["Nachrichten über einen Webhook in deinen Kanal senden", "Optional: letzte Nachrichten des Kanals lesen", "Status-Nachrichten aus Flows, z. B. „Bin im Meeting“"]
        }
    }

    /// OAuth-Anbieter, falls der Konnektor eine Anmeldung braucht.
    var provider: OAuthProvider? {
        switch self {
        case .calendar, .discord: nil
        case .gmail: .google
        case .spotify: .spotify
        }
    }
}
