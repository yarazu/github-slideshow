import SwiftUI
import UserNotifications

/// Felder des Editors, die den Tastaturfokus bekommen können.
private enum FlowEditorField: Hashable {
    case name
    case sender
    case notifyTitle(UUID)
    case notifyBody(UUID)
    case discordText(UUID)
    case reminderText(UUID)

    /// Felder, in die Platzhalter eingefügt werden können.
    var acceptsTokens: Bool {
        switch self {
        case .name, .sender: false
        case .notifyTitle, .notifyBody, .discordText, .reminderText: true
        }
    }

    var stepID: UUID? {
        switch self {
        case .name, .sender:
            return nil
        case .notifyTitle(let id), .notifyBody(let id), .discordText(let id), .reminderText(let id):
            return id
        }
    }

    var label: String {
        switch self {
        case .name: "Name"
        case .sender: "Absender"
        case .notifyTitle: "Titel"
        case .notifyBody: "Text"
        case .discordText: "Discord-Text"
        case .reminderText: "Erinnerung"
        }
    }
}

/// So sähe die erste Nachricht des Flows aus.
private struct FlowPreviewData {
    let connector: Connector?
    let source: String
    let title: String
    let body: String
}

/// Bearbeitet eine lokale Kopie eines Flows und schreibt sie erst beim Sichern zurück.
struct FlowEditorView: View {
    @Environment(HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss
    /// `nil` = neuer Flow.
    let flowID: UUID?
    @State private var draft: Flow
    @State private var lastField: FlowEditorField?
    @State private var isTesting = false
    @State private var confirmDelete = false
    @FocusState private var focus: FlowEditorField?

    init(flowID: UUID?, draft: Flow) {
        self.flowID = flowID
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                identityCard
                styleCard
                triggerSection
                stepsSection
                if hasTextFields {
                    tokensSection
                }
                if let preview {
                    previewSection(preview)
                }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { HubBackground() }
        .navigationTitle(flowID == nil ? "Neuer Flow" : "Flow bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: focus) { _, field in
            if let field, field.acceptsTokens {
                lastField = field
            }
        }
        .confirmationDialog("„\(draft.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Flow löschen", role: .destructive, action: deleteFlow)
        } message: {
            Text("Der Flow und seine geplanten Mitteilungen werden entfernt.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Sichern", action: save)
                .fontWeight(.semibold)
                .disabled(!canSave)
        }
        ToolbarItemGroup(placement: .keyboard) {
            if focus?.acceptsTokens == true {
                tokenMenu
            }
            Spacer()
            Button("Fertig") { focus = nil }
                .fontWeight(.semibold)
        }
    }

    private var tokenMenu: some View {
        Menu {
            ForEach(FlowToken.available(for: draft.trigger.kind)) { token in
                Button(token.label) { insert(token) }
            }
        } label: {
            Label("Platzhalter", systemImage: "curlybraces")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Platzhalter einfügen")
    }

    // MARK: Name, Symbol, Farbe

    private var identityCard: some View {
        VStack(spacing: 16) {
            FlowSymbolTile(symbol: draft.symbol, color: draft.color.color, size: 76)
            VStack(spacing: 6) {
                TextField("Name des Flows", text: $draft.name)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                Label(draft.trigger.summary, systemImage: draft.trigger.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Toggle(isOn: $draft.isEnabled) {
                Label("Flow ist aktiv", systemImage: "power")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard()
        .animation(.snappy, value: draft.color)
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardLabel(title: "Symbol", symbol: "square.grid.2x2.fill", tint: draft.color.color)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(Flow.symbols, id: \.self) { symbol in
                    FlowSymbolChoice(symbol: symbol, color: draft.color.color, isSelected: draft.symbol == symbol) {
                        draft.symbol = symbol
                    }
                }
            }
            CardLabel(title: "Farbe", symbol: "paintpalette.fill", tint: draft.color.color)
            HStack(spacing: 0) {
                ForEach(FlowColor.allCases) { color in
                    FlowColorChoice(color: color, isSelected: draft.color == color) {
                        draft.color = color
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .glassCard()
    }

    // MARK: Auslöser

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Auslöser", trailing: draft.trigger.kind.title)
            VStack(alignment: .leading, spacing: 18) {
                FlowTriggerKindPicker(trigger: $draft.trigger)
                triggerFields
                if draft.hasActionSteps && (draft.trigger.kind == .daily || draft.trigger.kind == .beforeEvent) {
                    FlowInfoRow(
                        symbol: "hand.tap.fill",
                        text: "Discord-, Spotify- und Erinnerungs-Schritte laufen, wenn du die Mitteilung gedrückt hältst und „Aktionen ausführen“ wählst."
                    )
                }
                if let required = draft.trigger.kind.requiredConnector, !hub.isConnected(required) {
                    FlowConnectorHint(
                        connector: required,
                        text: "Für diesen Auslöser braucht Orbit \(required.name)."
                    )
                }
            }
            .padding(18)
            .glassCard()
            .animation(.snappy, value: draft.trigger.kind)
        }
    }

    @ViewBuilder
    private var triggerFields: some View {
        switch draft.trigger {
        case .manual:
            FlowInfoRow(
                symbol: "hand.tap.fill",
                text: "Starte den Flow per Tipp auf „Ausführen“, mit Siri („Starte einen Flow in Orbit“) oder automatisch über eine Kurzbefehle-Automation."
            )
        case .daily:
            FlowDailyTriggerFields(trigger: $draft.trigger)
        case .beforeEvent:
            FlowBeforeEventFields(trigger: $draft.trigger)
        case .newMail:
            FlowNewMailFields(trigger: $draft.trigger, focus: $focus)
        }
    }

    // MARK: Schritte

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Schritte", trailing: draft.steps.count == 1 ? "1 Schritt" : "\(draft.steps.count) Schritte")
            if draft.steps.isEmpty {
                Text("Noch keine Schritte. Füge hinzu, was der Flow für dich erledigen soll.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .glassCard(radius: 24)
            }
            ForEach($draft.steps) { $step in
                FlowStepEditor(
                    step: $step,
                    number: number(of: step.id),
                    isFirst: step.id == draft.steps.first?.id,
                    isLast: step.id == draft.steps.last?.id,
                    tint: draft.color.color,
                    focus: $focus,
                    move: { offset in moveStep(step.id, by: offset) },
                    delete: { deleteStep(step.id) }
                )
            }
            addStepMenu
        }
        .animation(.snappy, value: draft.steps.map { $0.id })
    }

    private var addStepMenu: some View {
        Menu {
            ForEach(FlowAction.Kind.allCases) { kind in
                Button(kind.title, systemImage: kind.symbol) { addStep(kind) }
            }
        } label: {
            Label("Schritt hinzufügen", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glass(Capsule(), interactive: true)
                .contentShape(Capsule())
        }
    }

    private func number(of id: UUID) -> Int {
        (draft.steps.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func addStep(_ kind: FlowAction.Kind) {
        let step = FlowStep(action: kind.defaultValue)
        draft.steps.append(step)
        // Neue Textfelder werden Ziel für Platzhalter, ohne die Tastatur aufzureißen.
        switch kind {
        case .notify: lastField = .notifyBody(step.id)
        case .discord: lastField = .discordText(step.id)
        case .reminder: lastField = .reminderText(step.id)
        case .spotifyPause, .spotifyPlay: break
        }
    }

    private func moveStep(_ id: UUID, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.steps.indices.contains(target) else { return }
        draft.steps.swapAt(index, target)
    }

    private func deleteStep(_ id: UUID) {
        if focus?.stepID == id { focus = nil }
        if lastField?.stepID == id { lastField = nil }
        draft.steps.removeAll { $0.id == id }
    }

    // MARK: Platzhalter

    private var hasTextFields: Bool { fallbackField != nil }

    /// Erstes Textfeld, falls noch keines gewählt wurde.
    private var fallbackField: FlowEditorField? {
        for step in draft.steps {
            switch step.action {
            case .notify: return .notifyBody(step.id)
            case .discord: return .discordText(step.id)
            case .reminder: return .reminderText(step.id)
            case .spotifyPause, .spotifyPlay: continue
            }
        }
        return nil
    }

    /// Das Feld, in das ein Platzhalter-Chip einfügt.
    private var tokenTarget: FlowEditorField? {
        if let lastField, let id = lastField.stepID, draft.steps.contains(where: { $0.id == id }) {
            return lastField
        }
        return fallbackField
    }

    private var tokenTargetText: String? {
        guard let target = tokenTarget, let id = target.stepID,
              let index = draft.steps.firstIndex(where: { $0.id == id }) else { return nil }
        return "In: \(target.label) · Schritt \(index + 1)"
    }

    private var tokensSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Platzhalter", trailing: tokenTargetText)
            VStack(alignment: .leading, spacing: 14) {
                Text("Platzhalter werden beim Ausführen durch echte Daten ersetzt – etwa deine Termine oder ungelesenen Mails. Tippe einen an, um ihn ins zuletzt gewählte Textfeld einzufügen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WrappingChipLayout(spacing: 8) {
                    ForEach(FlowToken.available(for: draft.trigger.kind)) { token in
                        FlowTokenChip(token: token) { insert(token) }
                    }
                }
            }
            .padding(18)
            .glassCard()
        }
    }

    private func insert(_ token: FlowToken) {
        guard let target = tokenTarget, let id = target.stepID,
              let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
        draft.steps[index].action = Self.inserting(token.key, into: draft.steps[index].action, field: target)
        lastField = target
        focus = target
    }

    private static func inserting(_ key: String, into action: FlowAction, field: FlowEditorField) -> FlowAction {
        switch (action, field) {
        case (.notify(let title, let body), .notifyTitle(_)):
            return .notify(title: appending(key, to: title), body: body)
        case (.notify(let title, let body), .notifyBody(_)):
            return .notify(title: title, body: appending(key, to: body))
        case (.discord(let message), .discordText(_)):
            return .discord(message: appending(key, to: message))
        case (.reminder(let minutes, let text), .reminderText(_)):
            return .reminder(minutes: minutes, text: appending(key, to: text))
        default:
            return action
        }
    }

    private static func appending(_ key: String, to text: String) -> String {
        if text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") {
            return text + key
        }
        return text + " " + key
    }

    // MARK: Vorschau

    private var previewEvent: CalendarEvent? {
        hub.calendar.events.first { !$0.isAllDay && $0.end > .now }
    }

    private var previewMail: GmailMessage? {
        hub.gmail.messages.first
    }

    private var previewContext: FlowContext {
        switch draft.trigger.kind {
        case .beforeEvent:
            return hub.flows.makeContext(event: previewEvent)
        case .newMail:
            return hub.flows.makeContext(mail: previewMail)
        case .daily:
            return hub.flows.makeContext(date: hub.flows.nextRuns[draft.id] ?? .now)
        case .manual:
            return hub.flows.makeContext()
        }
    }

    private var preview: FlowPreviewData? {
        let context = previewContext
        if let message = draft.firstMessage {
            return FlowPreviewData(
                connector: nil,
                source: "Orbit",
                title: context.render(message.title),
                body: context.render(message.body)
            )
        }
        for step in draft.steps {
            switch step.action {
            case .discord(let message):
                return FlowPreviewData(
                    connector: .discord,
                    source: "Discord · \(hub.discord.channelLabel)",
                    title: "Orbit",
                    body: context.render(message)
                )
            case .reminder(let minutes, let text):
                return FlowPreviewData(
                    connector: nil,
                    source: "Orbit · in \(minutes) Min.",
                    title: draft.name,
                    body: context.render(text)
                )
            case .notify, .spotifyPause, .spotifyPlay:
                continue
            }
        }
        return nil
    }

    private var previewHint: String {
        switch draft.trigger.kind {
        case .beforeEvent:
            if let event = previewEvent {
                return "Beispiel mit deinem nächsten Termin „\(event.title)“."
            }
            return "Kein passender Termin gefunden – Termin-Platzhalter bleiben in der Vorschau leer."
        case .newMail:
            if let mail = previewMail {
                return "Beispiel mit der Mail von \(mail.sender)."
            }
            return "Noch keine Mail geladen – Absender und Betreff bleiben in der Vorschau leer."
        case .daily, .manual:
            return "Mit deinen aktuellen Terminen und Mails gerendert."
        }
    }

    private func previewSection(_ data: FlowPreviewData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Vorschau")
            FlowPreviewCard(data: data)
            Text(previewHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Aktionen

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.steps.isEmpty
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: save) {
                Label("Sichern", systemImage: "checkmark")
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)

            Button(action: test) {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView()
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Jetzt testen")
                }
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(isTesting || draft.steps.isEmpty)

            Text("„Jetzt testen“ führt alle Schritte sofort aus – auch Discord-Nachrichten und Spotify.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if flowID != nil {
                Button("Flow löschen", role: .destructive) { confirmDelete = true }
                    .buttonStyle(GlassButtonStyle(foreground: .danger))
                    .padding(.top, 8)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        var flow = draft
        if let flowID { flow.id = flowID }
        flow.name = flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNew = flowID == nil
        // Sichern ist eine bewusste Aktion – dann darf Orbit nach Mitteilungen fragen.
        let needsPermission = flow.isEnabled && FlowEngine.needsNotifications(flow) && hub.flows.notificationStatus == .notDetermined
        hub.flows.save(flow)
        hub.showToast(isNew ? "„\(flow.name)“ angelegt" : "Änderungen gesichert")
        focus = nil
        dismiss()
        if needsPermission {
            let engine = hub.flows
            Task { _ = await engine.requestNotificationPermission() }
        }
    }

    private func test() {
        guard !isTesting else { return }
        focus = nil
        isTesting = true
        let flow = draft
        Task {
            let summary = await hub.flows.run(flow)
            isTesting = false
            hub.showToast("Test: \(summary)")
        }
    }

    private func deleteFlow() {
        guard let flowID else { return }
        hub.flows.delete(flowID)
        hub.showToast("Flow gelöscht")
        dismiss()
    }
}

// MARK: - Auswahl von Symbol & Farbe

private struct FlowSymbolChoice: View {
    let symbol: String
    let color: Color
    let isSelected: Bool
    let select: () -> Void

    private static let names = [
        "sun.max.fill": "Sonne", "briefcase.fill": "Aktentasche", "envelope.badge.fill": "Brief",
        "house.fill": "Haus", "headphones": "Kopfhörer", "moon.stars.fill": "Mond",
        "cup.and.saucer.fill": "Tasse", "figure.walk": "Spaziergang", "bolt.fill": "Blitz",
        "bell.fill": "Glocke", "car.fill": "Auto", "cart.fill": "Einkaufswagen",
        "dumbbell.fill": "Hantel", "book.fill": "Buch", "heart.fill": "Herz"
    ]

    var body: some View {
        Button(action: select) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.8) : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    isSelected ? AnyShapeStyle(color) : AnyShapeStyle(Color.white.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.names[symbol] ?? "Symbol")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FlowColorChoice: View {
    let color: FlowColor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(color.color)
                .frame(width: 30, height: 30)
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                        .padding(-5)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Auslöser-Felder

private struct FlowTriggerKindPicker: View {
    @Binding var trigger: FlowTrigger

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(FlowTrigger.Kind.allCases) { kind in
                kindButton(kind)
            }
        }
    }

    private func kindButton(_ kind: FlowTrigger.Kind) -> some View {
        let isSelected = trigger.kind == kind
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            if !isSelected { trigger = kind.defaultValue }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.black) : AnyShapeStyle(TintShapeStyle()))
                    .frame(width: 30, height: 30)
                    .background(
                        isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(TintShapeStyle().opacity(0.14)),
                        in: Circle()
                    )
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(isSelected ? 0.14 : 0.05), in: shape)
            .overlay {
                shape.stroke(
                    isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.06)),
                    lineWidth: isSelected ? 1.5 : 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FlowDailyTriggerFields: View {
    @Binding var trigger: FlowTrigger

    private static let fullNames = [
        1: "Sonntag", 2: "Montag", 3: "Dienstag", 4: "Mittwoch", 5: "Donnerstag", 6: "Freitag", 7: "Samstag"
    ]

    private var parts: (hour: Int, minute: Int, weekdays: [Int]) {
        if case .daily(let hour, let minute, let weekdays) = trigger {
            return (hour, minute, weekdays)
        }
        return (7, 30, [])
    }

    private var time: Binding<Date> {
        Binding<Date>(
            get: {
                let current = parts
                return Calendar.current.date(bySettingHour: current.hour, minute: current.minute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                trigger = .daily(hour: components.hour ?? 7, minute: components.minute ?? 0, weekdays: parts.weekdays)
            }
        )
    }

    private var summary: String {
        let current = parts
        let time = String(format: "%02d:%02d", current.hour, current.minute)
        return "\(FlowTrigger.daysText(current.weekdays)) um \(time) Uhr. Orbit plant die Mitteilungen für die nächsten 7 Tage vor – sie kommen auch, wenn die App geschlossen ist."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker(selection: time, displayedComponents: .hourAndMinute) {
                Label("Uhrzeit", systemImage: "clock")
                    .font(.subheadline.weight(.medium))
            }
            .environment(\.locale, Fmt.locale)

            VStack(alignment: .leading, spacing: 10) {
                Text("An diesen Tagen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                weekdayRow
                presetRow
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 5) {
            ForEach(FlowTrigger.weekdayOrder, id: \.self) { day in
                dayButton(day)
            }
        }
    }

    private func dayButton(_ day: Int) -> some View {
        let current = parts.weekdays
        let isOn = current.isEmpty || current.contains(day)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            toggle(day)
        } label: {
            Text(FlowTrigger.weekdayNames[day] ?? "")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isOn ? Color.black : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.08)), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.fullNames[day] ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            presetButton("Täglich", days: [])
            presetButton("Mo–Fr", days: [2, 3, 4, 5, 6])
            presetButton("Wochenende", days: [1, 7])
        }
    }

    private func presetButton(_ title: String, days: [Int]) -> some View {
        let current = Set(parts.weekdays)
        let isSelected = days.isEmpty ? (current.isEmpty || current.count == 7) : current == Set(days)
        return Button {
            let now = parts
            trigger = .daily(hour: now.hour, minute: now.minute, weekdays: days)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(
                    isSelected ? AnyShapeStyle(TintShapeStyle().opacity(0.16)) : AnyShapeStyle(Color.white.opacity(0.06)),
                    in: Capsule()
                )
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ day: Int) {
        let current = parts
        var days = Set(current.weekdays.isEmpty ? FlowTrigger.weekdayOrder : current.weekdays)
        if days.contains(day) {
            // Mindestens ein Tag bleibt ausgewählt.
            guard days.count > 1 else { return }
            days.remove(day)
        } else {
            days.insert(day)
        }
        let ordered: [Int] = days.count == 7 ? [] : FlowTrigger.weekdayOrder.filter { days.contains($0) }
        trigger = .daily(hour: current.hour, minute: current.minute, weekdays: ordered)
    }
}

private struct FlowBeforeEventFields: View {
    @Environment(HubStore.self) private var hub
    @Binding var trigger: FlowTrigger

    private var minutes: Int {
        if case .beforeEvent(let minutes) = trigger {
            return minutes
        }
        return 10
    }

    private var minutesBinding: Binding<Int> {
        Binding<Int>(
            get: { minutes },
            set: { trigger = .beforeEvent(minutes: $0) }
        )
    }

    private var minutesText: String {
        minutes == 0 ? "Zum Terminbeginn" : "\(minutes) Min. vorher"
    }

    /// Der nächste Termin, für den der Flow noch auslösen würde.
    private var upcomingText: String? {
        let lead = Double(minutes) * 60
        guard let event = hub.calendar.events.first(where: { !$0.isAllDay && $0.start.addingTimeInterval(-lead) > .now }) else {
            return nil
        }
        let fire = event.start.addingTimeInterval(-lead)
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(fire) {
            day = "heute"
        } else if calendar.isDateInTomorrow(fire) {
            day = "morgen"
        } else {
            day = "am \(Fmt.dayTitle(fire))"
        }
        return "Nächster Termin: „\(event.title)“ – Orbit meldet sich \(day) um \(Fmt.time(fire)) Uhr."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: minutesBinding, in: 0...120, step: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(minutesText)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .contentTransition(.numericText())
                    Text("vor jedem Termin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let upcomingText {
                FlowInfoRow(symbol: "calendar", text: upcomingText)
            }
            Text("Ganztägige Termine werden übersprungen. Platzhalter wie {termin}, {termin_ende} und {ort} enthalten die Daten des jeweiligen Termins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FlowNewMailFields: View {
    @Binding var trigger: FlowTrigger
    var focus: FocusState<FlowEditorField?>.Binding

    private var sender: Binding<String> {
        Binding<String>(
            get: {
                if case .newMail(let sender) = trigger {
                    return sender
                }
                return ""
            },
            set: { trigger = .newMail(senderContains: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowTextInput(
                title: "Nur von Absender (optional)",
                prompt: "z. B. Lea oder @firma.de",
                text: sender,
                field: .sender,
                focus: focus
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Text("Leer lassen, um bei jeder neuen Mail ausgelöst zu werden. Orbit prüft neue Mails bei jeder Aktualisierung – auch im Hintergrund.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Schritt-Editor

private struct FlowStepEditor: View {
    @Environment(HubStore.self) private var hub
    @Binding var step: FlowStep
    let number: Int
    let isFirst: Bool
    let isLast: Bool
    let tint: Color
    var focus: FocusState<FlowEditorField?>.Binding
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fields
            if let connector = step.action.connector, !hub.isConnected(connector) {
                FlowConnectorHint(
                    connector: connector,
                    text: "\(connector.name) ist nicht verbunden – dieser Schritt wird beim Ausführen übersprungen."
                )
            }
        }
        .padding(18)
        .glassCard(radius: 24)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            FlowStepIcon(action: step.action, size: 34, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.action.title)
                    .font(.subheadline.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Nach oben", systemImage: "arrow.up") { move(-1) }
                    .disabled(isFirst)
                Button("Nach unten", systemImage: "arrow.down") { move(1) }
                    .disabled(isLast)
                Divider()
                Button("Schritt entfernen", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Optionen für Schritt \(number)")
        }
    }

    private var caption: String {
        switch step.action {
        case .notify: "Mitteilung auf deinem iPhone"
        case .discord: "Postet als „Orbit“ in \(hub.discord.channelLabel)"
        case .spotifyPause: "Hält die laufende Wiedergabe an"
        case .spotifyPlay: "Startet Musik auf deinem aktiven Gerät"
        case .reminder: "Mitteilung – etwas später"
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch step.action {
        case .notify:
            FlowTextInput(title: "Titel", prompt: "z. B. Guten Morgen!", text: notifyTitle, field: .notifyTitle(step.id), focus: focus)
            FlowTextInput(title: "Text", prompt: "Was soll in der Mitteilung stehen?", text: notifyBody, field: .notifyBody(step.id), focus: focus, multiline: true)
        case .discord:
            FlowTextInput(title: "Nachricht", prompt: "z. B. Bin gleich im Meeting", text: discordText, field: .discordText(step.id), focus: focus, multiline: true)
        case .spotifyPause:
            Text("Pausiert die Musik auf deinem aktiven Spotify-Gerät – praktisch vor Meetings und Anrufen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .spotifyPlay(let uri, let name):
            FlowPlaylistPicker(contextURI: uri, name: name) { newURI, newName in
                step.action = .spotifyPlay(contextURI: newURI, name: newName)
            }
        case .reminder(let minutes, _):
            Stepper(value: reminderMinutes, in: 5...480, step: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.durationText(minutes))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .contentTransition(.numericText())
                    Text("nach dem Ausführen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            FlowTextInput(title: "Text", prompt: "Woran soll Orbit dich erinnern?", text: reminderText, field: .reminderText(step.id), focus: focus, multiline: true)
        }
    }

    private static func durationText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) Min." }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) Std." : "\(hours) Std. \(rest) Min."
    }

    // MARK: Bindings an die Werte der Aktion

    private var notifyTitle: Binding<String> {
        Binding<String>(
            get: {
                if case .notify(let title, _) = step.action {
                    return title
                }
                return ""
            },
            set: { newValue in
                if case .notify(_, let body) = step.action {
                    step.action = .notify(title: newValue, body: body)
                }
            }
        )
    }

    private var notifyBody: Binding<String> {
        Binding<String>(
            get: {
                if case .notify(_, let body) = step.action {
                    return body
                }
                return ""
            },
            set: { newValue in
                if case .notify(let title, _) = step.action {
                    step.action = .notify(title: title, body: newValue)
                }
            }
        )
    }

    private var discordText: Binding<String> {
        Binding<String>(
            get: {
                if case .discord(let message) = step.action {
                    return message
                }
                return ""
            },
            set: { newValue in
                if case .discord = step.action {
                    step.action = .discord(message: newValue)
                }
            }
        )
    }

    private var reminderMinutes: Binding<Int> {
        Binding<Int>(
            get: {
                if case .reminder(let minutes, _) = step.action {
                    return minutes
                }
                return 30
            },
            set: { newValue in
                if case .reminder(_, let text) = step.action {
                    step.action = .reminder(minutes: newValue, text: text)
                }
            }
        )
    }

    private var reminderText: Binding<String> {
        Binding<String>(
            get: {
                if case .reminder(_, let text) = step.action {
                    return text
                }
                return ""
            },
            set: { newValue in
                if case .reminder(let minutes, _) = step.action {
                    step.action = .reminder(minutes: minutes, text: newValue)
                }
            }
        )
    }
}

/// Beschriftetes Textfeld im Stil der Glas-Karten.
private struct FlowTextInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let field: FlowEditorField
    var focus: FocusState<FlowEditorField?>.Binding
    var multiline = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let isFocused = focus.wrappedValue == field
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(multiline ? 2...6 : 1...3)
                .focused(focus, equals: field)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 46)
                .background(Color.black.opacity(0.25), in: shape)
                .overlay {
                    shape.stroke(
                        isFocused ? AnyShapeStyle(TintShapeStyle().opacity(0.7)) : AnyShapeStyle(Color.white.opacity(0.06)),
                        lineWidth: 1
                    )
                }
                .accessibilityLabel(title)
        }
    }
}

/// Auswahl einer Spotify-Playlist oder „Wiedergabe fortsetzen“.
private struct FlowPlaylistPicker: View {
    @Environment(HubStore.self) private var hub
    let contextURI: String?
    let name: String?
    let select: (String?, String?) -> Void

    private var playlists: [SpotifyPlaylist] {
        hub.spotify.playlists.filter { $0.uri != nil }
    }

    private var hint: String {
        if !hub.spotify.isConnected {
            return "Verbinde Spotify, um eine Playlist auszuwählen. Ohne Auswahl setzt Orbit die Wiedergabe fort."
        }
        if playlists.isEmpty {
            return "Keine Playlists gefunden – Orbit setzt die Wiedergabe fort."
        }
        return "Braucht Spotify Premium und ein aktives Gerät."
    }

    var body: some View {
        let selected = playlists.first(where: { $0.uri == contextURI })
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button {
                    select(nil, nil)
                } label: {
                    choiceLabel("Wiedergabe fortsetzen", isSelected: contextURI == nil)
                }
                if !playlists.isEmpty {
                    Section("Deine Playlists") {
                        ForEach(playlists) { playlist in
                            Button {
                                select(playlist.uri, playlist.name)
                            } label: {
                                choiceLabel(playlist.name, isSelected: contextURI != nil && playlist.uri == contextURI)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    if contextURI != nil {
                        Artwork(url: selected?.artworkURL, size: 40, radius: 10)
                    } else {
                        Image(systemName: "playpause.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Connector.spotify.tint)
                            .frame(width: 40, height: 40)
                            .background(Connector.spotify.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contextURI == nil ? "Wiedergabe fortsetzen" : (name ?? selected?.name ?? "Playlist"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(contextURI == nil ? "Spielt weiter, was zuletzt lief" : "Playlist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Playlist wählen")
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Kleine Bausteine

private struct FlowTokenChip: View {
    let token: FlowToken
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.heavy))
                Text(token.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(TintShapeStyle().opacity(0.14), in: Capsule())
            // Sichtbar 36 pt hoch, tippbar auf 44 pt.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Platzhalter \(token.label) einfügen")
    }
}

private struct FlowInfoRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hinweis, dass ein Konnektor fehlt, mit Button zum Verbinden.
private struct FlowConnectorHint: View {
    @Environment(HubStore.self) private var hub
    let connector: Connector
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ConnectorIcon(connector: connector, size: 32)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Verbinden") { hub.connectSheet = connector }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityLabel("\(connector.name) verbinden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FlowPreviewCard: View {
    let data: FlowPreviewData

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let connector = data.connector {
                ConnectorIcon(connector: connector, size: 38)
            } else {
                HubMark(size: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(data.source.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("jetzt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(data.title.isEmpty ? "Ohne Titel" : data.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !data.body.isEmpty {
                    Text(data.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
        .accessibilityElement(children: .combine)
    }
}
