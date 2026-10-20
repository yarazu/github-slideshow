import SwiftUI
import UIKit

// MARK: - Hintergrund

struct HubBackground: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let photo = appearance.activePhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: appearance.blur, opaque: true)
                } else {
                    PresetBackground(preset: appearance.preset)
                }
                Color.black.opacity(appearance.dim)
            }
        }
        .ignoresSafeArea()
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

/// Das Hub-Zeichen aus dem Entwurf: ein Knoten mit vier Satelliten.
struct HubGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius * unit, y: center.y - radius * unit, width: 2 * radius * unit, height: 2 * radius * unit)
        }

        var path = Path()
        path.addEllipse(in: circle(point(12, 12), 2.5))
        let spokes: [(CGPoint, CGPoint)] = [
            (point(12, 9.5), point(12, 6)),
            (point(12, 14.5), point(12, 18)),
            (point(9.5, 12), point(6, 12)),
            (point(14.5, 12), point(18, 12))
        ]
        for (from, to) in spokes {
            path.move(to: from)
            path.addLine(to: to)
        }
        for satellite in [point(12, 4.25), point(12, 19.75), point(4.25, 12), point(19.75, 12)] {
            path.addEllipse(in: circle(satellite, 1.75))
        }
        return path
    }
}

struct HubMark: View {
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(.tint)
            .frame(width: size, height: size)
            .overlay {
                HubGlyph()
                    .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round))
                    .padding(size * 0.2)
            }
            .accessibilityHidden(true)
    }
}

struct ConnectorIcon: View {
    let connector: Connector
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [connector.tint.opacity(0.95), connector.tint.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: connector.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
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
                .tracking(0.8)
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
                .font(.system(.title3, design: .rounded).weight(.semibold))
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

/// Hub ←→ Konnektor, wie im Entwurf.
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
        .accessibilityLabel(connected ? "Hub ist mit \(connector.name) verbunden" : "Hub und \(connector.name)")
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
            .font(.headline)
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

    var body: some View {
        Button("Verbindung trennen") { confirming = true }
            .buttonStyle(GlassButtonStyle(foreground: .danger))
            .confirmationDialog("\(connector.name) trennen?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Trennen", role: .destructive, action: action)
            } message: {
                Text("Der Hub zeigt danach keine Daten von \(connector.name) mehr an.")
            }
    }
}
