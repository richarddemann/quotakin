import Foundation
import UsageCore

struct PetSettingsPresentation {
    struct PickerOption: Equatable, Identifiable {
        let id: String
        let selectionID: String?
        let title: String
    }

    static let automaticOptionID = "__automatic__"

    let packs: [PetAssets.PackSummary]

    var pickerOptions: [PickerOption] {
        [Self.automaticOption] + packs.map {
            PickerOption(id: $0.id, selectionID: $0.id, title: $0.displayName)
        }
    }

    var availablePackIDs: [String] {
        packs.map(\.id)
    }

    static var automaticOption: PickerOption {
        PickerOption(id: automaticOptionID, selectionID: nil, title: "Automatic")
    }

    static func renderedSelection(
        for provider: Provider,
        preferences: UserPreferences,
        availablePackIDs: [String]
    ) -> String? {
        guard let selectedID = preferences.petSelection[provider],
              availablePackIDs.contains(selectedID)
        else {
            return nil
        }
        return selectedID
    }

    static func preferences(
        _ preferences: UserPreferences,
        setting selectionID: String?,
        for provider: Provider
    ) -> UserPreferences {
        var updated = preferences
        if let selectionID {
            updated.petSelection[provider] = selectionID
        } else {
            updated.petSelection.removeValue(forKey: provider)
        }
        return updated
    }
}
