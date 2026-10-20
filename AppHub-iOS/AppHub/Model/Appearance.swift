import SwiftUI
import UIKit

enum AccentChoice: String, CaseIterable, Identifiable {
    case lime, sky, apricot, lilac, rose

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .lime: Color(hex: 0xC6F432)
        case .sky: Color(hex: 0x7CC4FF)
        case .apricot: Color(hex: 0xFFB86B)
        case .lilac: Color(hex: 0xC9A7FF)
        case .rose: Color(hex: 0xFF8FB1)
        }
    }

    var name: String {
        switch self {
        case .lime: "Limette"
        case .sky: "Himmel"
        case .apricot: "Aprikose"
        case .lilac: "Flieder"
        case .rose: "Rosé"
        }
    }
}

enum BackgroundPreset: String, CaseIterable, Identifiable {
    case aurora, dusk, ocean, forest, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora: "Polarlicht"
        case .dusk: "Abendrot"
        case .ocean: "Ozean"
        case .forest: "Wald"
        case .graphite: "Graphit"
        }
    }

    /// 3 × 3 Farben für den Mesh-Verlauf, zeilenweise von oben links.
    var colors: [Color] { hexColors.map { Color(hex: $0) } }

    private var hexColors: [UInt32] {
        switch self {
        case .aurora:
            [0x0B1026, 0x1B2A5C, 0x0E3B43,
             0x2A1B5C, 0x1F7A6B, 0x123F7A,
             0x0B1026, 0x3A1F6B, 0x0A2A3A]
        case .dusk:
            [0x1A1030, 0x4A1F4F, 0x2B1240,
             0x8A3B4F, 0xD9775A, 0x5B2A55,
             0x1A1030, 0x6B2F45, 0x24123A]
        case .ocean:
            [0x04121F, 0x0B2E4F, 0x06283A,
             0x0E4A6E, 0x1C7FA6, 0x0B3A5C,
             0x04121F, 0x0A3550, 0x041A2A]
        case .forest:
            [0x07140F, 0x163A2A, 0x0C2219,
             0x1F4D33, 0x4F7F3A, 0x173A2C,
             0x07140F, 0x214733, 0x0A1A12]
        case .graphite:
            [0x0E0F12, 0x1B1D22, 0x121317,
             0x23262D, 0x30343C, 0x1C1F24,
             0x0E0F12, 0x1E2026, 0x0B0C0E]
        }
    }
}

/// Mitgelieferte Hintergrundbilder im Asset-Katalog.
enum Wallpaper: String, CaseIterable, Identifiable {
    case nordlicht, duenen, gebirge, tiefsee, glut

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nordlicht: "Nordlicht"
        case .duenen: "Dünen"
        case .gebirge: "Gebirge"
        case .tiefsee: "Tiefsee"
        case .glut: "Glut"
        }
    }

    var imageName: String { "wallpaper-\(rawValue)" }

    var image: UIImage? { UIImage(named: imageName) }
}

/// Was hinter allen Bildschirmen liegt.
enum BackgroundSource: Equatable {
    case photo
    case wallpaper(Wallpaper)
    case gradient(BackgroundPreset)

    static let standard = BackgroundSource.wallpaper(.nordlicht)

    init(storage: String?) {
        let parts = (storage ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "photo":
            self = .photo
        case "wallpaper":
            self = Wallpaper(rawValue: value).map { .wallpaper($0) } ?? Self.standard
        case "gradient":
            self = BackgroundPreset(rawValue: value).map { .gradient($0) } ?? Self.standard
        default:
            self = Self.standard
        }
    }

    var storage: String {
        switch self {
        case .photo: "photo"
        case .wallpaper(let wallpaper): "wallpaper:\(wallpaper.rawValue)"
        case .gradient(let preset): "gradient:\(preset.rawValue)"
        }
    }
}

/// Hintergrund (eigenes Foto, Bild oder Verlauf), Unschärfe, Abdunklung und Akzentfarbe.
@MainActor
@Observable
final class Appearance {
    private enum Keys {
        static let accent = "appearance.accent"
        static let source = "appearance.source"
        static let blur = "appearance.blur"
        static let dim = "appearance.dim"
    }

    private let defaults = UserDefaults.standard

    var accentChoice: AccentChoice {
        didSet { defaults.set(accentChoice.rawValue, forKey: Keys.accent) }
    }

    var source: BackgroundSource {
        didSet { defaults.set(source.storage, forKey: Keys.source) }
    }

    var blur: Double {
        didSet { defaults.set(blur, forKey: Keys.blur) }
    }

    var dim: Double {
        didSet { defaults.set(dim, forKey: Keys.dim) }
    }

    /// Das eigene Foto, falls eines gewählt wurde (auch wenn gerade ein anderer Hintergrund aktiv ist).
    private(set) var photo: UIImage?

    var accent: Color { accentChoice.color }

    /// Das Bild hinter der App – eigenes Foto oder mitgeliefertes Bild; `nil` bei Verläufen.
    var backgroundImage: UIImage? {
        switch source {
        case .photo: photo ?? Wallpaper.nordlicht.image
        case .wallpaper(let wallpaper): wallpaper.image
        case .gradient: nil
        }
    }

    /// Der Verlauf, falls einer gewählt ist.
    var gradient: BackgroundPreset? {
        if case .gradient(let preset) = source { return preset }
        return nil
    }

    init() {
        accentChoice = AccentChoice(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .lime
        source = BackgroundSource(storage: defaults.string(forKey: Keys.source))
        blur = defaults.object(forKey: Keys.blur) as? Double ?? 0
        dim = defaults.object(forKey: Keys.dim) as? Double ?? 0.25
        photo = UIImage(contentsOfFile: Self.photoURL.path)
        if source == .photo && photo == nil { source = .standard }
    }

    /// Speichert ein ausgewähltes Foto verkleinert im App-Speicher und zeigt es an.
    func setPhoto(data: Data) -> Bool {
        guard let original = UIImage(data: data) else { return false }
        let scaled = Self.downscaled(original, maxPixels: 2400)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.88) else { return false }
        do {
            try jpeg.write(to: Self.photoURL, options: .atomic)
        } catch {
            return false
        }
        photo = scaled
        source = .photo
        return true
    }

    func removePhoto() {
        try? FileManager.default.removeItem(at: Self.photoURL)
        photo = nil
        if source == .photo { source = .standard }
    }

    func reset() {
        accentChoice = .lime
        source = .standard
        blur = 0
        dim = 0.25
    }

    private static var photoURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hintergrund.jpg")
    }

    private static func downscaled(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        let factor = longest > maxPixels ? maxPixels / longest : 1
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        // Neu zeichnen normalisiert auch die Ausrichtung (HEIC-Fotos sind oft gedreht gespeichert).
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
