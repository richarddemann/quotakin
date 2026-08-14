import Foundation
import UsageCore
import UserNotifications

enum NotificationAuthorizationState: Equatable {
    case allowed
    case notRequested
    case blocked
    case unknown
}

@MainActor
protocol QuotaNotificationPosting {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async
    func post(_ notifications: [QuotaNotification]) async -> Bool
}

@MainActor
final class UserNotificationsQuotaPoster: QuotaNotificationPosting {
    private let center: UNUserNotificationCenter
    private var requestedAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.authorizationState(for: settings.authorizationStatus)
    }

    static func authorizationState(for status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            .allowed
        case .notDetermined:
            .notRequested
        case .denied:
            .blocked
        @unknown default:
            .unknown
        }
    }

    func requestAuthorization() async {
        await requestAuthorizationIfNeeded()
    }

    func post(_ notifications: [QuotaNotification]) async -> Bool {
        guard !notifications.isEmpty else {
            return true
        }

        let settings = await center.notificationSettings()
        guard Self.authorizationState(for: settings.authorizationStatus) == .allowed else {
            return false
        }

        for notification in notifications {
            let request = UNNotificationRequest(
                identifier: identifier(for: notification),
                content: content(for: notification),
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                return false
            }
        }
        return true
    }

    private func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization else {
            return
        }
        requestedAuthorization = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func identifier(for notification: QuotaNotification) -> String {
        let payload = notification.payload
        let reset = Int(payload.resetsAt.timeIntervalSince1970)
        switch notification {
        case .thresholdCrossed(_, let threshold):
            return "quota.threshold.\(payload.provider.rawValue).\(payload.window.rawValue).\(threshold).\(reset)"
        case .windowReset:
            return "quota.reset.\(payload.provider.rawValue).\(payload.window.rawValue).\(reset)"
        case .atRiskPrediction:
            return "quota.prediction.\(payload.provider.rawValue).\(payload.window.rawValue).\(reset)"
        }
    }

    private func content(for notification: QuotaNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let payload = notification.payload
        switch notification {
        case .thresholdCrossed(_, let threshold):
            content.title = "\(providerName(payload.provider)) \(windowName(payload.window)) quota"
            content.body = "\(percent(payload.usedPercent)) used crossed \(percent(threshold)). Resets \(resetText(payload.resetsAt))."
        case .windowReset:
            content.title = "\(providerName(payload.provider)) \(windowName(payload.window)) quota reset"
            content.body = "Usage is \(percent(payload.usedPercent)) in the new window."
        case .atRiskPrediction(_, let projectedAt):
            content.title = "\(providerName(payload.provider)) \(windowName(payload.window)) quota at risk"
            content.body = "On pace to hit the limit around \(timeText(projectedAt)). Resets \(resetText(payload.resetsAt))."
        }
        return content
    }

    private func providerName(_ provider: Provider) -> String {
        switch provider {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    private func windowName(_ window: QuotaWindow) -> String {
        switch window {
        case .session:
            "session"
        case .weekly:
            "weekly"
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func resetText(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
