import AppKit

/// Brings the app's auxiliary windows (Settings, and — when re-enabled in
/// v0.2 — History) reliably to the front, above whatever app is currently
/// frontmost.
///
/// This app is `LSUIElement`/accessory, and an accessory app can't raise a
/// window above another app just by ordering it front — `activate` is a no-op
/// for a policy-`.accessory` app. So on open we briefly promote the app to
/// `.regular` (which makes activation work, at the cost of a temporary Dock
/// icon), then demote back to `.accessory` once the last auxiliary window
/// closes, so the Dock icon doesn't linger.
///
/// Two windows use this: History via `bringForward(title:)` (stable NSWindow
/// title) and Settings via `present()` — the Settings window's title tracks
/// the selected pane, so it's resolved structurally instead of by a fixed name.
enum WindowFocus {
    /// Present the Settings window (or any single auxiliary content window).
    @MainActor
    static func present() {
        promoteAndFront(matchingTitle: nil, attemptsRemaining: 12)
    }

    /// Present a window with a known, stable title (History).
    @MainActor
    static func bringForward(title: String) {
        promoteAndFront(matchingTitle: title, attemptsRemaining: 12)
    }

    static func centeredFrame(windowSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(windowSize.width, visibleFrame.width * 0.9)
        let height = min(windowSize.height, visibleFrame.height * 0.9)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    @MainActor
    private static func promoteAndFront(matchingTitle: String?, attemptsRemaining: Int) {
        installCloseObserverIfNeeded()
        // Promote out of accessory so `activate` can rise above other apps.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        front(matchingTitle: matchingTitle, attemptsRemaining: attemptsRemaining)
    }

    @MainActor
    private static func front(matchingTitle: String?, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay(for: attemptsRemaining)) {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = targetWindow(matchingTitle: matchingTitle) else {
                if attemptsRemaining > 0 {
                    front(matchingTitle: matchingTitle, attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }

            window.collectionBehavior.insert(.moveToActiveSpace)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.setFrame(
                centeredFrame(
                    windowSize: window.frame.size,
                    visibleFrame: activeScreenVisibleFrame()
                ),
                display: true
            )
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The window to raise. Prefer an exact title match (History); otherwise the
    /// frontmost titled "content" window — which, right after `openSettings()`,
    /// is the Settings window. The menu-bar popover is a borderless panel and is
    /// excluded because it lacks `.titled`.
    @MainActor
    private static func targetWindow(matchingTitle: String?) -> NSWindow? {
        if let matchingTitle,
           let match = NSApp.windows.first(where: { $0.title == matchingTitle && isContentWindow($0) }) {
            return match
        }
        return NSApp.orderedWindows.first(where: isContentWindow)
            ?? NSApp.windows.first(where: isContentWindow)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.styleMask.contains(.titled)
            && !window.styleMask.contains(.hudWindow)
    }

    // MARK: - Demote back to accessory when the last window closes

    @MainActor
    private static var closeObserver: (any NSObjectProtocol)?

    @MainActor
    private static func installCloseObserverIfNeeded() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Defer past the close so the departing window is no longer visible,
            // then drop the Dock icon if nothing auxiliary remains open.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                if !hasVisibleContentWindow(), NSApp.activationPolicy() != .accessory {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    @MainActor
    private static func hasVisibleContentWindow() -> Bool {
        NSApp.windows.contains { isContentWindow($0) && !$0.isMiniaturized }
    }

    private static func retryDelay(for attemptsRemaining: Int) -> TimeInterval {
        attemptsRemaining == 12 ? 0.02 : 0.08
    }

    @MainActor
    private static func activeScreenVisibleFrame() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens
            .first { $0.frame.contains(mouseLocation) }?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 900, height: 700)
    }
}
