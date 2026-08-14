import Testing
@testable import UsageBar

@Test
func settingsDestinationsFollowUserGoals() {
    #expect(SettingsDestination.allCases == [
        .display,
        .alerts,
        .connections,
        .advanced
    ])
    #expect(SettingsDestination.defaultDestination == .display)
    #expect(SettingsDestination.allCases.map(\.title) == [
        "Display",
        "Alerts",
        "Connections",
        "Advanced"
    ])
    #expect(SettingsDestination.allCases.map(\.subtitle) == [
        "Choose what appears in the menu bar and how Quotakin looks.",
        "Choose when Quotakin should get your attention.",
        "Connect the providers you use and keep account quota current.",
        "Manage refresh timing, revisit setup, and find support."
    ])
}

@Test
func settingsDestinationsHaveAccessiblePresentationMetadata() {
    for destination in SettingsDestination.allCases {
        #expect(!destination.title.isEmpty)
        #expect(!destination.subtitle.isEmpty)
        #expect(!destination.systemImage.isEmpty)
    }
}

@Test
func settingsTabsPinTheirWidthWhileRemainingVerticallyResizable() {
    #expect(SettingsLayout.windowWidth == 560)
    #expect(SettingsLayout.minimumWindowWidth == 560)
    #expect(SettingsLayout.maximumWindowWidth == 560)
    #expect(SettingsLayout.minimumHeight == 560)
    #expect(SettingsLayout.maximumHeight.isInfinite)
}
