import AppKit
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
}

@Test
func settingsTabsPinTheirWidthWhileRemainingVerticallyResizable() {
    #expect(SettingsLayout.windowWidth == 560)
    #expect(SettingsLayout.minimumWindowWidth == 560)
    #expect(SettingsLayout.maximumWindowWidth == 560)
    #expect(SettingsLayout.minimumHeight == 560)
    #expect(SettingsLayout.maximumHeight.isInfinite)
}

@Test @MainActor
func closingSettingsDoesNotTerminateMenuBarApp() {
    #expect(!QuotakinAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}
