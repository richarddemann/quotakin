import SwiftUI
import UsageCore

/// Centered visual chooser presented from Settings. A grid gives every pet
/// enough room to be recognizable and avoids the narrow, scrolling menu that
/// an anchored popover becomes as the catalog grows.
///
/// Selection state and mutation both go through `PetSettingsPresentation`, so
/// behavior matches the existing picker exactly:
/// - current selection ← `renderedSelection(...)` (unknown/absent → Automatic)
/// - a tap ← `preferences(_:setting:for:)`, handed back via `onSelect`.
///
/// The parent owns preferences; this view is stateless and reduce-motion
/// friendly (static thumbnails, no animation).
struct PetSelectorView: View {
    let provider: Provider
    let preferences: UserPreferences
    let onCancel: () -> Void
    /// Called with the updated preferences when the user picks a row. The
    /// parent is responsible for persisting them (e.g. `model.preferences = …`).
    let onSelect: (UserPreferences) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Space.s),
        count: 4
    )

    private var presentation: PetSettingsPresentation {
        PetSettingsPresentation(packs: PetAssets.availablePacks)
    }

    private var selectedID: String? {
        PetSettingsPresentation.renderedSelection(
            for: provider,
            preferences: preferences,
            availablePackIDs: presentation.availablePackIDs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .center, spacing: Space.s) {
                    ForEach(presentation.pickerOptions) { option in
                        card(for: option)
                    }
                }
                .padding(Space.m)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .frame(width: 500, height: 410)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) pet")
    }

    @ViewBuilder
    private func card(for option: PetSettingsPresentation.PickerOption) -> some View {
        let isSelected = option.selectionID == selectedID

        Button {
            onSelect(
                PetSettingsPresentation.preferences(
                    preferences,
                    setting: option.selectionID,
                    for: provider
                )
            )
        } label: {
            VStack(spacing: Space.xs) {
                ZStack(alignment: .topTrailing) {
                    leadingGlyph(for: option)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)

                Text(option.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .padding(Space.xs)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func leadingGlyph(for option: PetSettingsPresentation.PickerOption) -> some View {
        if let packID = option.selectionID {
            PetThumbnail(packID: packID, size: CGSize(width: 68, height: 72))
        } else {
            AutomaticPetGlyph(size: CGSize(width: 68, height: 72))
        }
    }
}

struct AutomaticPetGlyph: View {
    var size = CGSize(width: 34, height: 37)

    var body: some View {
        // "Automatic" has no single sprite; a wand reads as "pick for me".
        Image(systemName: "wand.and.stars")
            .font(.system(size: min(size.width, size.height) * 0.48))
            .foregroundStyle(.secondary)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

#Preview("PetSelectorView") {
    struct PreviewHost: View {
        @State private var preferences = UserPreferences(petModeEnabled: true)

        var body: some View {
            PetSelectorView(provider: .claude, preferences: preferences, onCancel: {}) { updated in
                preferences = updated
            }
        }
    }

    return PreviewHost()
}
