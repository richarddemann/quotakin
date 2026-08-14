import Foundation
import Testing
import UserNotifications
@testable import UsageBar
@testable import UsageCore

private let now = Date(timeIntervalSince1970: 10_000)

private func snapshot(
    usedPercent: Double,
    resetsAt: Date = Date(timeIntervalSince1970: 20_000)
) -> QuotaSnapshot {
    QuotaSnapshot(
        provider: .claude,
        window: .session,
        source: .account,
        usedPercent: usedPercent,
        resetsAt: resetsAt,
        observedAt: now
    )
}

@Test @MainActor
func permissionDeniedDeliveryDoesNotAdvanceFiredState() {
    let initialState = QuotaNotificationPolicyState()
    let deniedDecision = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 49)],
        currentSnapshots: [snapshot(usedPercent: 51)],
        predictions: [],
        preferences: QuotaNotificationPreferences(
            enabledKinds: [.thresholdCrossed],
            thresholdsByWindow: [.session: [50]]
        ),
        state: initialState,
        now: now
    )

    let stateAfterDeniedDelivery = AppModel.committedNotificationPolicyState(
        currentState: initialState,
        decision: deniedDecision,
        notificationsDelivered: false
    )
    let advancesSnapshotsAfterDeniedDelivery = AppModel.shouldAdvanceNotificationTracking(
        notifications: deniedDecision.notifications,
        notificationsDelivered: false
    )

    #expect(stateAfterDeniedDelivery == initialState)
    #expect(!advancesSnapshotsAfterDeniedDelivery)

    let authorizedDecision = QuotaNotificationPolicy.decide(
        previousSnapshots: advancesSnapshotsAfterDeniedDelivery
            ? [snapshot(usedPercent: 51)]
            : [snapshot(usedPercent: 49)],
        currentSnapshots: [snapshot(usedPercent: 51)],
        predictions: [],
        preferences: QuotaNotificationPreferences(
            enabledKinds: [.thresholdCrossed],
            thresholdsByWindow: [.session: [50]]
        ),
        state: stateAfterDeniedDelivery,
        now: now
    )

    #expect(authorizedDecision.notifications == deniedDecision.notifications)
}

@Test @MainActor
func systemAuthorizationStatusesMapToExposedStates() {
    #expect(UserNotificationsQuotaPoster.authorizationState(for: .authorized) == .allowed)
    #expect(UserNotificationsQuotaPoster.authorizationState(for: .provisional) == .allowed)
    #expect(UserNotificationsQuotaPoster.authorizationState(for: .notDetermined) == .notRequested)
    #expect(UserNotificationsQuotaPoster.authorizationState(for: .denied) == .blocked)
}

@Test @MainActor
func thresholdAlertsStartWithUsefulNonNoisyDefaults() {
    #expect(NotificationsSettingsPane.defaultThresholds == [75, 90])
}

@Test @MainActor
func authorizationRefreshPublishesPosterState() async {
    let poster = NotificationPosterDouble(authorizationState: .blocked)
    let model = makeModel(notificationPoster: poster)

    #expect(model.notificationAuthorizationState == .unknown)

    await model.refreshNotificationAuthorizationState()

    #expect(model.notificationAuthorizationState == .blocked)
    #expect(poster.authorizationStateCallCount == 1)
}

@Test @MainActor
func enablingFirstAlertRequestsAuthorizationAndRefreshesState() async {
    let poster = NotificationPosterDouble(authorizationState: .allowed)
    let model = makeModel(notificationPoster: poster)

    model.preferences.notificationPreferences.enabledKinds = [.thresholdCrossed]
    await waitUntil { poster.requestAuthorizationCallCount == 1 }

    #expect(poster.requestAuthorizationCallCount == 1)
    #expect(poster.authorizationStateCallCount == 1)
    #expect(model.notificationAuthorizationState == .allowed)

    model.preferences.notificationPreferences.enabledKinds.append(.windowReset)
    await Task.yield()

    #expect(poster.requestAuthorizationCallCount == 1)
    #expect(poster.authorizationStateCallCount == 1)
}

@MainActor
private func makeModel(notificationPoster: any QuotaNotificationPosting) -> AppModel {
    let suiteName = UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppModel(
        preferences: .default,
        defaults: defaults,
        notificationPoster: notificationPoster
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() {
        await Task.yield()
    }
}

@MainActor
private final class NotificationPosterDouble: QuotaNotificationPosting {
    var nextAuthorizationState: NotificationAuthorizationState
    private(set) var authorizationStateCallCount = 0
    private(set) var requestAuthorizationCallCount = 0

    init(authorizationState: NotificationAuthorizationState) {
        nextAuthorizationState = authorizationState
    }

    func authorizationState() async -> NotificationAuthorizationState {
        authorizationStateCallCount += 1
        return nextAuthorizationState
    }

    func requestAuthorization() async {
        requestAuthorizationCallCount += 1
    }

    func post(_ notifications: [QuotaNotification]) async -> Bool {
        true
    }
}
