import AppKit
import Foundation

/// Single source of truth for the "Report a Bug…" action. Builds a prefilled
/// GitHub issue with app and system versions and opens it in the browser, so
/// every entry point (Settings, popover footer) opens the same issue.
enum BugReporter {
    @MainActor
    static func openPrefilledIssue() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        **What happened?**

        **What did you expect?**

        ---
        Quotakin \(appVersion) · macOS \(osVersion)
        """
        var components = URLComponents(string: "https://github.com/richarddemann/quotakin/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
