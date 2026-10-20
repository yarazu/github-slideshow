import SwiftUI

/// Startseite von Orbit: Tagesüberblick, Karten der verbundenen Apps, Flows und Schnellzugriff.
struct HubView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL
    @State private var showEventEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HomeHeader()
                HomeTodayStrip()
                cards
                HomeFlowsSection()
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
            // Der aktuelle Spotify-Titel bleibt frisch, solange die Startseite sichtbar ist.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if hub.spotify.isConnected {
                    await hub.spotify.refreshPlayback()
                }
            }
        }
    }

    /// Karten der verbundenen Apps – oder ein Einstieg, solange noch nichts verbunden ist.
    @ViewBuilder
    private var cards: some View {
        if hub.connected.isEmpty {
            HomeGetStartedCard()
        }
        if hub.calendar.isConnected {
            HomeNextEventCard()
        }
        if hub.spotify.isConnected {
            HomeNowPlayingCard()
        }
        if hub.gmail.isConnected {
            NavigationLink(value: Route.connector(.gmail)) {
                HomeInboxCard()
            }
            .buttonStyle(.plain)
        }
        if hub.discord.isConnected {
            HomeDiscordCard()
        }
    }

    private var connectors: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Konnektoren", trailing: "\(hub.connected.count) von \(Connector.allCases.count) mit Orbit verbunden")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Connector.allCases) { connector in
                    if hub.isConnected(connector) {
                        NavigationLink(value: Route.connector(connector)) {
                            HomeConnectorTile(connector: connector, connected: true, detail: detail(for: connector))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            hub.connectSheet = connector
                        } label: {
                            HomeConnectorTile(connector: connector, connected: false, detail: connector.tagline)
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
                HomeQuickAction(title: "Termin anlegen", symbol: "calendar.badge.plus", tint: Connector.calendar.tint) {
                    if hub.calendar.isConnected { showEventEditor = true } else { hub.connectSheet = .calendar }
                }
                HomeQuickAction(title: "E-Mail schreiben", symbol: "square.and.pencil", tint: Connector.gmail.tint) {
                    openURL.first(of: GmailService.composeURLs(to: []))
                }
                HomeQuickAction(title: hub.spotify.isPlaying ? "Musik pausieren" : "Spotify öffnen", symbol: hub.spotify.isPlaying ? "pause.fill" : "music.note", tint: Connector.spotify.tint) {
                    if hub.spotify.isPlaying {
                        Task { await hub.spotify.togglePlay() }
                    } else {
                        openURL.first(of: SpotifyService.appURLs)
                    }
                }
                HomeQuickAction(title: "Discord öffnen", symbol: "bubble.left.and.bubble.right.fill", tint: Connector.discord.tint) {
                    openURL.first(of: DiscordService.appURLs)
                }
            }
        }
    }

    /// Kurzer Status unter dem Namen einer verbundenen Kachel.
    private func detail(for connector: Connector) -> String {
        switch connector {
        case .calendar:
            let count = hub.calendar.events.count
            return count == 1 ? "1 Termin in 7 Tagen" : "\(count) Termine in 7 Tagen"
        case .gmail:
            guard let unread = hub.gmail.unreadCount else { return "Verbunden" }
            return unread == 0 ? "Alles gelesen" : "\(unread) ungelesen"
        case .spotify:
            if hub.spotify.isPlaying, let item = hub.spotify.playback?.item { return item.name }
            return "Bereit"
        case .discord:
            return hub.discord.channelLabel
        }
    }
}

// MARK: - Kopf & Tagesleiste

private struct HomeHeader: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                HubMark(size: 38)
                Text("Orbit")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink(value: Route.appearance) {
                    Image(systemName: "paintbrush.pointed.fill")
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("Design & Hintergrund")
                Button {
                    hub.selectedTab = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("Einstellungen")
            }

            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.longDate(context.date).uppercased())
                        .font(.footnote.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Text(Fmt.greeting(for: context.date))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(summary)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Ein ruhiger Satz zum Tag: der nächste Termin oder die Tagline.
    private var summary: String {
        guard hub.calendar.isConnected, let event = hub.calendar.nextEvent else { return "Dein Alltag, verbunden." }
        if event.isOngoing { return "Gerade: \(event.title)" }
        guard Calendar.current.isDateInToday(event.start) else { return "Heute ist nichts mehr geplant." }
        return event.isAllDay ? "Heute: \(event.title)" : "Als Nächstes: \(event.title) um \(Fmt.time(event.start))"
    }
}

private struct HomeTodayStrip: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        HStack(spacing: 10) {
            metric(for: .calendar, value: eventsToday.map { String($0) }, title: "Termine heute", symbol: "calendar")
            metric(for: .gmail, value: unread.map { String($0) }, title: "Ungelesen", symbol: "envelope.fill")
            Button {
                hub.selectedTab = .flows
            } label: {
                HomeMetricLabel(value: "\(activeFlows)", title: activeFlows == 1 ? "Flow aktiv" : "Flows aktiv", symbol: "bolt.fill", tint: Color.orbitLime)
            }
            .buttonStyle(.plain)
        }
    }

    private var eventsToday: Int? {
        guard hub.calendar.isConnected else { return nil }
        let calendar = Calendar.current
        return hub.calendar.events.filter { calendar.isDateInToday($0.start) || $0.isOngoing }.count
    }

    private var unread: Int? {
        guard hub.gmail.isConnected else { return nil }
        return hub.gmail.unreadCount ?? hub.gmail.messages.filter { $0.isUnread }.count
    }

    private var activeFlows: Int {
        hub.flows.flows.filter { $0.isEnabled }.count
    }

    @ViewBuilder
    private func metric(for connector: Connector, value: String?, title: String, symbol: String) -> some View {
        if hub.isConnected(connector) {
            NavigationLink(value: Route.connector(connector)) {
                HomeMetricLabel(value: value ?? "–", title: title, symbol: symbol, tint: connector.tint)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                hub.connectSheet = connector
            } label: {
                HomeMetricLabel(value: "–", title: title, symbol: symbol, tint: connector.tint)
            }
            .buttonStyle(.plain)
            .accessibilityHint("\(connector.name) verbinden")
        }
    }
}

private struct HomeMetricLabel: View {
    let value: String
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value == "–" ? "nicht verbunden" : value)")
    }
}

// MARK: - Karten

/// Kopfzeile einer Karte: Marken-Logo, Titel in Kapitälchen und optionaler Zusatz.
private struct HomeCardHeader: View {
    let connector: Connector
    let title: String
    var detail: String? = nil
    var showsChevron = true

    var body: some View {
        HStack(spacing: 10) {
            ConnectorIcon(connector: connector, size: 26)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }
}

private struct HomeGetStartedCard: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: -10) {
                ForEach(Connector.allCases) { connector in
                    ConnectorIcon(connector: connector, size: 46)
                        .overlay {
                            RoundedRectangle(cornerRadius: 46 * 0.28, style: .continuous)
                                .stroke(Color.black.opacity(0.35), lineWidth: 3)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Verbinde deine Apps")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Kalender, Gmail, Spotify und Discord – Orbit bringt alles auf einen Blick zusammen und lässt Flows deine Routinen erledigen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Kalender verbinden") {
                hub.connectSheet = .calendar
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct HomeNextEventCard: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: Route.connector(.calendar)) {
                HomeCardHeader(connector: .calendar, title: "Nächster Termin")
            }
            .buttonStyle(.plain)

            if let event = hub.calendar.nextEvent {
                HStack(spacing: 14) {
                    DateTile(date: event.start, color: event.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
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
                if let location = event.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                actions(for: event)
            } else {
                Text("Keine Termine in den nächsten 7 Tagen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassCard()
    }

    @ViewBuilder
    private func actions(for event: CalendarEvent) -> some View {
        let mapsURL = event.mapsURL
        let calendarURL = event.calendarAppURL
        if !event.attendees.isEmpty || mapsURL != nil || calendarURL != nil {
            HStack(spacing: 10) {
                if !event.attendees.isEmpty {
                    Button {
                        openURL.first(of: GmailService.composeURLs(to: event.attendees, subject: event.title))
                    } label: {
                        Label("Mailen", systemImage: "envelope")
                    }
                    .accessibilityLabel("Teilnehmende mailen")
                }
                if let mapsURL {
                    Button {
                        openURL(mapsURL)
                    } label: {
                        Label("Route", systemImage: "map")
                    }
                }
                if let calendarURL {
                    Button {
                        openURL(calendarURL)
                    } label: {
                        Label("Öffnen", systemImage: "arrow.up.right")
                    }
                }
            }
            .buttonStyle(GlassButtonStyle(height: 44))
            .labelStyle(CompactLabelStyle())
        }
    }
}

private struct HomeNowPlayingCard: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL

    var body: some View {
        let spotify = hub.spotify
        let item = spotify.playback?.item
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: Route.connector(.spotify)) {
                HomeCardHeader(connector: .spotify, title: spotify.isPlaying ? "Läuft gerade" : "Spotify")
            }
            .buttonStyle(.plain)

            if let item {
                HStack(spacing: 14) {
                    Artwork(url: item.artworkURL, size: 64, radius: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(.headline, design: .rounded))
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
                    Button {
                        openURL.first(of: SpotifyService.appURLs)
                    } label: {
                        Text("Spotify öffnen")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            if let notice = spotify.notice {
                Text(notice.text)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
            }
        }
        .padding(20)
        .background {
            // Das Albumcover schimmert leicht durch die Karte.
            if let url = item?.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 40)
                            .opacity(0.3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .glassCard()
    }
}

private struct HomeInboxCard: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        let gmail = hub.gmail
        VStack(alignment: .leading, spacing: 14) {
            HomeCardHeader(connector: .gmail, title: "Posteingang", detail: unreadText(gmail.unreadCount))
            if gmail.messages.isEmpty {
                Text(gmail.isLoading ? "Lädt …" : (gmail.errorMessage ?? "Keine Nachrichten im Posteingang."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(gmail.messages.prefix(3)) { message in
                    HStack(spacing: 12) {
                        Text(message.initials)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(message.isUnread ? Color.black : Color.white)
                            .frame(width: 34, height: 34)
                            .background(message.isUnread ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.14)), in: Circle())
                            .accessibilityHidden(true)
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
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(20)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func unreadText(_ unread: Int?) -> String? {
        guard let unread else { return nil }
        return unread == 1 ? "1 ungelesen" : "\(unread) ungelesen"
    }
}

/// Discord: Kanal, letzte Nachrichten und Schnellnachrichten mit einem Tipp.
private struct HomeDiscordCard: View {
    @Environment(HubStore.self) private var hub
    @State private var sending: String?
    @State private var errorText: String?

    private static let quickMessages = ["Bin gleich da", "Bin unterwegs", "Komme etwas später", "Bin im Meeting"]

    var body: some View {
        let discord = hub.discord
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: Route.connector(.discord)) {
                HomeCardHeader(connector: .discord, title: "Discord", detail: discord.channelLabel)
            }
            .buttonStyle(.plain)

            latest(discord)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.quickMessages, id: \.self) { text in
                        Button {
                            send(text)
                        } label: {
                            chip(text)
                        }
                        .buttonStyle(.plain)
                        .disabled(sending != nil)
                        .accessibilityLabel("„\(text)“ an \(discord.channelLabel) senden")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .padding(.horizontal, -20)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .glassCard()
    }

    @ViewBuilder
    private func latest(_ discord: DiscordService) -> some View {
        if let message = discord.messages.first {
            HomeDiscordLine(author: message.author, content: message.content, date: message.date)
        } else if let sent = discord.sent.first {
            HomeDiscordLine(author: sent.flowName.map { "Orbit · \($0)" } ?? "Orbit", content: sent.content, date: sent.date)
        } else {
            Text("Noch keine Nachrichten. Tippe auf eine Schnellnachricht, um deinem Team Bescheid zu geben.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 7) {
            if sending == text {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Connector.discord.tint)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Connector.discord.tint.opacity(0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(Connector.discord.tint.opacity(0.35), lineWidth: 1))
        .contentShape(Capsule())
    }

    private func send(_ text: String) {
        guard sending == nil else { return }
        sending = text
        errorText = nil
        Task {
            do {
                try await hub.discord.send(text)
                hub.activity.add(.discord, title: "Discord: \(hub.discord.channelLabel)", detail: text)
                hub.showToast("An \(hub.discord.channelLabel) gesendet")
            } catch {
                errorText = error.localizedDescription
            }
            sending = nil
        }
    }
}

private struct HomeDiscordLine: View {
    let author: String
    let content: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(author.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Connector.discord.tint.opacity(0.55), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(author)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Fmt.relative(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flows

/// „Deine Flows“: manuelle Flows mit einem Tipp starten, dazu der nächste automatische Lauf.
private struct HomeFlowsSection: View {
    @Environment(HubStore.self) private var hub
    @State private var runningID: UUID?

    var body: some View {
        let flows = hub.flows.flows
        let manual = flows.filter { $0.trigger.kind == .manual }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Deine Flows")
                Button {
                    hub.selectedTab = .flows
                } label: {
                    Text("Alle")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Alle Flows anzeigen")
            }

            if let next = nextAutomatic(flows) {
                HomeNextFlowRow(flow: next.flow, date: next.date)
            }

            if manual.isEmpty {
                emptyHint
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(manual) { flow in
                            Button {
                                run(flow)
                            } label: {
                                HomeFlowChip(flow: flow, isRunning: runningID == flow.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(runningID != nil)
                            .accessibilityLabel("\(flow.name) ausführen")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private var emptyHint: some View {
        Button {
            hub.selectedTab = .flows
        } label: {
            HStack(spacing: 14) {
                HomeFlowGlyph(symbol: "bolt.fill", color: Color.orbitLime, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routinen mit einem Tipp")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text("Lege einen Flow mit manuellem Auslöser an – er erscheint dann hier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .glassCard(radius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func nextAutomatic(_ flows: [Flow]) -> (flow: Flow, date: Date)? {
        var best: (flow: Flow, date: Date)?
        for flow in flows where flow.isEnabled {
            guard let date = hub.flows.nextRuns[flow.id], date > .now else { continue }
            if best == nil || date < best!.date {
                best = (flow, date)
            }
        }
        return best
    }

    private func run(_ flow: Flow) {
        guard runningID == nil else { return }
        runningID = flow.id
        Task {
            let summary = await hub.flows.run(id: flow.id)
            runningID = nil
            hub.showToast("\(flow.name): \(summary)")
        }
    }
}

private struct HomeNextFlowRow: View {
    let flow: Flow
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            HomeFlowGlyph(symbol: flow.symbol, color: flow.color.color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Als Nächstes automatisch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(flow.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(Fmt.dayTitle(date)), \(Fmt.time(date))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(radius: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct HomeFlowChip: View {
    let flow: Flow
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HomeFlowGlyph(symbol: flow.symbol, color: flow.color.color, size: 42)
                Spacer()
                ZStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 32, height: 32)
                .background(isRunning ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(TintShapeStyle()), in: Circle())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(flow.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(Array(flow.steps.prefix(4))) { step in
                        HomeStepIcon(action: step.action)
                    }
                    if flow.steps.count > 4 {
                        Text("+\(flow.steps.count - 4)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 156, alignment: .leading)
        .glassCard(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Farbige Kachel mit dem Symbol eines Flows.
private struct HomeFlowGlyph: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.78))
            }
            .accessibilityHidden(true)
    }
}

/// Kleines Symbol eines Schritts: Marken-Logo für Discord/Spotify, sonst ein SF Symbol.
private struct HomeStepIcon: View {
    let action: FlowAction

    var body: some View {
        if let connector = action.connector {
            ConnectorIcon(connector: connector, size: 20)
        } else {
            Image(systemName: action.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
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

private struct HomeConnectorTile: View {
    let connector: Connector
    let connected: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                ConnectorIcon(connector: connector, size: 46)
                Spacer()
                if connected {
                    Circle()
                        .fill(.tint)
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(.tint, in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.shortName)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Text(connected ? detail : "Verbinden")
                    .font(.caption)
                    .foregroundStyle(connected ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(TintShapeStyle()))
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 24)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connector.name), \(connected ? "verbunden, \(detail)" : "nicht verbunden")")
    }
}

private struct HomeQuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .buttonStyle(.plain)
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

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        let spotify = hub.spotify
        HStack(spacing: compact ? 28 : 40) {
            Button {
                Task { await spotify.skip(forward: false) }
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
