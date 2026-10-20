import SwiftUI

/// Begrüßung beim ersten Start: Hintergrundbild, großes Orbit-Zeichen, Tagline und was Orbit kann.
struct WelcomeView: View {
    let onFinish: () -> Void

    @State private var appeared = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                hero
                VStack(spacing: 12) {
                    WelcomeFeatureRow(
                        title: "Alles an einem Ort",
                        text: "Kalender, Gmail, Spotify und Discord auf einen Blick – mit einem Tipp verbunden."
                    ) {
                        WelcomeLogoCluster()
                    }
                    WelcomeFeatureRow(
                        title: "Flows für deine Routinen",
                        text: "Morgen-Briefing, Meeting-Modus, Feierabend: Orbit erledigt Wiederkehrendes für dich."
                    ) {
                        WelcomeSymbolTile(symbol: "bolt.fill", color: Color.orbitLime)
                    }
                    WelcomeFeatureRow(
                        title: "Nachrichten, die mitdenken",
                        text: "Erinnerungen vor Terminen, Hinweise zu neuen Mails und Status-Updates an dein Team."
                    ) {
                        WelcomeSymbolTile(symbol: "bell.badge.fill", color: Color(hex: 0xFFB86B))
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button("Los geht's", action: onFinish)
                    .buttonStyle(AccentButtonStyle())
                Text("Du kannst alles jederzeit in den Einstellungen ändern.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background {
                // Inhalte, die darunter scrollen, verschwinden sanft statt hinter dem Button zu stehen.
                LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .background { HubBackground() }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.25)) { appeared = true }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orbitLime.opacity(0.22))
                    .frame(width: 130, height: 130)
                    .blur(radius: 36)
                HubMark(size: 92)
                    .shadow(color: Color.black.opacity(0.35), radius: 24, y: 12)
            }
            .scaleEffect(appeared ? 1 : 0.86)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 8) {
                Text("Orbit")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Dein Alltag, verbunden.")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Eine Zeile „Was kann Orbit?“ mit Bild links.
private struct WelcomeFeatureRow<Icon: View>: View {
    let title: String
    let text: String
    let icon: Icon

    init(title: String, text: String, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.text = text
        self.icon = icon()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            icon
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(radius: 24)
        .accessibilityElement(children: .combine)
    }
}

/// Die vier Marken-Logos, leicht überlappend.
private struct WelcomeLogoCluster: View {
    var body: some View {
        let size: CGFloat = 30
        VStack(spacing: -6) {
            HStack(spacing: -6) {
                tile(.calendar, size: size)
                tile(.gmail, size: size)
            }
            HStack(spacing: -6) {
                tile(.spotify, size: size)
                tile(.discord, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func tile(_ connector: Connector, size: CGFloat) -> some View {
        ConnectorIcon(connector: connector, size: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 2)
            }
    }
}

private struct WelcomeSymbolTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.78))
            }
            .accessibilityHidden(true)
    }
}
