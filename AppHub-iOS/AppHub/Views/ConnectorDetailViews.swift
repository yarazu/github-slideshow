import SwiftUI

/// Kopf jeder Detailseite: Hub ←→ Konnektor mit Status.
private struct ConnectionHeader: View {
    let connector: Connector
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            ConnectionVisual(connector: connector, connected: true)
            StatusPill(text: "Verbunden")
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCard()
    }
}

private struct DetailScaffold<Content: View>: View {
    let title: String
    let refresh: () async -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
    }
}

// MARK: - Kalender

struct CalendarDetailView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showEditor = false

    private struct Day: Identifiable {
        let id: Date
        let events: [CalendarEvent]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: hub.calendar.events) { calendar.startOfDay(for: max($0.start, .now)) }
        return grouped.keys.sorted().map { Day(id: $0, events: grouped[$0] ?? []) }
    }

    var body: some View {
        let service = hub.calendar
        DetailScaffold(title: "Kalender", refresh: { @MainActor in service.reload() }) {
            ConnectionHeader(
                connector: .calendar,
                detail: service.lastSync.map { "Zuletzt synchronisiert: \(Fmt.time($0)) Uhr" } ?? "Über die Kalender deines iPhones"
            )

            Button {
                showEditor = true
            } label: {
                Label("Neuer Termin", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Nächste 7 Tage", trailing: "\(service.events.count) Termine")
                if days.isEmpty {
                    Text("Keine Termine – genieß die freie Zeit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .glassCard(radius: 22)
                }
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Fmt.dayTitle(day.id))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(day.events) { event in
                                EventRow(event: event)
                                if event.id != day.events.last?.id {
                                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 30)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .glassCard(radius: 22)
                    }
                }
            }

            if !service.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Angezeigte Kalender")
                    VStack(spacing: 0) {
                        ForEach(service.calendars) { info in
                            Toggle(isOn: Binding(
                                get: { service.isVisible(info.id) },
                                set: { service.setVisible($0, calendarID: info.id) }
                            )) {
                                HStack(spacing: 12) {
                                    Circle().fill(info.color).frame(width: 12, height: 12)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(info.title).font(.subheadline.weight(.medium))
                                        Text(info.account).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .glassCard(radius: 22)
                }
            }

            DisconnectButton(connector: .calendar) {
                service.disconnect()
                hub.showToast("Kalender wurde getrennt")
                dismiss()
            }
            Text("Den Systemzugriff kannst du zusätzlich in den iOS-Einstellungen › App-Hub › Kalender entziehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .sheet(isPresented: $showEditor) {
            EventEditor(store: service.store) { showEditor = false }
                .ignoresSafeArea()
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            if let url = event.calendarAppURL {
                Button("Im Kalender öffnen", systemImage: "calendar") { openURL(url) }
            }
            if !event.attendees.isEmpty {
                Button("Teilnehmende mailen", systemImage: "envelope") {
                    openURL.first(of: GmailService.composeURLs(to: event.attendees, subject: event.title))
                }
            }
            if let maps = event.mapsURL {
                Button("Route planen", systemImage: "map") { openURL(maps) }
            }
        } label: {
            HStack(spacing: 14) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 4, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(event.timeText)
                        if let location = event.location {
                            Text("·")
                            Text(location).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if event.isOngoing {
                    Text("Jetzt")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint, in: Capsule())
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gmail

struct GmailDetailView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let gmail = hub.gmail
        DetailScaffold(title: "Gmail", refresh: { await gmail.refresh() }) {
            ConnectionHeader(connector: .gmail, detail: gmail.email ?? "Bei Google angemeldet")

            HStack(spacing: 12) {
                StatTile(value: gmail.unreadCount.map { String($0) } ?? "–", label: "Ungelesen")
                StatTile(value: "\(gmail.messages.count)", label: "Neueste im Posteingang")
            }

            HStack(spacing: 12) {
                Button {
                    openURL.first(of: GmailService.composeURLs(to: []))
                } label: {
                    Label("Neue E-Mail", systemImage: "square.and.pencil")
                }
                .buttonStyle(AccentButtonStyle())
                Button {
                    openURL.first(of: GmailService.appURLs)
                } label: {
                    Label("Gmail öffnen", systemImage: "arrow.up.right")
                }
                .buttonStyle(GlassButtonStyle(height: 54))
            }

            if let error = gmail.errorMessage {
                NoticeBanner(text: error)
            }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Posteingang", trailing: gmail.isLoading ? "Lädt …" : nil)
                VStack(spacing: 0) {
                    if gmail.messages.isEmpty {
                        Text(gmail.isLoading ? "Nachrichten werden geladen …" : "Keine Nachrichten.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }
                    ForEach(gmail.messages) { message in
                        Button {
                            openURL.first(of: [message.webURL].compactMap { $0 } + GmailService.appURLs)
                        } label: {
                            MessageRow(message: message)
                        }
                        .buttonStyle(.plain)
                        if message.id != gmail.messages.last?.id {
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 54)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .glassCard(radius: 22)
            }

            DisconnectButton(connector: .gmail) {
                gmail.disconnect()
                hub.showToast("Gmail wurde getrennt")
                dismiss()
            }
        }
        .task { await gmail.refresh() }
    }
}

private struct MessageRow: View {
    let message: GmailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message.initials)
                .font(.caption.weight(.bold))
                .frame(width: 40, height: 40)
                .background(Connector.gmail.tint.opacity(message.isUnread ? 0.45 : 0.2), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender)
                        .font(.subheadline.weight(message.isUnread ? .bold : .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(Fmt.mailDate(message.date))
                        .font(.caption)
                        .foregroundStyle(message.isUnread ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
                Text(message.subject)
                    .font(.footnote.weight(message.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Text(message.snippet)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(radius: 22)
    }
}

// MARK: - Spotify

struct SpotifyDetailView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let spotify = hub.spotify
        DetailScaffold(title: "Spotify", refresh: { await spotify.refreshAll() }) {
            nowPlaying(spotify)

            if let notice = spotify.notice {
                NoticeBanner(
                    text: notice.text,
                    actionTitle: notice.suggestsOpeningApp ? "Spotify öffnen" : nil,
                    action: { openURL.first(of: SpotifyService.appURLs) }
                )
            }

            if !spotify.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Deine Playlists")
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(spotify.playlists) { playlist in
                                Button {
                                    Task {
                                        let started = await spotify.play(playlist)
                                        if !started { openURL.first(of: playlist.openURLs) }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Artwork(url: playlist.artworkURL, size: 120, radius: 18)
                                        Text(playlist.name)
                                            .font(.footnote.weight(.semibold))
                                            .lineLimit(1)
                                            .frame(width: 120, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Playlist \(playlist.name) abspielen")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            }

            if !spotify.recent.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Zuletzt gehört")
                    VStack(spacing: 0) {
                        ForEach(spotify.recent) { entry in
                            Button {
                                openURL.first(of: entry.item.openURLs)
                            } label: {
                                HStack(spacing: 12) {
                                    Artwork(url: entry.item.artworkURL, size: 44, radius: 10)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.item.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(entry.item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .glassCard(radius: 22)
                }
            }

            Button {
                openURL.first(of: SpotifyService.appURLs)
            } label: {
                Label("Spotify öffnen", systemImage: "arrow.up.right")
            }
            .buttonStyle(GlassButtonStyle())

            DisconnectButton(connector: .spotify) {
                spotify.disconnect()
                hub.showToast("Spotify wurde getrennt")
                dismiss()
            }
        }
        .task {
            await spotify.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await spotify.refreshPlayback()
            }
        }
    }

    @ViewBuilder
    private func nowPlaying(_ spotify: SpotifyService) -> some View {
        VStack(spacing: 18) {
            if let item = spotify.playback?.item {
                Artwork(url: item.artworkURL, size: 240, radius: 26)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                VStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let device = spotify.playback?.device?.name {
                        Label("Wird auf \(device) abgespielt", systemImage: "hifispeaker")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .padding(.top, 4)
                    }
                }
                PlaybackProgress()
                PlayerControls()
            } else {
                ConnectionVisual(connector: .spotify, connected: true)
                Text(spotify.displayName.map { "Hallo \($0)! Gerade läuft nichts." } ?? "Gerade läuft nichts.")
                    .font(.headline)
                Text("Starte Musik in Spotify – der Hub zeigt sie hier an und du kannst sie steuern.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PlayerControls()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCard()
    }
}
