import SwiftUI
import UIKit

// MARK: - Hintergrund

/// Das gewählte Bild (bzw. der Verlauf) hinter allen Bildschirmen – mit Unschärfe, Abdunklung und
/// einem sanften Verlauf oben und unten, damit Text auf jedem Bild gut lesbar bleibt.
struct HubBackground: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = appearance.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: appearance.blur, opaque: true)
                } else {
                    PresetBackground(preset: appearance.gradient ?? .aurora)
                }
                Color.black.opacity(appearance.dim)
                LinearGradient(
                    stops: [
                        Gradient.Stop(color: Color.black.opacity(0.38), location: 0),
                        Gradient.Stop(color: Color.black.opacity(0), location: 0.26),
                        Gradient.Stop(color: Color.black.opacity(0), location: 0.68),
                        Gradient.Stop(color: Color.black.opacity(0.42), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PresetBackground: View {
    let preset: BackgroundPreset

    var body: some View {
        if #available(iOS 18.0, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.58, 0.42], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: preset.colors
            )
        } else {
            LinearGradient(
                colors: [preset.colors[1], preset.colors[4], preset.colors[7]],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Marken & Symbole

/// Das Orbit-Zeichen als Umriss: Planet, geneigter Ring und Satellit (z. B. für Linien oder Masken).
struct HubGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tilt = CGAffineTransform(rotationAngle: OrbitGeometry.tiltDegrees * .pi / 180)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))

        var path = Path()
        let planet = size * OrbitGeometry.planetRatio / 2
        path.addEllipse(in: CGRect(x: center.x - planet, y: center.y - planet, width: planet * 2, height: planet * 2))

        let ringWidth = size * OrbitGeometry.ringWidthRatio
        let ringHeight = size * OrbitGeometry.ringHeightRatio
        let ring = CGRect(x: -ringWidth / 2, y: -ringHeight / 2, width: ringWidth, height: ringHeight)
        path.addPath(Path(ellipseIn: ring), transform: tilt)

        let satellite = size * OrbitGeometry.satelliteRatio / 2
        let position = CGPoint(x: ringWidth / 2 * OrbitGeometry.satelliteX, y: ringHeight / 2 * OrbitGeometry.satelliteY).applying(tilt)
        path.addEllipse(in: CGRect(x: position.x - satellite, y: position.y - satellite, width: satellite * 2, height: satellite * 2))
        return path
    }
}

/// Maße des Orbit-Zeichens relativ zur Kantenlänge (gemeinsam für `HubGlyph` und `OrbitEmblem`).
private enum OrbitGeometry {
    static let tiltDegrees: CGFloat = 25
    static let planetRatio: CGFloat = 0.42
    static let ringWidthRatio: CGFloat = 0.8
    static let ringHeightRatio: CGFloat = 0.3
    static let satelliteRatio: CGFloat = 0.11
    /// Lage des Satelliten auf dem Ring (cos/sin von 35°), vorne rechts unten wie im App-Icon.
    static let satelliteX: CGFloat = 0.82
    static let satelliteY: CGFloat = 0.57
}

/// Limetten-Planet mit geneigtem Ring und Satellit – frei stehend, ohne Kachel (z. B. groß auf dem Willkommens-Bildschirm).
struct OrbitEmblem: View {
    var size: CGFloat = 44

    var body: some View {
        let ringWidth = size * OrbitGeometry.ringWidthRatio
        let ringHeight = size * OrbitGeometry.ringHeightRatio
        let line = max(1, size * 0.034)
        let planet = size * OrbitGeometry.planetRatio
        let satellite = size * OrbitGeometry.satelliteRatio
        let tilt = Angle.degrees(Double(OrbitGeometry.tiltDegrees))
        let ringStyle = StrokeStyle(lineWidth: line, lineCap: .round)

        ZStack {
            // Hintere Hälfte des Rings liegt hinter dem Planeten.
            Ellipse()
                .trim(from: 0.5, to: 1)
                .stroke(Color.white.opacity(0.9), style: ringStyle)
                .frame(width: ringWidth, height: ringHeight)
                .rotationEffect(tilt)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xEAFBA8), Color.orbitLime, Color(hex: 0x98C41E)],
                        center: UnitPoint(x: 0.34, y: 0.3),
                        startRadius: 0,
                        endRadius: planet * 0.78
                    )
                )
                .frame(width: planet, height: planet)
                .shadow(color: Color.orbitLime.opacity(0.35), radius: size * 0.06)

            // Vordere Hälfte mit Satellit.
            ZStack {
                Ellipse()
                    .trim(from: 0, to: 0.5)
                    .stroke(Color.white, style: ringStyle)
                    .frame(width: ringWidth, height: ringHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: satellite, height: satellite)
                    .offset(x: ringWidth / 2 * OrbitGeometry.satelliteX, y: ringHeight / 2 * OrbitGeometry.satelliteY)
            }
            .rotationEffect(tilt)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Das Orbit-Zeichen wie im App-Icon: Limetten-Planet mit Ring und Satellit auf Indigo.
struct HubMark: View {
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [Color.orbitViolet, Color.orbitIndigo, Color.orbitTeal],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                RadialGradient(
                    colors: [Color(hex: 0x9A80FF).opacity(0.75), Color.clear],
                    center: UnitPoint(x: 0.28, y: 0.18),
                    startRadius: 0,
                    endRadius: size * 0.62
                )
            }
            .overlay {
                OrbitEmblem(size: size * 0.86)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.5, size * 0.014))
            }
            .accessibilityHidden(true)
    }
}

/// Marken-Kachel eines Konnektors: Logo auf der Farbe des jeweiligen App-Icons.
struct ConnectorIcon: View {
    let connector: Connector
    var size: CGFloat = 52

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        shape
            .fill(connector.tileColor)
            .frame(width: size, height: size)
            .overlay {
                Image(connector.logoAsset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(connector.logoColor)
                    .padding(size * 0.22)
            }
            .overlay {
                // Feiner Rand: weiße Kacheln heben sich so vom Glas ab, farbige bekommen etwas Glanz.
                shape.strokeBorder(
                    connector.hasLightTile ? Color.black.opacity(0.1) : Color.white.opacity(0.14),
                    lineWidth: max(0.5, size * 0.02)
                )
            }
            .accessibilityHidden(true)
    }
}

private extension Connector {
    var hasLightTile: Bool {
        switch self {
        case .calendar, .gmail: true
        case .spotify, .discord: false
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(TintShapeStyle()))
                .frame(width: 8, height: 8)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.1), in: Capsule())
    }
}

struct CardLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Orbit ←→ Konnektor, wie im Entwurf.
struct ConnectionVisual: View {
    let connector: Connector
    let connected: Bool
    var size: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            HubMark(size: size)
            ZStack {
                if connected {
                    HLine().stroke(TintShapeStyle().opacity(0.6), lineWidth: 2)
                } else {
                    HLine().stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                }
                Circle()
                    .fill(connected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.35)))
                    .frame(width: 12, height: 12)
            }
            .frame(width: 72, height: size)
            ConnectorIcon(connector: connector, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel(connected ? "Orbit ist mit \(connector.name) verbunden" : "Orbit und \(connector.name)")
    }
}

struct PermissionList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.tint)
                        .frame(width: 26, height: 26)
                        .background(TintShapeStyle().opacity(0.16), in: Circle())
                    Text(item)
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < items.count - 1 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(.horizontal, 16)
        .glassCard(radius: 22)
    }
}

struct NoticeBanner: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.danger)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(radius: 20)
    }
}

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 56
    var radius: CGFloat = 12

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                LinearGradient(
                    colors: [Connector.spotify.tint.opacity(0.8), Color(hex: 0x1B2A5C)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var foreground: Color = .primary
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 14)
            .glass(Capsule(), interactive: true)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glass(Circle(), interactive: true)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Bestätigt und trennt einen Konnektor.
struct DisconnectButton: View {
    let connector: Connector
    let action: () -> Void
    @State private var confirming = false

    init(connector: Connector, action: @escaping () -> Void) {
        self.connector = connector
        self.action = action
    }

    var body: some View {
        Button("Verbindung trennen") { confirming = true }
            .buttonStyle(GlassButtonStyle(foreground: .danger))
            .confirmationDialog("\(connector.name) trennen?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Trennen", role: .destructive, action: action)
            } message: {
                Text("Orbit zeigt danach keine Daten von \(connector.name) mehr an.")
            }
    }
}
