import PhotosUI
import SwiftUI

/// Eigenes Hintergrundbild, Verläufe, Unschärfe, Abdunklung und Akzentfarbe – mit Live-Vorschau.
struct AppearanceView: View {
    @Environment(Appearance.self) private var appearance
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoError: String?

    var body: some View {
        @Bindable var appearance = appearance
        let hasPhoto = appearance.photo != nil
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                preview

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Hintergrundbild")
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HStack(spacing: 8) {
                            if isLoadingPhoto {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "photo.on.rectangle")
                            }
                            Text(hasPhoto ? "Anderes Foto wählen" : "Eigenes Foto wählen")
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(.tint, in: Capsule())
                    }
                    .disabled(isLoadingPhoto)

                    if let photoError {
                        NoticeBanner(text: photoError)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        if let photo = appearance.photo {
                            Swatch(title: "Mein Foto", isSelected: appearance.usesPhoto) {
                                appearance.usesPhoto = true
                            } content: {
                                Image(uiImage: photo).resizable().scaledToFill()
                            }
                        }
                        ForEach(BackgroundPreset.allCases) { preset in
                            Swatch(title: preset.name, isSelected: !appearance.usesPhoto && appearance.preset == preset) {
                                appearance.selectPreset(preset)
                            } content: {
                                PresetBackground(preset: preset)
                            }
                        }
                    }

                    if appearance.photo != nil {
                        Button(role: .destructive) {
                            withAnimation { appearance.removePhoto() }
                        } label: {
                            Label("Foto entfernen", systemImage: "trash")
                        }
                        .buttonStyle(GlassButtonStyle(foreground: .danger))
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Wirkung")
                    VStack(spacing: 18) {
                        SliderRow(title: "Unschärfe", symbol: "drop.halffull", value: $appearance.blur, range: 0...40, display: "\(Int(appearance.blur))")
                            .disabled(!appearance.usesPhoto)
                            .opacity(appearance.usesPhoto ? 1 : 0.45)
                        SliderRow(title: "Abdunkeln", symbol: "circle.lefthalf.filled", value: $appearance.dim, range: 0...0.8, display: "\(Int(appearance.dim * 100)) %")
                    }
                    .padding(18)
                    .glassCard(radius: 22)
                }

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
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.name)
                            .accessibilityAddTraits(choice == appearance.accentChoice ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                    .glassCard(radius: 22)
                }

                Button("Auf Standard zurücksetzen") {
                    withAnimation { appearance.reset() }
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
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    /// Eine Mini-Karte, an der man Lesbarkeit und Wirkung direkt sieht.
    private var preview: some View {
        HStack(spacing: 14) {
            HubMark(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("So wirkt dein Hub")
                    .font(.headline)
                Text("Hintergrund, Glas und Akzent ändern sich live.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .glassCard()
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer {
            isLoadingPhoto = false
            pickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), appearance.setPhoto(data: data) else {
                photoError = "Dieses Foto konnte nicht geladen werden."
                return
            }
        } catch {
            photoError = "Dieses Foto konnte nicht geladen werden."
        }
    }
}

private struct Swatch<Content: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Color.clear
                    .frame(height: 120)
                    .overlay { content }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.15)), lineWidth: isSelected ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.black, TintShapeStyle())
                                .padding(8)
                        }
                    }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SliderRow: View {
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
