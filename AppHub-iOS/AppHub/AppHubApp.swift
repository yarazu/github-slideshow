import SwiftUI

@main
struct AppHubApp: App {
    @State private var hub = HubStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(hub.appearance)
                .preferredColorScheme(.dark)
        }
    }
}

enum Route: Hashable {
    case connector(Connector)
    case appearance
    case setup
}

struct RootView: View {
    @Environment(HubStore.self) private var hub
    @Environment(Appearance.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []

    var body: some View {
        @Bindable var hub = hub
        NavigationStack(path: $path) {
            HubView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .connector(.calendar): CalendarDetailView()
                    case .connector(.gmail): GmailDetailView()
                    case .connector(.spotify): SpotifyDetailView()
                    case .appearance: AppearanceView()
                    case .setup: SetupView()
                    }
                }
        }
        .sheet(item: $hub.connectSheet) { connector in
            ConnectSheet(connector: connector)
                .tint(appearance.accent)
        }
        .tint(appearance.accent)
        .overlay(alignment: .bottom) { toast }
        .animation(.spring(duration: 0.35), value: hub.toast)
        .task {
            #if DEBUG
            if let route = hub.applyLaunchArguments() { path = [route] }
            #endif
            await hub.refreshAll()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await hub.refreshAll() } }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = hub.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                Text(message)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glass(Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
        }
    }
}
