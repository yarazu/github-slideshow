import SwiftUI

struct HubView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL
    @State private var showEventEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                StatusCard()
                if hub.calendar.isConnected {
                    NextEventCard()
                }
                if hub.spotify.isConnected {
                    NowPlayingCard()
                }
                if hub.gmail.isConnected {
                    NavigationLink(value: Route.connector(.gmail)) {
                        InboxCard()
                    }
                    .buttonStyle(.plain)
                }
                connectors
                quickActions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await hub.refreshAll() }
        .sheet(isPresented: $showEventEditor) {
            EventEditor(store: hub.calendar.store) { showEventEditor = false }
                .ignoresSafeArea()
        }
        .task {
            // Der aktuelle Spotify-Titel bleibt frisch, solange der Hub sichtbar ist.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await hub.spotify.refreshPlayback()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HubMark(size: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.greeting())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Dein Hub")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }
            Spacer()
            NavigationLink(value: Route.appearance) {
                Image(systemName: "paintbrush.pointed.fill")
            }
            .buttonStyle(CircleIconButtonStyle())
            .accessibilityLabel("Design & Hintergrund")
            NavigationLink(value: Route.setup) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(CircleIconButtonStyle())
            .accessibilityLabel("Konnektoren einrichten")
        }
    }

    private var connectors: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Konnektoren", trailing: "\(hub.connected.count) von \(Connector.allCases.count) verbunden")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Connector.allCases) { connector in
                    if hub.isConnected(connector) {
                        NavigationLink(value: Route.connector(connector)) {
                            ConnectorTile(connector: connector, connected: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            hub.connectSheet = connector
                        } label: {
                            ConnectorTile(connector: connector, connected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Schnellzugriff")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                QuickAction(title: "Termin anlegen", symbol: "calendar.badge.plus", tint: Connector.calendar.tint) {
                    if hub.calendar.isConnected { showEventEditor = true } else { hub.connectSheet = .calendar }
                }
                QuickAction(title: "E-Mail schreiben", symbol: "square.and.pencil", tint: Connector.gmail.tint) {
                    openURL.first(of: GmailService.composeURLs(to: []))
                }
                QuickAction(title: hub.spotify.isPlaying ? "Musik pausieren" : "Spotify öffnen", symbol: hub.spotify.isPlaying ? "pause.fill" : "music.note", tint: Connector.spotify.tint) {
                    if hub.spotify.isPlaying {
                        Task { await hub.spotify.togglePlay() }
                    } else {
                        openURL.first(of: SpotifyService.appURLs)
                    }
                }
                NavigationLink(value: Route.appearance) {
                    QuickActionLabel(title: "Hintergrund ändern", symbol: "photo.on.rectangle.angled", tint: Color(hex: 0xC9A7FF))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Karten

private struct StatusCard: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        let connected = hub.connected
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(connected.count)")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(connected.count == 1 ? "App mit deinem Hub verbunden" : "Apps mit deinem Hub verbunden")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: connected.isEmpty ? "Bereit" : "Alles synchron")
            }
            if connected.isEmpty {
                Text("Verbinde Kalender, Gmail oder Spotify, um loszulegen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    HStack(spacing: -8) {
                        ForEach(connected) { connector in
                            ConnectorIcon(connector: connector, size: 34)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 34 * 0.3, style: .continuous)
                                        .stroke(Color.black.opacity(0.35), lineWidth: 3)
                                }
                        }
                    }
                    Text("tauschen Daten über den Hub aus")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .animation(.snappy, value: connected.count)
    }
}

private struct NextEventCard: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: Route.connector(.calendar)) {
                HStack {
                    CardLabel(title: "Nächster Termin", symbol: "calendar", tint: Connector.calendar.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let event = hub.calendar.nextEvent {
                HStack(spacing: 14) {
                    DateTile(date: event.start, color: event.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(event.timeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(event.relativeText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    if !event.attendees.isEmpty {
                        Button {
                            openURL.first(of: GmailService.composeURLs(to: event.attendees, subject: event.title))
                        } label: {
                            Label("Mailen", systemImage: "envelope")
                        }
                        .accessibilityLabel("Teilnehmende mailen")
                    }
                    if let maps = event.mapsURL {
                        Button {
                            openURL(maps)
                        } label: {
                            Label("Route", systemImage: "map")
                        }
                    }
                    if let calendarURL = event.calendarAppURL {
                        Button {
                            openURL(calendarURL)
                        } label: {
                            Label("Öffnen", systemImage: "arrow.up.right")
                        }
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .labelStyle(CompactLabelStyle())
            } else {
                Text("Keine Termine in den nächsten 7 Tagen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassCard()
    }
}

private struct NowPlayingCard: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL

    var body: some View {
        let spotify = hub.spotify
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: Route.connector(.spotify)) {
                HStack {
                    CardLabel(title: spotify.isPlaying ? "Läuft gerade" : "Spotify", symbol: "music.note", tint: Connector.spotify.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let item = spotify.playback?.item {
                HStack(spacing: 14) {
                    Artwork(url: item.artworkURL, size: 60, radius: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let device = spotify.playback?.device?.name {
                            Label(device, systemImage: "hifispeaker")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                PlaybackProgress()
                PlayerControls(compact: true)
            } else {
                HStack {
                    Text("Gerade läuft nichts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Spotify öffnen") { openURL.first(of: SpotifyService.appURLs) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            if let notice = spotify.notice {
                Text(notice.text)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
            }
        }
        .padding(18)
        .glassCard()
    }
}

private struct InboxCard: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        let gmail = hub.gmail
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardLabel(title: "Posteingang", symbol: "envelope.fill", tint: Connector.gmail.tint)
                Spacer()
                if let unread = gmail.unreadCount {
                    Text(unread == 1 ? "1 ungelesen" : "\(unread) ungelesen")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Connector.gmail.tint.opacity(0.25), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            if gmail.messages.isEmpty {
                Text(gmail.isLoading ? "Lädt …" : (gmail.errorMessage ?? "Keine Nachrichten im Posteingang."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(gmail.messages.prefix(3)) { message in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(message.isUnread ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.clear))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(message.sender)
                                    .font(.subheadline.weight(message.isUnread ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer()
                                Text(Fmt.mailDate(message.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(message.subject)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(18)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: - Bausteine

struct DateTile: View {
    let date: Date
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(Fmt.weekdayShort(date))
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(Fmt.dayNumber(date))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
        }
        .frame(width: 56, height: 56)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ConnectorTile: View {
    let connector: Connector
    let connected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ConnectorIcon(connector: connector, size: 52)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(connected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.3)))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 2.5))
                        .offset(x: 4, y: -4)
                }
            VStack(spacing: 2) {
                Text(connector.shortName)
                    .font(.subheadline.weight(.semibold))
                Text(connected ? "Verbunden" : "Verbinden")
                    .font(.caption)
                    .foregroundStyle(connected ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(TintShapeStyle()))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassCard(radius: 24)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connector.name), \(connected ? "verbunden" : "nicht verbunden")")
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuickActionLabel(title: title, symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct QuickActionLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .glassCard(radius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Spotify-Steuerung

struct PlaybackProgress: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * hub.spotify.progress(at: context.date))
                }
            }
            .frame(height: 4)
        }
        .accessibilityHidden(true)
    }
}

struct PlayerControls: View {
    @Environment(HubStore.self) private var hub
    var compact = false

    var body: some View {
        let spotify = hub.spotify
        HStack(spacing: compact ? 28 : 40) {
            Button {
                Task { await spotify.skip(forward: false) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Vorheriger Titel")

            Button {
                Task { await spotify.togglePlay() }
            } label: {
                Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 20 : 26, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: compact ? 52 : 68, height: compact ? 52 : 68)
                    .background(.tint, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(spotify.isPlaying ? "Pausieren" : "Abspielen")

            Button {
                Task { await spotify.skip(forward: true) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Nächster Titel")
        }
        .font(.system(size: compact ? 18 : 22, weight: .semibold))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: spotify.isPlaying)
    }
}
