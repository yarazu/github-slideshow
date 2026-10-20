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
            "Nutzt die Kalender deines iPhones – auch Google-Kalender, die unter Einstellungen › Kalender › Accounts eingerichtet sind."
        case .gmail:
            "Du meldest dich direkt bei Google an. Der Hub erhält nur Lesezugriff, den du jederzeit wieder entziehen kannst."
        case .spotify:
            "Du meldest dich direkt bei Spotify an. Die Verbindung lässt sich jederzeit wieder trennen."
        }
    }

    private var primaryTitle: String {
        switch connector {
        case .calendar: hub.calendar.isDenied ? "In den Einstellungen erlauben" : "Zugriff erlauben"
        case .gmail: "Mit Google anmelden"
        case .spotify: "Mit Spotify anmelden"
        }
    }

    private var needsClientID: Bool {
        connector.provider != nil && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        errorText = "Ohne Kalenderzugriff kann der Hub keine Termine anzeigen."
                        return
                    }
                case .gmail:
                    try await hub.gmail.auth.signIn(using: webAuthenticationSession)
                    await hub.gmail.refresh()
                case .spotify:
                    try await hub.spotify.auth.signIn(using: webAuthenticationSession)
                    await hub.spotify.refreshAll()
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
