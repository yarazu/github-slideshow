import SwiftUI
import UIKit
import UserNotifications

/// Navigationsziele im Tab „Flows“.
enum FlowRoute: Hashable {
    case edit(UUID)
    case create(Flow)
}

/// Tab „Flows“: eigene Routinen, Vorlagen und die Verbindung zu Kurzbefehlen.
struct FlowsView: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                intro
                if !hub.flows.hasNotificationPermission {
                    FlowsPermissionBanner()
                }
                if let next = nextUp {
                    FlowsNextUpCard(flow: next.flow, date: next.date)
                }
                flowsSection
                if !availableTemplates.isEmpty {
                    templatesSection
                }
                FlowsShortcutsCard()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle("Flows")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: FlowRoute.create(Flow.blank())) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Neuer Flow")
            }
        }
        .navigationDestination(for: FlowRoute.self) { route in
            FlowRouteDestination(route: route)
        }
        .refreshable { await hub.refreshAll() }
        .task { await hub.flows.refreshNotificationStatus() }
    }

    // MARK: Abschnitte

    private var intro: some View {
        Text("Flows erledigen Routinen für dich: Sie fassen deinen Tag zusammen, erinnern dich vor Terminen, pausieren die Musik und sagen deinem Team auf Discord Bescheid – automatisch oder mit einem Tipp.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var flowsSection: some View {
        let flows = hub.flows.flows
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Deine Flows", trailing: flows.isEmpty ? nil : "\(flows.filter { $0.isEnabled }.count) von \(flows.count) aktiv")
            if flows.isEmpty {
                FlowsEmptyState()
            } else {
                ForEach(Array(flows.enumerated()), id: \.element.id) { index, flow in
                    FlowsFlowCard(flow: flow, index: index, count: flows.count)
                }
            }
        }
        .animation(.snappy, value: flows)
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Vorlagen", trailing: "Ein Tipp zum Hinzufügen")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(availableTemplates) { item in
                        FlowsTemplateCard(key: item.key, template: item.flow)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
        }
    }

    // MARK: Daten

    private struct TemplateItem: Identifiable {
        let key: String
        let flow: Flow
        var id: String { key }
    }

    private var availableTemplates: [TemplateItem] {
        FlowTemplates.keys
            .filter { !hub.flows.hasTemplate($0) }
            .compactMap { key in FlowTemplates.make(key).map { TemplateItem(key: key, flow: $0) } }
    }

    /// Der Flow, der als Nächstes automatisch läuft.
    private var nextUp: (flow: Flow, date: Date)? {
        var best: (flow: Flow, date: Date)?
        for flow in hub.flows.flows where flow.isEnabled {
            guard let date = hub.flows.nextRuns[flow.id], date > .now else { continue }
            if best == nil || date < best!.date {
                best = (flow, date)
            }
        }
        return best
    }

    /// Konnektoren, die ein Flow nutzt – zuerst der des Auslösers, dann die der Schritte.
    static func connectors(in flow: Flow) -> [Connector] {
        var result: [Connector] = []
        if let required = flow.trigger.kind.requiredConnector {
            result.append(required)
        }
        for step in flow.steps {
            if let connector = step.action.connector, !result.contains(connector) {
                result.append(connector)
            }
        }
        return result
    }

    /// „Heute, 07:30 Uhr“
    static func runText(_ date: Date) -> String {
        "\(Fmt.dayTitle(date)), \(Fmt.time(date)) Uhr"
    }
}

/// Ziel einer `FlowRoute`.
private struct FlowRouteDestination: View {
    @Environment(HubStore.self) private var hub
    let route: FlowRoute

    var body: some View {
        switch route {
        case .edit(let id):
            if let flow = hub.flows.flow(id: id) {
                FlowEditorView(flowID: id, draft: flow)
            } else {
                ContentUnavailableView(
                    "Flow nicht gefunden",
                    systemImage: "bolt.slash",
                    description: Text("Dieser Flow wurde gelöscht.")
                )
                .background { HubBackground() }
            }
        case .create(let flow):
            FlowEditorView(flowID: nil, draft: flow)
        }
    }
}

// MARK: - Gemeinsame Bausteine

/// Farbige Kachel mit dem Symbol eines Flows.
struct FlowSymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.68)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.78))
            }
            .shadow(color: color.opacity(0.35), radius: size * 0.18, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// Symbol eines Schritts: Marken-Logo für Discord/Spotify, sonst ein SF Symbol.
struct FlowStepIcon: View {
    let action: FlowAction
    var size: CGFloat = 22
    var tint: Color = .white

    var body: some View {
        if let connector = action.connector {
            ConnectorIcon(connector: connector, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.opacity(0.22))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: action.symbol)
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)
        }
    }
}

/// Ordnet Chips in Zeilen an und bricht um, wenn eine Zeile voll ist.
struct WrappingChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = Self.measure(subview, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = proposal.width.map { min($0, widest) } ?? widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = Self.measure(subview, maxWidth: bounds.width)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// Ideale Größe eines Chips, höchstens so breit wie eine Zeile (lange Texte werden gekürzt).
    private static func measure(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let width: CGFloat? = maxWidth.isFinite ? maxWidth : nil
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// Kleiner Chip, der einen Schritt beschreibt, z. B. [Spotify-Logo] Pausieren.
private struct FlowsStepChip: View {
    let action: FlowAction
    let tint: Color

    private var title: String {
        switch action {
        case .notify: "Nachricht"
        case .discord: "Discord"
        case .spotifyPause: "Musik pausieren"
        case .spotifyPlay(_, let name): name ?? "Musik an"
        case .reminder(let minutes, _): "Erinnerung · \(minutes) Min."
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            FlowStepIcon(action: action, size: 20, tint: tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mitteilungen

private struct FlowsPermissionBanner: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.openURL) private var openURL
    @State private var isAsking = false

    private var isDenied: Bool { hub.flows.notificationStatus == .denied }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isDenied ? "bell.slash.fill" : "bell.badge.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(TintShapeStyle().opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(isDenied ? "Mitteilungen sind aus" : "Damit Flows dich erreichen")
                        .font(.headline)
                    Text(isDenied
                         ? "Erlaube Orbit in den iOS-Einstellungen Mitteilungen – sonst können Flows dich nicht zur richtigen Zeit erinnern."
                         : "Flows schicken dir Briefings und Erinnerungen als Mitteilung – genau zur richtigen Zeit, auch wenn Orbit geschlossen ist.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                if isDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    ask()
                }
            } label: {
                if isAsking {
                    ProgressView().tint(.black)
                } else {
                    Text(isDenied ? "In Einstellungen öffnen" : "Mitteilungen erlauben")
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(isAsking)
        }
        .padding(18)
        .glassCard()
    }

    private func ask() {
        isAsking = true
        Task {
            let granted = await hub.flows.requestNotificationPermission()
            isAsking = false
            hub.showToast(granted ? "Mitteilungen sind aktiv" : "Mitteilungen wurden nicht erlaubt")
        }
    }
}

// MARK: - Als Nächstes

private struct FlowsNextUpCard: View {
    let flow: Flow
    let date: Date

    var body: some View {
        NavigationLink(value: FlowRoute.edit(flow.id)) {
            HStack(spacing: 14) {
                FlowSymbolTile(symbol: flow.symbol, color: flow.color.color, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    CardLabel(title: "Als Nächstes", symbol: "clock.fill", tint: flow.color.color)
                    Text(flow.name)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    Text("\(FlowsView.runText(date)) · \(Fmt.relative(date))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard()
        .accessibilityHint("Öffnet den Flow")
    }
}

// MARK: - Flow-Karte

private struct FlowsFlowCard: View {
    @Environment(HubStore.self) private var hub
    let flow: Flow
    let index: Int
    let count: Int
    @State private var isRunning = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: FlowRoute.edit(flow.id)) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                        .padding(.trailing, 64)
                    if !flow.steps.isEmpty {
                        WrappingChipLayout(spacing: 8) {
                            ForEach(flow.steps) { step in
                                FlowsStepChip(action: step.action, tint: flow.color.color)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Flow bearbeiten")

            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .padding(18)
        .overlay(alignment: .topTrailing) { enabledToggle }
        .glassCard(radius: 26)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contextMenu { menu }
        .confirmationDialog("„\(flow.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                hub.flows.delete(flow.id)
                hub.showToast("Flow gelöscht")
            }
        } message: {
            Text("Der Flow und seine geplanten Mitteilungen werden entfernt.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            FlowSymbolTile(symbol: flow.symbol, color: flow.color.color, size: 48)
                .saturation(flow.isEnabled ? 1 : 0.2)
            VStack(alignment: .leading, spacing: 3) {
                Text(flow.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Label(flow.trigger.summary, systemImage: flow.trigger.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var enabledToggle: some View {
        Toggle(
            "\(flow.name) aktiv",
            isOn: Binding<Bool>(
                get: { flow.isEnabled },
                set: { value in
                    let id = flow.id
                    Task { await hub.flows.setEnabled(value, for: id) }
                }
            )
        )
        .labelsHidden()
        .padding(.top, 26)
        .padding(.trailing, 18)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let schedule = scheduleInfo
            Label(schedule.text, systemImage: schedule.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            runButton
        }
    }

    private var runButton: some View {
        Button(action: run) {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                }
                Text("Ausführen")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(.tint, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRunning || flow.steps.isEmpty)
        .opacity(flow.steps.isEmpty ? 0.45 : 1)
        .accessibilityLabel("\(flow.name) jetzt ausführen")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Jetzt ausführen", systemImage: "play.fill", action: run)
        Button("Duplizieren", systemImage: "plus.square.on.square", action: duplicate)
        if index > 0 {
            Button("Nach oben", systemImage: "arrow.up") {
                hub.flows.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
            }
        }
        if index < count - 1 {
            Button("Nach unten", systemImage: "arrow.down") {
                hub.flows.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
            }
        }
        Button("Löschen", systemImage: "trash", role: .destructive) {
            confirmDelete = true
        }
    }

    /// Was als Nächstes passiert – oder warum gerade nichts geplant ist.
    private var scheduleInfo: (symbol: String, text: String) {
        if !flow.isEnabled {
            return ("pause.circle", "Pausiert")
        }
        if let next = hub.flows.nextRuns[flow.id], next > .now {
            return ("clock", "Nächste Ausführung: \(FlowsView.runText(next))")
        }
        switch flow.trigger {
        case .manual:
            if let lastRun = flow.lastRun {
                return ("checkmark.circle", "Zuletzt \(Fmt.relative(lastRun))")
            }
            return ("hand.tap", "Bereit – ein Tipp genügt")
        case .daily:
            if hub.flows.hasNotificationPermission {
                return ("clock", "Wird geplant …")
            }
            return ("bell.slash", "Geplant, sobald Mitteilungen erlaubt sind")
        case .beforeEvent:
            if hub.isConnected(.calendar) {
                return ("calendar", "Kein passender Termin in den nächsten 7 Tagen")
            }
            return ("calendar.badge.exclamationmark", "Kalender ist nicht verbunden")
        case .newMail:
            if hub.isConnected(.gmail) {
                return ("arrow.clockwise", "Prüft neue Mails bei jeder Aktualisierung")
            }
            return ("envelope.badge", "Gmail ist nicht verbunden")
        }
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        let current = flow
        Task {
            let summary = await hub.flows.run(current)
            isRunning = false
            hub.showToast("\(current.name): \(summary)")
        }
    }

    private func duplicate() {
        var copy = flow
        copy.id = UUID()
        copy.name = "\(flow.name) (Kopie)"
        copy.isEnabled = false
        copy.lastRun = nil
        copy.templateKey = nil
        copy.steps = flow.steps.map { FlowStep(action: $0.action) }
        hub.flows.save(copy)
        hub.showToast("„\(copy.name)“ angelegt")
    }
}

// MARK: - Leerer Zustand

private struct FlowsEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.badge.automatic.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(TintShapeStyle().opacity(0.14), in: Circle())
            Text("Noch keine Flows")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Starte mit einer Vorlage unten oder baue deinen eigenen Flow – zum Beispiel ein Briefing am Morgen oder eine Discord-Nachricht vor jedem Meeting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: FlowRoute.create(Flow.blank())) {
                Label("Eigenen Flow erstellen", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCard()
    }
}

// MARK: - Vorlagen

private struct FlowsTemplateCard: View {
    @Environment(HubStore.self) private var hub
    let key: String
    let template: Flow
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                FlowSymbolTile(symbol: template.symbol, color: template.color.color, size: 46)
                Spacer(minLength: 8)
                HStack(spacing: -6) {
                    ForEach(FlowsView.connectors(in: template)) { connector in
                        ConnectorIcon(connector: connector, size: 26)
                            .overlay {
                                RoundedRectangle(cornerRadius: 26 * 0.3, style: .continuous)
                                    .stroke(Color.black.opacity(0.35), lineWidth: 2)
                            }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Text(FlowTemplates.pitch(key))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
            }
            Label(template.trigger.summary, systemImage: template.trigger.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(template.color.color)
                .lineLimit(1)
            Button(action: add) {
                Label("Hinzufügen", systemImage: "plus")
            }
            .buttonStyle(GlassButtonStyle(height: 44))
            .disabled(isAdding)
            .accessibilityLabel("Vorlage \(template.name) hinzufügen")
        }
        .padding(16)
        .frame(width: 252, alignment: .leading)
        .glassCard(radius: 24)
    }

    private func add() {
        isAdding = true
        Task {
            guard let flow = hub.flows.addTemplate(key) else {
                isAdding = false
                return
            }
            hub.showToast("„\(flow.name)“ hinzugefügt")
            // Eine Vorlage hinzuzufügen ist eine bewusste Aktion – dann darf Orbit nach Mitteilungen fragen.
            if flow.isEnabled && !hub.flows.hasNotificationPermission && hub.flows.notificationStatus == .notDetermined {
                _ = await hub.flows.requestNotificationPermission()
            }
            isAdding = false
        }
    }
}

// MARK: - Kurzbefehle

private struct FlowsShortcutsCard: View {
    @Environment(\.openURL) private var openURL

    private static let steps = [
        "Öffne die Kurzbefehle-App und tippe auf „Automation“.",
        "Wähle einen Auslöser – z. B. „Wecker gestoppt“, „Ankunft zuhause“ oder „Mit CarPlay verbunden“.",
        "Füge die Aktion „Flow ausführen“ von Orbit hinzu, wähle deinen Flow und stelle „Sofort ausführen“ ein."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0xF0508F), Color(hex: 0x5B5BF0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vollautomatisch mit Kurzbefehlen")
                        .font(.headline)
                    Text("Flows starten, ohne Orbit zu öffnen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(.tint, in: Circle())
                        Text(text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Label("Oder sag einfach: „Hey Siri, starte einen Flow in Orbit“.", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label("Kurzbefehle öffnen", systemImage: "arrow.up.right")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(18)
        .glassCard()
    }
}
