import AppKit

/// The process-termination boundary used by UI entry points. Keeping it as a
/// small injected command lets tests exercise Quit without terminating their
/// own host process.
@MainActor
struct ApplicationQuitAction {
    static let title = "Quit Quotakin"
    static let systemImage = "power"
    static let accessibilityHint = "Closes Quotakin and removes it from the menu bar"

    private let terminate: @MainActor () -> Void

    init(terminate: @escaping @MainActor () -> Void) {
        self.terminate = terminate
    }

    func callAsFunction() {
        terminate()
    }

    static let live = ApplicationQuitAction {
        NSApplication.shared.terminate(nil)
    }
}
