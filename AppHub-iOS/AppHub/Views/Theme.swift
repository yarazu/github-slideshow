import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let danger = Color(hex: 0xFF7A6B)

    /// Markenfarben von Orbit, wie im App-Icon.
    static let orbitLime = Color(hex: 0xC6F432)
    static let orbitViolet = Color(hex: 0x7B5CFF)
    static let orbitIndigo = Color(hex: 0x33228A)
    static let orbitTeal = Color(hex: 0x1D6E86)
}

extension View {
    /// Liquid Glass ab iOS 26, sonst Material mit feiner Kante.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let style: Glass = interactive ? Glass.regular.interactive() : Glass.regular
            self.glassEffect(style, in: shape)
        } else {
            materialGlass(shape)
        }
        #else
        materialGlass(shape)
        #endif
    }

    func glassCard(radius: CGFloat = 28) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func materialGlass<S: Shape>(_ shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// Sheets bekommen unter iOS 26 automatisch Glas, davor ein Material.
    @ViewBuilder
    func hubSheetBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            presentationBackground(.ultraThinMaterial)
        }
    }
}

enum Fmt {
    static let locale = Locale(identifier: "de_DE")

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInTomorrow(date) { return "Morgen" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
    }

    /// Ausgeschriebenes Datum ohne Jahr, z. B. „Dienstag, 20. Oktober“.
    static func longDate(_ date: Date = .now) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
    }

    static func weekdayShort(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
            .replacingOccurrences(of: ".", with: "")
            .uppercased()
    }

    static func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day().locale(locale))
            .replacingOccurrences(of: ".", with: "")
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func mailDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return time(date) }
        return date.formatted(.dateTime.day().month(.twoDigits).locale(locale))
    }

    static func greeting(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: "Guten Morgen"
        case 11..<18: "Hallo"
        default: "Guten Abend"
        }
    }
}
