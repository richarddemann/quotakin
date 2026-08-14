import Foundation

enum OnboardingLaunchDecision: Equatable {
    case newInstall
    case incomplete
    case existingInstall
    case completed

    static let startedKey = "UsageBar.OnboardingStarted.v1"
    static let completionKey = "UsageBar.OnboardingCompleted.v1"

    private static let existingInstallEvidenceKeys = [
        "UsageBar.UserPreferences.v1",
        "UsageBar.MenuBarMetricOrder.v1",
        "UsageBar.NotificationState.v1"
    ]

    var shouldPresentAutomatically: Bool {
        self == .newInstall || self == .incomplete
    }

    static func evaluate(defaults: UserDefaults) -> OnboardingLaunchDecision {
        if defaults.bool(forKey: completionKey) {
            return .completed
        }
        if defaults.bool(forKey: startedKey) {
            return .incomplete
        }
        if existingInstallEvidenceKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            return .existingInstall
        }
        return .newInstall
    }
}
