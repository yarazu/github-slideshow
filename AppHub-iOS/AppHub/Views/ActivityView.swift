import SwiftUI
import UIKit

/// Tab „Aktivität“: alles, was Flows erledigt haben – nach Tagen gruppiert.
struct ActivityView: View {
    @Environment(HubStore.self) private var hub
    @State private var confirmClear = false
    /// Einträge, die seit dem letzten Besuch neu sind (beim Öffnen gemerkt).
    @State private var newIDs: Set<UUID> = []

    private struct Day: Identifiable {
        let id: Date
        let entries: [ActivityEntry]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: hub.activity.entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { Day(id: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        let entries = hub.activity.entries
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if entries.isEmpty {
                    ActivityEmptyState()
                } else {
                    ActivitySummary(entries: entries)
                    ForEach(days) { day in
                        ActivityDaySection(date: day.id, entries: day.entries, newIDs: newIDs)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle("Aktivität")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Leeren") { confirmClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("Verlauf leeren?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Verlauf leeren", role: .destructive) {
                hub.activity.clear()
                newIDs = []
            }
        } message: {
            Text("Alle Einträge werden von diesem iPhone entfernt. Deine Flows bleiben erhalten.")
        }
        .refreshable { await hub.refreshAll() }
        .onAppear {
            let count = hub.activity.unseenCount
            newIDs = Set(hub.activity.entries.prefix(count).map { $0.id })
            hub.activity.markAllSeen()
        }
        .onDisappear { hub.activity.markAllSeen() }
        .animation(.snappy, value: entries.count)
    }
}

// MARK: - Überblick

private struct ActivitySummary: View {
    let entries: [ActivityEntry]

    private var today: [ActivityEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        let today = self.today
        let messages = today.filter { $0.kind == .message || $0.kind == .reminder || $0.kind == .mail }.count
        let discord = today.filter { $0.kind == .discord }.count
        let errors = today.filter { $0.kind == .error }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Alles, was deine Flows erledigt haben – Mitteilungen, Discord-Posts, Musik und Erinnerungen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ActivityStat(value: today.count, label: "Heute", symbol: "sparkles", tint: nil)
                ActivityStat(value: messages, label: "Mitteilungen", symbol: "bell.badge.fill", tint: Color(hex: 0xFFD25A))
                if errors > 0 {
                    ActivityStat(value: errors, label: "Fehler", symbol: "exclamationmark.triangle.fill", tint: .danger)
                } else {
                    ActivityStat(value: discord, label: "Discord", symbol: "bubble.left.and.bubble.right.fill", tint: Connector.discord.tint)
                }
            }
        }
    }
}

private struct ActivityStat: View {
    let value: Int
    let label: String
    let symbol: String
    /// `nil` = Akzentfarbe.
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(TintShapeStyle()))
            Text("\(value)")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(radius: 20)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tage & Einträge

private struct ActivityDaySection: View {
    let date: Date
    let entries: [ActivityEntry]
    let newIDs: Set<UUID>

    private var title: String {
        Calendar.current.isDateInYesterday(date) ? "Gestern" : Fmt.dayTitle(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, trailing: entries.count == 1 ? "1 Eintrag" : "\(entries.count) Einträge")
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    ActivityEntryRow(entry: entry, isNew: newIDs.contains(entry.id))
                    if entry.id != entries.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, 16)
            .glassCard(radius: 24)
        }
    }
}

private struct ActivityEntryRow: View {
    @Environment(HubStore.self) private var hub
    let entry: ActivityEntry
    let isNew: Bool

    /// Farbe des Symbols; `nil` = Akzentfarbe.
    private var tint: Color? {
        switch entry.kind {
        case .message: nil
        case .reminder: Color(hex: 0xFFD25A)
        case .run: Color(hex: 0xA98BFF)
        case .error: .danger
        case .discord: Connector.discord.tint
        case .spotify: Connector.spotify.tint
        case .mail: Connector.gmail.tint
        }
    }

    private var flow: Flow? {
        guard let name = entry.flowName else { return nil }
        return hub.flows.flows.first { $0.name == name }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.kind == .error ? AnyShapeStyle(Color.danger) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if isNew {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Neu")
                    }
                    Text(Fmt.time(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let flowName = entry.flowName {
                    Label(flowName, systemImage: "bolt.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var icon: some View {
        if let connector = entry.connector {
            ConnectorIcon(connector: connector, size: 40)
        } else {
            Image(systemName: entry.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(TintShapeStyle()))
                .frame(width: 40, height: 40)
                .background(
                    tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(TintShapeStyle().opacity(0.16)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Text kopieren", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = entry.detail.isEmpty ? entry.title : "\(entry.title)\n\(entry.detail)"
        }
        if let flow {
            Button("„\(flow.name)“ erneut ausführen", systemImage: "play.fill") {
                Task {
                    let summary = await hub.flows.run(flow)
                    hub.showToast("\(flow.name): \(summary)")
                }
            }
        }
    }
}

// MARK: - Leerer Zustand

private struct ActivityEmptyState: View {
    @Environment(HubStore.self) private var hub

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(TintShapeStyle().opacity(0.14), in: Circle())
            Text("Noch nichts passiert")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Sobald Flows laufen, siehst du hier jede Nachricht.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                hub.selectedTab = .flows
            } label: {
                Label("Zu den Flows", systemImage: "bolt.fill")
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCard()
        .padding(.top, 12)
    }
}
