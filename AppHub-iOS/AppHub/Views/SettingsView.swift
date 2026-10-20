import SwiftUI
import UIKit
import UserNotifications

/// Tab „Einstellungen“: Design, Konnektoren, Mitteilungen, Kurzbefehle und Infos zu Orbit.
struct SettingsView: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsDesignSection()
                SettingsConnectorsSection()
                SettingsNotificationsSection()
                SettingsShortcutsSection()
                SettingsAboutSection()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.large)
        .task { await hub.flows.refreshNotificationStatus() }
    }
}

// MARK: - Design

private struct SettingsDesignSection: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Design")
            NavigationLink(value: Route.appearance) {
                HStack(spacing: 16) {
                    SettingsBackgroundThumb()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Design & Hintergrund")
                            .font(.system(.headline, design: .rounded))
                        Text(sourceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appearance.accent)
                                .frame(width: 10, height: 10)
                            Text("Akzent \(appearance.accentChoice.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    SettingsChevron()
                }
                .padding(14)
                .glassCard(radius: 24)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var sourceName: String {
        switch appearance.source {
        case .photo: "Eigenes Foto"
        case .wallpaper(let wallpaper): "Bild „\(wallpaper.name)“"
        case .gradient(let preset): "Verlauf „\(preset.name)“"
        }
    }
}

/// Kleine Hochformat-Vorschau des aktuellen Hintergrunds.
private struct SettingsBackgroundThumb: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Color.clear
            .frame(width: 52, height: 86)
            .overlay {
                if let image = appearance.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PresetBackground(preset: appearance.gradient ?? .aurora)
                }
            }
            .overlay {
                Color.black.opacity(appearance.dim * 0.6)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Konnektoren

private struct SettingsConnectorsSection: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Konnektoren", trailing: "\(hub.connected.count) von \(Connector.allCases.count) verbunden")
            VStack(spacing: 0) {
                ForEach(Connector.allCases) { connector in
                    SettingsConnectorRow(connector: connector)
                    SettingsDivider()
                }
                NavigationLink(value: Route.setup) {
                    SettingsRowLabel(
                        symbol: "wrench.and.screwdriver.fill",
                        tint: Color.orbitLime,
                        title: "Einrichtung & Anleitungen",
                        detail: "Client-IDs, Discord-Webhook und Schritt-für-Schritt-Hilfe"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .glassCard(radius: 24)
        }
    }
}

private struct SettingsConnectorRow: View {
    @Environment(HubStore.self) private var hub
    let connector: Connector

    var body: some View {
        if hub.isConnected(connector) {
            NavigationLink(value: Route.connector(connector)) {
                label(connected: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                hub.connectSheet = connector
            } label: {
                label(connected: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(connected: Bool) -> some View {
        HStack(spacing: 14) {
            ConnectorIcon(connector: connector, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Text(connected ? detail : connector.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if connected {
                Circle()
                    .fill(.tint)
                    .frame(width: 8, height: 8)
                SettingsChevron()
            } else {
                Text("Verbinden")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(.tint, in: Capsule())
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connector.name), \(connected ? "verbunden" : "nicht verbunden")")
        .accessibilityHint(connected ? "Details öffnen" : "Verbinden")
    }

    private var detail: String {
        switch connector {
        case .calendar:
            let count = hub.calendar.events.count
            return count == 1 ? "Verbunden · 1 Termin in 7 Tagen" : "Verbunden · \(count) Termine in 7 Tagen"
        case .gmail:
            return hub.gmail.email.map { "Verbunden · \($0)" } ?? "Verbunden"
        case .spotify:
            return hub.spotify.displayName.map { "Verbunden · \($0)" } ?? "Verbunden"
        case .discord:
            return "Verbunden · \(hub.discord.channelLabel)"
        }
    }
}

// MARK: - Mitteilungen

private struct SettingsNotificationsSection: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        let granted = hub.flows.hasNotificationPermission
        let denied = hub.flows.notificationStatus == .denied
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Mitteilungen")
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SettingsSymbol(symbol: granted ? "bell.badge.fill" : "bell.slash.fill", tint: granted ? Color.orbitLime : Color.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(granted ? "Mitteilungen sind erlaubt" : "Mitteilungen sind aus")
                            .font(.system(.headline, design: .rounded))
                        Text(granted
                             ? "Flows können dich erinnern, Tagesüberblicke schicken und neue Mails melden."
                             : "Ohne Erlaubnis können Flows dir keine Nachrichten schicken – sie laufen dann nur, wenn du sie selbst startest.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if granted {
                    Button {
                        openNotificationSettings()
                    } label: {
                        Label("Mitteilungs-Einstellungen", systemImage: "gearshape")
                    }
                    .buttonStyle(GlassButtonStyle(height: 44))
                } else if denied {
                    Button("In Einstellungen öffnen") {
                        openNotificationSettings()
                    }
                    .buttonStyle(AccentButtonStyle())
                } else {
                    Button {
                        requestPermission()
                    } label: {
                        HStack(spacing: 8) {
                            if isRequesting {
                                ProgressView().tint(.black)
                            }
                            Text("Erlauben")
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(isRequesting)
                }
            }
            .padding(18)
            .glassCard(radius: 24)
        }
    }

    private func requestPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            let granted = await hub.flows.requestNotificationPermission()
            isRequesting = false
            hub.showToast(granted ? "Mitteilungen sind jetzt erlaubt" : "Mitteilungen bleiben ausgeschaltet")
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }
}

// MARK: - Kurzbefehle

private struct SettingsShortcutsSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Kurzbefehle")
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SettingsSymbol(symbol: "square.stack.3d.up.fill", tint: Color(hex: 0xC9A7FF))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flows vollautomatisch")
                            .font(.system(.headline, design: .rounded))
                        Text("In der Kurzbefehle-App kannst du Flows automatisch starten – z. B. wenn ein Wecker klingelt, du ankommst oder dein iPhone sich mit dem Auto verbindet: Automation › Neue Automation › Aktion „Flow ausführen“ von Orbit wählen. Oder sag einfach: „Starte einen Flow in Orbit“.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Kurzbefehle öffnen", systemImage: "arrow.up.right")
                }
                .buttonStyle(GlassButtonStyle(height: 44))
            }
            .padding(18)
            .glassCard(radius: 24)
        }
    }
}

// MARK: - Über Orbit

private struct SettingsAboutSection: View {
    @AppStorage("orbit.didOnboard") private var didOnboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Über Orbit")
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    HubMark(size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbit")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Dein Alltag, verbunden.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(versionText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                SettingsDivider()

                Text("Zugangsdaten wie Tokens und die Discord-Webhook-URL liegen nur im Schlüsselbund dieses iPhones. Orbit spricht direkt mit Google, Spotify und Discord – ohne eigenen Server dazwischen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Google Kalender, Gmail, Spotify und Discord sowie ihre Logos sind Marken ihrer jeweiligen Inhaber. Orbit steht in keiner Verbindung zu diesen Unternehmen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    didOnboard = false
                } label: {
                    Label("Einführung erneut ansehen", systemImage: "sparkles")
                }
                .buttonStyle(GlassButtonStyle(height: 44))
            }
            .padding(18)
            .glassCard(radius: 24)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}

// MARK: - Bausteine

private struct SettingsRowLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsSymbol(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            SettingsChevron()
        }
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSymbol: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().overlay(Color.white.opacity(0.08))
    }
}
