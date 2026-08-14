import CoreGraphics
import Testing
import UsageCore
@testable import UsageBar

@Test
func petSettingsOptionsStartWithAutomaticThenDiscoveredPacksInOrder() {
    let presentation = PetSettingsPresentation(packs: [
        PetAssets.PackSummary(id: "calico", displayName: "Calico"),
        PetAssets.PackSummary(id: "cloudling", displayName: "Cloudling")
    ])

    #expect(presentation.pickerOptions.map(\.title) == ["Automatic", "Calico", "Cloudling"])
    #expect(presentation.pickerOptions.map(\.selectionID) == [nil, "calico", "cloudling"])
}

@Test
func selectingAutomaticRemovesProviderSelection() {
    let preferences = UserPreferences(
        petModeEnabled: true,
        petSelection: [.claude: "calico", .codex: "cloudling"]
    )

    let updated = PetSettingsPresentation.preferences(
        preferences,
        setting: nil,
        for: .claude
    )

    #expect(updated.petSelection[.claude] == nil)
    #expect(updated.petSelection[.codex] == "cloudling")
}

@Test
func selectingPackStoresProviderSelection() {
    let preferences = UserPreferences(petModeEnabled: true)

    let updated = PetSettingsPresentation.preferences(
        preferences,
        setting: "cloudling",
        for: .codex
    )

    #expect(updated.petSelection[.codex] == "cloudling")
}

@Test
func unknownStoredSelectionRendersAsAutomatic() {
    let preferences = UserPreferences(
        petModeEnabled: true,
        petSelection: [.claude: "missing"]
    )

    let selection = PetSettingsPresentation.renderedSelection(
        for: .claude,
        preferences: preferences,
        availablePackIDs: ["calico", "cloudling"]
    )

    #expect(selection == nil)
}

@Test
func unknownPackIDResolvesToNilWithoutCrashing() {
    // The additive by-id accessors backing PetThumbnail must be total: an
    // unknown id yields nil (→ placeholder) rather than trapping.
    #expect(PetAssets.pack(withID: "__definitely_not_a_real_pack__") == nil)
    #expect(PetAssets.spritesheetImage(forPackID: "__definitely_not_a_real_pack__") == nil)
}

@Test
func availablePackIDsResolveToTheSamePack() {
    // Every advertised pack id must resolve back through the by-id lookup, so
    // the selector's thumbnails and the picker's options stay in sync.
    for summary in PetAssets.availablePacks {
        #expect(PetAssets.pack(withID: summary.id)?.id == summary.id)
    }
}

@Test
func allOfficialCodexPetsAreBundledAndLoadable() {
    let officialIDs: Set<String> = [
        "codex", "dewey", "fireball", "rocky", "seedy", "stacky", "bsod", "null-signal"
    ]

    #expect(officialIDs.isSubset(of: Set(PetAssets.availablePacks.map(\.id))))
    for id in officialIDs {
        #expect(PetAssets.pack(withID: id) != nil)
        #expect(PetAssets.spritesheetImage(forPackID: id) != nil)
    }
}

@Test
func petThumbnailUsesTheFirstDeclaredIdleFrameAndCustomGrid() {
    let manifest = PetManifest(
        frame: .init(width: 384, height: 208, columns: 4, rows: 9),
        animations: ["idle": .init(frames: [5])]
    )

    #expect(
        PetThumbnailPresentation.sourceRect(for: manifest)
            == CGRect(x: 384, y: 208, width: 384, height: 208)
    )
}
