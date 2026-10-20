import SwiftUI

// MARK: - Discord

/// Discord: Nachrichten über den Webhook senden, den Kanal mitlesen (mit Bot) und der Verlauf.
struct DiscordDetailView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        let discord = hub.discord
        DetailScaffold(title: "Discord", refresh: { await discord.refresh() }) {
            if discord.isConnected {
                connectedContent(discord)
            } else {
                NotConnectedCard { hub.connectSheet = .discord }
            }
        }
        .task { await discord.refresh() }
    }

    @ViewBuilder
    private func connectedContent(_ discord: DiscordService) -> some View {
        ConnectionHeader(connector: .discord, detail: headerDetail(discord))

        composer(discord)

        if let sendError {
            NoticeBanner(text: sendError)
        } else if let error = discord.errorMessage {
            NoticeBanner(text: error)
        }

        quickMessages(discord)

        channelSection(discord)

        sentSection(discord)

        Button {
            openURL.first(of: discord.openURLs)
        } label: {
            Label("Discord öffnen", systemImage: "arrow.up.right")
        }
        .buttonStyle(GlassButtonStyle())

        DisconnectButton(connector: .discord) {
            discord.disconnect()
            hub.showToast("Discord wurde getrennt")
            dismiss()
        }

        Text("Den Webhook selbst kannst du in Discord unter Server-Einstellungen › Integrationen › Webhooks löschen.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private func headerDetail(_ discord: DiscordService) -> String {
        var parts = ["Postet als „Orbit“ in \(discord.channelLabel)"]
        if discord.canReadMessages { parts.append("Bot liest mit") }
        if let lastSync = discord.lastSync { parts.append("Stand \(Fmt.time(lastSync)) Uhr") }
        return parts.joined(separator: " · ")
    }

    // MARK: Composer

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func composer(_ discord: DiscordService) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardLabel(title: "Nachricht an \(discord.channelLabel)", symbol: "paperplane.fill", tint: Connector.discord.tint)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Schreib etwas …", text: $draft, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .frame(minHeight: 48)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    send(draft, fromComposer: true)
                } label: {
                    ZStack {
                        if isSending {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(.tint, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend || isSending ? 1 : 0.45)
                .accessibilityLabel("Nachricht senden")
            }
            Text(draft.count > 1800 ? "\(draft.count)/2000 Zeichen" : "Wird als „Orbit“ gepostet – genau wie die Nachrichten deiner Flows.")
                .font(.caption)
                .foregroundStyle(draft.count > 2000 ? AnyShapeStyle(Color.danger) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
        .padding(18)
        .glassCard()
    }

    private func quickMessages(_ discord: DiscordService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Schnellnachrichten", trailing: "Ein Tipp genügt")
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(DiscordService.quickMessages, id: \.self) { text in
                        QuickMessageChip(text: text, isDisabled: isSending) {
                            send(text, fromComposer: false)
                        }
                        .accessibilityHint("Sendet die Nachricht sofort an \(discord.channelLabel)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func send(_ text: String, fromComposer: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }
        sendError = nil
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await hub.discord.send(message)
                hub.activity.add(.discord, title: "Discord: \(hub.discord.channelLabel)", detail: message)
                if fromComposer {
                    draft = ""
                    composerFocused = false
                }
                hub.showToast("An \(hub.discord.channelLabel) gesendet")
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    // MARK: Kanal & Verlauf

    private func channelSection(_ discord: DiscordService) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Im Kanal", trailing: discord.isLoading ? "Lädt …" : discord.channelLabel)
            if discord.canReadMessages {
                VStack(spacing: 0) {
                    if discord.messages.isEmpty {
                        Text(discord.isLoading ? "Nachrichten werden geladen …" : "Noch keine Nachrichten im Kanal.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }
                    ForEach(discord.messages) { message in
                        DiscordMessageRow(message: message)
                        if message.id != discord.messages.last?.id {
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .glassCard(radius: 22)

                if !discord.messages.isEmpty && discord.messages.allSatisfy({ $0.content.isEmpty }) {
                    Text("Alle Nachrichten erscheinen ohne Text? Aktiviere im Developer Portal beim Bot den „Message Content Intent“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                BotHintCard()
            }
        }
    }

    private func sentSection(_ discord: DiscordService) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Gesendet", trailing: discord.sent.isEmpty ? nil : "\(discord.sent.count) Nachrichten")
            VStack(spacing: 0) {
                if discord.sent.isEmpty {
                    Text("Noch nichts gesendet. Schnellnachrichten und Flows erscheinen hier.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                }
                ForEach(discord.sent) { item in
                    SentMessageRow(item: item)
                    if item.id != discord.sent.last?.id {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 16)
            .glassCard(radius: 22)
        }
    }
}

// MARK: - Bausteine

private struct NotConnectedCard: View {
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ConnectionVisual(connector: .discord, connected: false)
            Text("Discord ist nicht verbunden")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Verbinde einen Webhook deines Servers, damit Orbit und deine Flows Nachrichten in deinen Kanal schicken können.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Discord verbinden", action: connect)
                .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCard()
    }
}

private struct QuickMessageChip: View {
    let text: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: "paperplane")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .glass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

/// Hinweis, wie Orbit mit einem Bot auch Kanal-Nachrichten lesen kann.
private struct BotHintCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Connector.discord.tint)
                    .frame(width: 32, height: 32)
                    .background(Connector.discord.tint.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kanal mitlesen")
                        .font(.subheadline.weight(.semibold))
                    Text("Ein Webhook kann nur senden. Mit einem eigenen Bot zeigt Orbit hier auch die letzten Nachrichten an: Bot im Developer Portal anlegen, „Message Content Intent“ aktivieren, auf den Server einladen und den Token hier einfügen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Link(destination: URL(string: "https://discord.com/developers/applications")!) {
                Label("Developer Portal öffnen", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
            }
            DiscordBotSettings()
        }
        .padding(18)
        .glassCard(radius: 22)
    }
}

/// Bot-Token hinzufügen oder entfernen. Der Token wird nie angezeigt, nur im Schlüsselbund gespeichert.
struct DiscordBotSettings: View {
    @Environment(HubStore.self) private var hub
    @State private var token = ""
    @State private var isWorking = false
    @State private var errorText: String?

    private var cleaned: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let discord = hub.discord
        VStack(alignment: .leading, spacing: 10) {
            if discord.hasBotToken {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Connector.discord.tint)
                    Text("Bot verbunden – Orbit liest \(discord.channelLabel) mit.")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                Button("Bot-Token entfernen", role: .destructive) { update(nil) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .disabled(isWorking)
            } else {
                Text("Bot-Token (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Token aus dem Developer Portal", text: $token)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    update(cleaned)
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Bot hinzufügen", systemImage: "plus")
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(cleaned.isEmpty || isWorking)
                .opacity(cleaned.isEmpty ? 0.5 : 1)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func update(_ value: String?) {
        errorText = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await hub.discord.updateBotToken(value)
                token = ""
                hub.showToast(value == nil ? "Bot-Token entfernt" : "Bot verbunden")
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

private struct DiscordMessageRow: View {
    let message: DiscordMessage

    private static let palette: [Color] = [
        Connector.discord.tint, Color(hex: 0x3BA55C), Color(hex: 0xFAA61A), Color(hex: 0xED4245), Color(hex: 0xEB459E)
    ]

    private var isOrbit: Bool { message.author == "Orbit" }

    private var initials: String {
        let letters = message.author.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Stabile Farbe je Name (nicht `hashValue`, das sich bei jedem Start ändert).
    private var avatarColor: Color {
        let sum = message.author.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isOrbit {
                HubMark(size: 40)
            } else {
                Text(initials)
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(avatarColor.opacity(0.4), in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.author)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(Fmt.mailDate(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.content.isEmpty ? "Anhang oder Einbettung" : message.content)
                    .font(.footnote)
                    .foregroundStyle(message.content.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SentMessageRow: View {
    let item: DiscordSentMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Connector.discord.tint)
                .frame(width: 34, height: 34)
                .background(Connector.discord.tint.opacity(0.18), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.content)
                    .font(.subheadline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("\(Fmt.mailDate(item.date)) · \(Fmt.relative(item.date))")
                    if let flowName = item.flowName {
                        Label(flowName, systemImage: "bolt.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
