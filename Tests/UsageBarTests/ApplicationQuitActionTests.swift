import Testing
@testable import UsageBar

@Test @MainActor
func quitActionUsesNativePresentationAndInvokesInjectedTermination() {
    var didTerminate = false
    let action = ApplicationQuitAction {
        didTerminate = true
    }

    #expect(ApplicationQuitAction.title == "Quit Quotakin")
    #expect(ApplicationQuitAction.systemImage == "power")
    #expect(ApplicationQuitAction.accessibilityHint == "Closes Quotakin and removes it from the menu bar")

    action()

    #expect(didTerminate)
}
