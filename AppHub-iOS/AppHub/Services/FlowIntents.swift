import AppIntents
import Foundation

// MARK: - Flow als App-Entität

/// Ein Flow, wie ihn Siri und die Kurzbefehle-App sehen.
struct FlowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flow"
    static let defaultQuery = FlowEntityQuery()

    let id: UUID
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbol))
    }
}

extension FlowEntity {
    init(_ flow: Flow) {
        self.init(id: flow.id, name: flow.name, symbol: flow.symbol)
    }
}

/// Liest die Flows direkt aus der Flow-Engine der App.
struct FlowEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FlowEntity] {
        HubStore.shared.flows.flows
            .filter { identifiers.contains($0.id) }
            .map { FlowEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [FlowEntity] {
        HubStore.shared.flows.flows.map { FlowEntity($0) }
    }
}

// MARK: - Intent

/// „Flow ausführen“ – für Siri, die Kurzbefehle-App und Kurzbefehle-Automationen.
struct RunFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "Flow ausführen"
    static let description = IntentDescription("Führt einen deiner Orbit-Flows aus, z. B. Musik pausieren und Discord Bescheid geben.")
    static let openAppWhenRun = false

    @Parameter(title: "Flow")
    var flow: FlowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$flow) ausführen")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = HubStore.shared.flows
        let text: String
        if let current = engine.flow(id: flow.id) {
            let summary = await engine.run(id: current.id)
            text = "\(current.name): \(summary)"
        } else {
            text = "Diesen Flow gibt es nicht mehr."
        }
        return .result(dialog: "\(text)")
    }
}

// MARK: - Kurzbefehle

/// Kurzbefehle, die ohne Einrichtung in Siri und der Kurzbefehle-App erscheinen.
struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunFlowIntent(),
            phrases: [
                "Starte einen Flow in \(.applicationName)",
                "\(.applicationName) \(\.$flow) starten",
                "Führe \(\.$flow) mit \(.applicationName) aus"
            ],
            shortTitle: "Flow ausführen",
            systemImageName: "bolt.fill"
        )
    }
}
