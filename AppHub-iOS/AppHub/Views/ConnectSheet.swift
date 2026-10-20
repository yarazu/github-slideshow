import AuthenticationServices
import SwiftUI
import UIKit

/// Das Verbinden-Overlay aus dem Entwurf – jetzt mit echter Anmeldung.
struct ConnectSheet: View {
    let connector: Connector

    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var showGuide = false
    @State private var webhookURL = ""
    @State private var botToken = ""
    @AppStorage private var clientID: String

    init(connector: Connector) {
        self.connector = connector
        _clientID = AppStorage(wrappedValue: "", connector.provider?.clientIDKey ?? "calendar.clientID")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                    .accessibilityHidden(true)

                ConnectionVisual(connector: connector, connected: false, size: 64)
                    .padding(.top, 6)

                VStack(spacing: 8) {
                    Text("\(connector.name) verbinden")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                PermissionList(items: connector.permissions)

                if let provider = connector.provider {
                    ClientIDField(provider: provider)
                    DisclosureGroup(isExpanded: $showGuide) {
                        SetupSteps(connector: connector)
                            .padding(.top, 10)
                    } label: {
                        Label("So bekommst du eine Client-ID", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(16)
                    .glassCard(radius: 20)
                }

                if connector == .discord {
                    DiscordFields(webhookURL: $webhookURL, botToken: $botToken)
                    DisclosureGroup(isExpanded: $showGuide) {
                        SetupSteps(connector: .discord)
                            .padding(.top, 10)
                    } label: {
                        Label("So legst du einen Webhook an", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(16)
                    .glassCard(radius: 20)
                }

                if let errorText {
                    NoticeBanner(text: errorText)
                }

                VStack(spacing: 8) {
                    Button(action: connect) {
                        if isWorking {
                            ProgressView().tint(.black)
                        } else {
                            Text(primaryTitle)
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(isWorking || needsClientID)
                    .opacity(needsClientID ? 0.5 : 1)

                    Button("Abbrechen") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .hubSheetBackground()
    }

    private var subtitle: String {
        switch connector {
        case .calendar:
            "Nutzt die Kalender deines iPhones – auch Google-Kalender, die unter Einstellungen › Apps › Kalender › Kalender-Accounts eingerichtet sind."
        case .gmail:
            "Du meldest dich direkt bei Google an. Orbit erhält nur Lesezugriff, den du jederzeit wieder entziehen kannst."
        case .spotify:
            "Du meldest dich direkt bei Spotify an. Die Verbindung lässt sich jederzeit wieder trennen."
        case .discord:
            "Orbit postet über einen Webhook in deinen Kanal – ganz ohne Passwort. Mit einem optionalen Bot liest Orbit auch die letzten Nachrichten mit."
        }
    }

    private var primaryTitle: String {
        switch connector {
        case .calendar: hub.calendar.isDenied ? "In den Einstellungen erlauben" : "Zugriff erlauben"
        case .gmail: "Mit Google anmelden"
        case .spotify: "Mit Spotify anmelden"
        case .discord: "Mit Discord verbinden"
        }
    }

    /// Fehlt noch eine Pflichtangabe (Client-ID bzw. gültige Webhook-URL)?
    private var needsClientID: Bool {
        switch connector {
        case .discord:
            !DiscordService.isValidWebhookURL(webhookURL)
        case .calendar, .gmail, .spotify:
            connector.provider != nil && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func connect() {
        errorText = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch connector {
                case .calendar:
                    if hub.calendar.isDenied {
                        if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                        return
                    }
                    guard await hub.calendar.connect() else {
                        errorText = "Ohne Kalenderzugriff kann Orbit keine Termine anzeigen."
                        return
                    }
                case .gmail:
                    try await hub.gmail.auth.signIn(using: webAuthenticationSession)
                    await hub.gmail.refresh()
                case .spotify:
                    try await hub.spotify.auth.signIn(using: webAuthenticationSession)
                    await hub.spotify.refreshAll()
                case .discord:
                    let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await hub.discord.connect(webhookURL: webhookURL, botToken: token.isEmpty ? nil : token)
                    webhookURL = ""
                    botToken = ""
                }
                hub.showToast("\(connector.name) ist jetzt verbunden")
                dismiss()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Abgebrochen – nichts zu tun.
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Eingabefeld für die eigene OAuth-Client-ID.
struct ClientIDField: View {
    let provider: OAuthProvider
    @AppStorage private var clientID: String

    init(provider: OAuthProvider) {
        self.provider = provider
        _clientID = AppStorage(wrappedValue: "", provider.clientIDKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(provider.displayName) Client-ID")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(provider.id == "google" ? "1234-abc.apps.googleusercontent.com" : "32-stellige Client-ID", text: $clientID)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Color.danger)
            }
        }
        .padding(16)
        .glassCard(radius: 20)
    }

    private var hint: String? {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if provider.id == "google" && !value.hasSuffix(".apps.googleusercontent.com") {
            return "Eine Google-Client-ID endet auf „.apps.googleusercontent.com“."
        }
        if provider.id == "spotify" && value.count != 32 {
            return "Eine Spotify-Client-ID hat 32 Zeichen."
        }
        return nil
    }
}

/// Eingabefelder für die Discord-Webhook-URL (Pflicht) und einen optionalen Bot-Token.
struct DiscordFields: View {
    @Binding var webhookURL: String
    @Binding var botToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Webhook-URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Webhook-URL", text: $webhookURL, prompt: Text(verbatim: "https://discord.com/api/webhooks/…"))
                    .font(.callout.monospaced())
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Webhook-URL")
                webhookStatus
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bot-Token (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Nur zum Mitlesen des Kanals", text: $botToken)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Bot-Token, optional")
                Text(tokenHint ?? "Webhook-URL und Token bleiben verschlüsselt im Schlüsselbund deines iPhones.")
                    .font(.caption)
                    .foregroundStyle(tokenHint == nil ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.danger))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .glassCard(radius: 20)
    }

    @ViewBuilder
    private var webhookStatus: some View {
        let value = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            Text("In Discord: Server-Einstellungen › Integrationen › Webhooks › Webhook-URL kopieren.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if DiscordService.isValidWebhookURL(value) {
            Label("Webhook-URL erkannt", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.green)
        } else {
            Text("Eine Webhook-URL beginnt mit „https://discord.com/api/webhooks/“ und endet mit einem langen Schlüssel.")
                .font(.caption)
                .foregroundStyle(Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenHint: String? {
        let value = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let token = value.lowercased().hasPrefix("bot ") ? String(value.dropFirst(4)) : value
        return token.split(separator: ".").count == 3 ? nil : "Ein Bot-Token besteht aus drei durch Punkte getrennten Teilen."
    }
}
