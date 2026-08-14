import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func automaticPetSelectionUsesProviderDefaultsWhenOfficialPacksAreAvailable() {
    let available = ["bsod", "codex", "dewey", "fireball"]

    #expect(PetRowPresentation.resolvedPackID(
        for: .claude,
        preferences: .default,
        availablePackIDs: available
    ) == "dewey")
    #expect(PetRowPresentation.resolvedPackID(
        for: .codex,
        preferences: .default,
        availablePackIDs: available
    ) == "codex")
}

@Test
func petRowShowsOnlyWhenEnabledWithPackAndQuotaLayout() {
    #expect(PetRowPresentation(isEnabled: true, hasPack: true, layout: .quotaGlance).shouldRenderPetRow)
    #expect(!PetRowPresentation(isEnabled: false, hasPack: true, layout: .quotaGlance).shouldRenderPetRow)
    #expect(!PetRowPresentation(isEnabled: true, hasPack: false, layout: .quotaGlance).shouldRenderPetRow)
    #expect(!PetRowPresentation(isEnabled: true, hasPack: true, layout: .compactUnavailable).shouldRenderPetRow)
}

@Test
func selectedPetResolvesBeforeFirstAvailablePack() {
    let preferences = UserPreferences(
        petModeEnabled: true,
        petSelection: [.claude: "selected"]
    )

    let resolved = PetRowPresentation.resolvedPackID(
        for: .claude,
        preferences: preferences,
        availablePackIDs: ["first", "selected"]
    )

    #expect(resolved == "selected")
}

@Test
func missingSelectionFallsBackToFirstAvailablePackThenNil() {
    let preferences = UserPreferences(
        petModeEnabled: true,
        petSelection: [.claude: "missing"]
    )

    let fallback = PetRowPresentation.resolvedPackID(
        for: .claude,
        preferences: preferences,
        availablePackIDs: ["first"]
    )
    let empty = PetRowPresentation.resolvedPackID(
        for: .claude,
        preferences: preferences,
        availablePackIDs: []
    )

    #expect(fallback == "first")
    #expect(empty == nil)
}

@Test
func xOffsetClampsToRemainingFractionAndAvailableWidth() {
    #expect(PetRowPresentation.xOffset(
        trackWidth: 120,
        petWidth: 20,
        xPositionFraction: 0.5,
        remainingFraction: 0.8
    ) == 50)
    #expect(PetRowPresentation.xOffset(
        trackWidth: 120,
        petWidth: 20,
        xPositionFraction: 0.9,
        remainingFraction: 0.4
    ) == 40)
    #expect(PetRowPresentation.xOffset(
        trackWidth: 120,
        petWidth: 20,
        xPositionFraction: -0.2,
        remainingFraction: 0.4
    ) == 0)
    #expect(PetRowPresentation.xOffset(
        trackWidth: 10,
        petWidth: 20,
        xPositionFraction: 0.5,
        remainingFraction: 1
    ) == 0)
}

// Reset-celebration detection moved to UsageCore's QuotaResetDetector (model
// level, so it fires even when the popover is closed) — see
// QuotaResetDetectorTests.
