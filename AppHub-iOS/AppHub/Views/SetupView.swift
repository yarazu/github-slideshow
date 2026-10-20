import SwiftUI
import UIKit

/// Einrichtung der Konnektoren: Client-IDs und Schritt-für-Schritt-Anleitungen.
struct SetupView: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Gmail und Spotify verbinden sich über deine eigenen, kostenlosen Entwickler-Zugänge. So bleiben deine Daten zwischen dir und dem Anbieter – kein fremder Server dazwischen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProviderCard(connector: .gmail)
                ProviderCard(connector: .spotify)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ConnectorIcon(connector: .calendar, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Connector.calendar.name).font(.headline)
                            Text(hub.calendar.isConnected ? "Verbunden" : "Keine Einrichtung nötig")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Der Kalender nutzt die Kalender deines iPhones. Damit dein Google Kalender erscheint, füge dein Google-Konto unter Einstellungen › Apps › Kalender › Kalender-Accounts hinzu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassCard()
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle("Konnektoren einrichten")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProviderCard: View {
    let connector: Connector
    @Environment(HubStore.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ConnectorIcon(connector: connector, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name).font(.headline)
                    Text(hub.isConnected(connector) ? "Verbunden" : "Nicht verbunden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !hub.isConnected(connector) {
                    Button("Verbinden") { hub.connectSheet = connector }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(TintShapeStyle().opacity(0.18), in: Capsule())
                }
            }
            SetupSteps(connector: connector)
            if let provider = connector.provider {
                ClientIDField(provider: provider)
            }
        }
        .padding(18)
        .glassCard()
    }
}

/// Nummerierte Anleitung mit kopierbaren Werten.
struct SetupSteps: View {
    let connector: Connector

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(.tint, in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.text)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        if let value = step.copyValue {
                            CopyValue(value: value)
                        }
                        if let link = step.link {
                            Link(destination: link.url) {
                                Label(link.title, systemImage: "arrow.up.right.square")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Step {
        let text: String
        var copyValue: String? = nil
        var link: (title: String, url: URL)? = nil
    }

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "com.yarazu.AppHub" }

    private var steps: [Step] {
        switch connector {
        case .gmail:
            [
                Step(text: "Erstelle in der Google Cloud Console ein Projekt.", link: ("Google Cloud Console öffnen", URL(string: "https://console.cloud.google.com/projectcreate")!)),
                Step(text: "Aktiviere unter „APIs & Dienste“ die Gmail API.", link: ("Gmail API aktivieren", URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)),
                Step(text: "Richte den OAuth-Zustimmungsbildschirm ein (Zielgruppe „Extern“) und trage dich selbst als Testnutzer ein."),
                Step(text: "Lege unter „Anmeldedaten“ eine OAuth-Client-ID vom Typ „iOS“ mit dieser Bundle-ID an:", copyValue: bundleID),
                Step(text: "Kopiere die Client-ID und füge sie unten ein.")
            ]
        case .spotify:
            [
                Step(text: "Melde dich im Spotify Developer Dashboard an und tippe auf „Create app“.", link: ("Dashboard öffnen", URL(string: "https://developer.spotify.com/dashboard")!)),
                Step(text: "Trage diese Redirect-URI ein und wähle „Web API“ aus:", copyValue: "apphub://spotify-callback"),
                Step(text: "Kopiere die Client-ID aus den App-Einstellungen und füge sie unten ein. Für die Steuerung der Wiedergabe brauchst du Spotify Premium.")
            ]
        case .calendar:
            [
                Step(text: "Öffne die iOS-Einstellungen › Apps › Kalender › Kalender-Accounts und füge dein Google-Konto hinzu."),
                Step(text: "Tippe im Hub auf „Kalender“ und erlaube den Zugriff.")
            ]
        }
    }
}

private struct CopyValue: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 8) {
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Kopiert" : "\(value) kopieren")
    }
}
