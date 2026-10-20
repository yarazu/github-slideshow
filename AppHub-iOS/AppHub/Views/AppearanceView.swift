import PhotosUI
import SwiftUI

/// Hintergrundbilder, eigenes Foto, Verläufe, Unschärfe, Abdunklung und Akzentfarbe – mit Live-Vorschau.
struct AppearanceView: View {
    @Environment(Appearance.self) private var appearance
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoError: String?

    private let portraitColumns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AppearancePreview()
                wallpapers
                photoSection
                gradients
                AppearanceEffectsCard()
                accent
                Button("Auf Standard zurücksetzen") {
                    withAnimation(.easeInOut(duration: 0.35)) { appearance.reset() }
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { HubBackground() }
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: appearance.accentChoice)
        .sensoryFeedback(.selection, trigger: appearance.source)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    // MARK: Abschnitte

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Bilder", trailing: currentWallpaper?.name)
            LazyVGrid(columns: portraitColumns, spacing: 14) {
                ForEach(Wallpaper.allCases) { wallpaper in
                    AppearanceSwatch(title: wallpaper.name, isSelected: appearance.source == .wallpaper(wallpaper)) {
                        select(.wallpaper(wallpaper))
                    } content: {
                        Image(wallpaper.imageName)
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Eigenes Foto")
            HStack(alignment: .center, spacing: 14) {
                if let photo = appearance.photo {
                    AppearanceSwatch(title: "Mein Foto", isSelected: appearance.source == .photo) {
                        select(.photo)
                    } content: {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    }
                    .frame(width: 104)
                }
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HStack(spacing: 8) {
                            if isLoadingPhoto {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "photo.on.rectangle")
                            }
                            Text(appearance.photo == nil ? "Foto wählen" : "Anderes Foto")
                        }
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(.tint, in: Capsule())
                    }
                    .disabled(isLoadingPhoto)

                    if appearance.photo != nil {
                        Button(role: .destructive) {
                            withAnimation { appearance.removePhoto() }
                        } label: {
                            Label("Foto entfernen", systemImage: "trash")
                        }
                        .buttonStyle(GlassButtonStyle(foreground: .danger))
                    } else {
                        Text("Ein Bild aus deiner Mediathek – es bleibt nur auf diesem iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let photoError {
                NoticeBanner(text: photoError)
            }
        }
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Verläufe", trailing: appearance.gradient?.name)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 14) {
                ForEach(BackgroundPreset.allCases) { preset in
                    AppearanceSwatch(title: preset.name, isSelected: appearance.source == .gradient(preset), ratio: 1, radius: 16) {
                        select(.gradient(preset))
                    } content: {
                        PresetBackground(preset: preset)
                    }
                }
            }
        }
    }

    private var accent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Akzentfarbe", trailing: appearance.accentChoice.name)
            HStack(spacing: 0) {
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        withAnimation(.snappy) { appearance.accentChoice = choice }
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 36, height: 36)
                            .padding(4)
                            .overlay {
                                Circle()
                                    .stroke(choice == appearance.accentChoice ? Color.white : Color.clear, lineWidth: 2.5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(choice == appearance.accentChoice ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .glassCard(radius: 24)
        }
    }

    // MARK: Aktionen

    private var currentWallpaper: Wallpaper? {
        if case .wallpaper(let wallpaper) = appearance.source { return wallpaper }
        return nil
    }

    private func select(_ source: BackgroundSource) {
        withAnimation(.easeInOut(duration: 0.35)) {
            appearance.source = source
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer {
            isLoadingPhoto = false
            pickerItem = nil
        }
        do {
            let data = try await item.loadTransferable(type: Data.self)
            guard let data, appearance.setPhoto(data: data) else {
                photoError = "Dieses Foto konnte nicht geladen werden."
                return
            }
        } catch {
            photoError = "Dieses Foto konnte nicht geladen werden."
        }
    }
}

// MARK: - Vorschau

/// Mini-Startseite im Rahmen: Bild, Glas und Akzent ändern sich live.
private struct AppearancePreview: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HubMark(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("So wirkt Orbit")
                            .font(.system(.headline, design: .rounded))
                        Text("Hintergrund, Glas und Akzent ändern sich live.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 64, height: 8)
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 8)
                }
            }
            .padding(16)
            .glassCard(radius: 22)
            .padding(14)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var backdrop: some View {
        Color.clear
            .overlay {
                if let image = appearance.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: appearance.blur * 0.5, opaque: true)
                } else {
                    PresetBackground(preset: appearance.gradient ?? .aurora)
                }
            }
            .overlay {
                Color.black.opacity(appearance.dim)
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

// MARK: - Bausteine

/// Wählbare Kachel mit Vorschau, Titel und Häkchen.
private struct AppearanceSwatch<Content: View>: View {
    let title: String
    let isSelected: Bool
    let ratio: CGFloat
    let radius: CGFloat
    let action: () -> Void
    let content: Content

    init(title: String, isSelected: Bool, ratio: CGFloat = 0.56, radius: CGFloat = 20, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isSelected = isSelected
        self.ratio = ratio
        self.radius = radius
        self.action = action
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { content }
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.16)),
                            lineWidth: isSelected ? 3 : 1
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.black, TintShapeStyle())
                                .padding(7)
                        }
                    }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Regler für Unschärfe und Abdunklung.
private struct AppearanceEffectsCard: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        let hasImage = appearance.backgroundImage != nil
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Wirkung")
            VStack(spacing: 18) {
                AppearanceSliderRow(title: "Unschärfe", symbol: "drop.halffull", value: $appearance.blur, range: 0...40, display: "\(Int(appearance.blur))")
                    .disabled(!hasImage)
                    .opacity(hasImage ? 1 : 0.45)
                AppearanceSliderRow(title: "Abdunkeln", symbol: "circle.lefthalf.filled", value: $appearance.dim, range: 0...0.8, display: "\(Int(appearance.dim * 100)) %")
            }
            .padding(18)
            .glassCard(radius: 24)
        }
    }
}

private struct AppearanceSliderRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(display)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }
}
