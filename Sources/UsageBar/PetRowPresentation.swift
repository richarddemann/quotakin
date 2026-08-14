import CoreGraphics
import Foundation
import UsageCore

struct PetRowPresentation {
    let isEnabled: Bool
    let hasPack: Bool
    let layout: ProviderCardPresentation.Layout

    init(isEnabled: Bool, pack: PetPack?, layout: ProviderCardPresentation.Layout) {
        self.init(isEnabled: isEnabled, hasPack: pack != nil, layout: layout)
    }

    init(isEnabled: Bool, hasPack: Bool, layout: ProviderCardPresentation.Layout) {
        self.isEnabled = isEnabled
        self.hasPack = hasPack
        self.layout = layout
    }

    var shouldRenderPetRow: Bool {
        isEnabled && hasPack && layout == .quotaGlance
    }

    static func resolvedPack(
        for provider: Provider,
        preferences: UserPreferences,
        availablePacks: [PetPack]
    ) -> PetPack? {
        guard let id = resolvedPackID(
            for: provider,
            preferences: preferences,
            availablePackIDs: availablePacks.map(\.id)
        ) else {
            return nil
        }
        return availablePacks.first { $0.id == id }
    }

    static func resolvedPackID(
        for provider: Provider,
        preferences: UserPreferences,
        availablePackIDs: [String]
    ) -> String? {
        if let selectedID = preferences.petSelection[provider],
           availablePackIDs.contains(selectedID) {
            return selectedID
        }

        let providerDefaultID: String = switch provider {
        case .claude: "dewey"
        case .codex: "codex"
        }
        if availablePackIDs.contains(providerDefaultID) {
            return providerDefaultID
        }
        return availablePackIDs.first
    }

    static func xOffset(
        trackWidth: CGFloat,
        petWidth: CGFloat,
        xPositionFraction: Double,
        remainingFraction: Double
    ) -> CGFloat {
        let availableWidth = max(trackWidth - petWidth, 0)
        let clampedRemaining = min(max(remainingFraction, 0), 1)
        let clampedPosition = min(max(xPositionFraction, 0), clampedRemaining)
        return availableWidth * CGFloat(clampedPosition)
    }

    static func reducedMotionXPositionFraction(remainingFraction: Double) -> Double {
        min(max(remainingFraction, 0), 0.05)
    }
}
