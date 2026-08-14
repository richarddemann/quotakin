import SwiftUI
import UsageCore

struct PetSelectorButton: View {
    let provider: Provider
    let preferences: UserPreferences
    let onOpen: () -> Void

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

    private var selectedOption: PetSettingsPresentation.PickerOption {
        presentation.pickerOptions.first { $0.selectionID == selectedID }
            ?? PetSettingsPresentation.automaticOption
    }

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: Space.xs) {
                selectedGlyph

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(provider.displayName)
                        .foregroundStyle(.secondary)
                    Text(selectedOption.title)
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: Space.xs)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName) pet")
        .accessibilityValue(selectedOption.title)
    }

    @ViewBuilder
    private var selectedGlyph: some View {
        if let selectedID {
            PetThumbnail(packID: selectedID)
        } else {
            AutomaticPetGlyph()
        }
    }
}
