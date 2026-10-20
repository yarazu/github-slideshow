import SwiftUI

@main
struct AppHubApp: App {
    @UIApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate
    @State private var hub = HubStore.shared

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

/// Die vier Tabs von Orbit mit eigenen Navigationspfaden, dazu Verbinden-Sheet, Hinweis-Toast und Willkommen.
struct RootView: View {
    @Environment(HubStore.self) private var hub
    @Environment(Appearance.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("orbit.didOnboard") private var didOnboard = false
    @State private var hubPath: [Route] = []
    @State private var flowPath: [FlowRoute] = []
    @State private var settingsPath: [Route] = []
    @State private var showWelcome = false
    @State private var didStart = false

    var body: some View {
        @Bindable var hub = hub
        TabView(selection: $hub.selectedTab) {
            NavigationStack(path: $hubPath) {
                HubView()
                    .navigationDestination(for: Route.self) { route in
                        OrbitRouteDestination(route: route)
                    }
            }
            .tabItem { Label("Orbit", systemImage: "circle.hexagongrid.fill") }
            .tag(AppTab.hub)

            NavigationStack(path: $flowPath) {
                FlowsView()
            }
            .tabItem { Label("Flows", systemImage: "bolt.fill") }
            .tag(AppTab.flows)

            NavigationStack {
                ActivityView()
            }
            .tabItem { Label("Aktivität", systemImage: "bell.fill") }
            .badge(hub.activity.unseenCount)
            .tag(AppTab.activity)

            NavigationStack(path: $settingsPath) {
                SettingsView()
                    .navigationDestination(for: Route.self) { route in
                        OrbitRouteDestination(route: route)
                    }
            }
            .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
            .tag(AppTab.settings)
        }
        .tint(appearance.accent)
        .sheet(item: $hub.connectSheet) { connector in
            ConnectSheet(connector: connector)
                .tint(appearance.accent)
        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                didOnboard = true
                showWelcome = false
            }
            .tint(appearance.accent)
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.spring(duration: 0.35), value: hub.toast)
        .task { await start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, didStart else { return }
            Task {
                await hub.refreshAll()
                await hub.flows.refreshNotificationStatus()
            }
        }
        .onChange(of: didOnboard) { _, done in
            // „Einführung erneut ansehen“ in den Einstellungen.
            if !done { showWelcome = true }
        }
    }

    // MARK: Start

    private func start() async {
        guard !didStart else { return }
        didStart = true
        var welcome = !didOnboard
        #if DEBUG
        if hub.isDemo {
            hub.applyDemo()
            welcome = false
        }
        if applyLaunchScreen() { welcome = true }
        #endif
        if welcome {
            // Ohne Einblend-Animation, damit die Tabs beim ersten Start nicht kurz aufblitzen.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showWelcome = true }
        }
        await hub.refreshAll()
        await hub.flows.refreshNotificationStatus()
    }

    #if DEBUG
    /// Für Simulator-Screenshots: `-AppHubDemo YES -AppHubScreen flows`.
    /// Gibt `true` zurück, wenn der Willkommens-Bildschirm gezeigt werden soll.
    private func applyLaunchScreen() -> Bool {
        guard let screen = hub.launchScreen else { return false }
        switch screen {
        case "calendar":
            open(.connector(.calendar))
        case "gmail":
            open(.connector(.gmail))
        case "spotify":
            open(.connector(.spotify))
        case "discord":
            open(.connector(.discord))
        case "appearance":
            hub.selectedTab = .settings
            settingsPath = [.appearance]
        case "setup":
            hub.selectedTab = .settings
            settingsPath = [.setup]
        case "connect":
            hub.selectedTab = .hub
            hub.connectSheet = .discord
        case "flows":
            hub.selectedTab = .flows
        case "flowEditor":
            hub.selectedTab = .flows
            if let id = hub.flows.flows.first?.id {
                flowPath = [.edit(id)]
            }
        case "activity":
            hub.selectedTab = .activity
        case "settings":
            hub.selectedTab = .settings
        case "welcome":
            return true
        default:
            hub.selectedTab = .hub
        }
        return false
    }

    private func open(_ route: Route) {
        hub.selectedTab = .hub
        hubPath = [route]
    }
    #endif

    // MARK: Toast

    @ViewBuilder
    private var toast: some View {
        if let message = hub.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                Text(message)
                    .lineLimit(2)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glass(Capsule())
            .padding(.horizontal, 20)
            // Über der Tab-Leiste schweben.
            .padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Ziele der Routen im Orbit- und im Einstellungen-Tab.
private struct OrbitRouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .connector(.calendar): CalendarDetailView()
        case .connector(.gmail): GmailDetailView()
        case .connector(.spotify): SpotifyDetailView()
        case .connector(.discord): DiscordDetailView()
        case .appearance: AppearanceView()
        case .setup: SetupView()
        }
    }
}
