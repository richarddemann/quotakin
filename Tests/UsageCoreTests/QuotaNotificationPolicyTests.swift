import Foundation
import Testing
@testable import UsageCore

private let now = Date(timeIntervalSince1970: 10_000)

private func snapshot(
    provider: Provider = .claude,
    window: QuotaWindow = .session,
    usedPercent: Double,
    observedAt: Date = now,
    resetsAt: Date = Date(timeIntervalSince1970: 20_000)
) -> QuotaSnapshot {
    QuotaSnapshot(
        provider: provider,
        window: window,
        source: .account,
        usedPercent: usedPercent,
        resetsAt: resetsAt,
        observedAt: observedAt
    )
}

private func atRiskPrediction(
    provider: Provider = .claude,
    window: QuotaWindow = .session,
    observedAt: Date = now,
    resetsAt: Date = Date(timeIntervalSince1970: 20_000),
    projectedAt: Date = Date(timeIntervalSince1970: 15_000)
) -> QuotaLimitPrediction {
    QuotaLimitPrediction(
        provider: provider,
        window: window,
        source: .account,
        observedAt: observedAt,
        resetsAt: resetsAt,
        usedPercent: 60,
        burnRatePercentPerHour: 20,
        lookback: 90 * 60,
        verdict: .atRisk(projectedAt: projectedAt),
        pace: nil
    )
}

private func preferences(
    kinds: [QuotaNotificationKind] = [.thresholdCrossed],
    thresholdsByWindow: [QuotaWindow: [Double]] = [.session: [50]]
) -> QuotaNotificationPreferences {
    QuotaNotificationPreferences(enabledKinds: kinds, thresholdsByWindow: thresholdsByWindow)
}

@Test
func thresholdCrossingEmitsOncePerResetCycle() {
    let first = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 49)],
        currentSnapshots: [snapshot(usedPercent: 51)],
        predictions: [],
        preferences: preferences(),
        now: now
    )

    #expect(first.notifications == [
        .thresholdCrossed(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 51)), threshold: 50)
    ])

    let second = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 51)],
        currentSnapshots: [snapshot(usedPercent: 55)],
        predictions: [],
        preferences: preferences(),
        state: first.state,
        now: now
    )

    #expect(second.notifications.isEmpty)
}

@Test
func firstRunSeedSuppressesExistingUsageAndPersistedCrossingFiresOnceAfterRestart() {
    let seededCurrent = snapshot(usedPercent: 80)
    let firstRun = QuotaNotificationPolicy.decide(
        previousSnapshots: [seededCurrent],
        currentSnapshots: [seededCurrent],
        predictions: [],
        preferences: preferences(thresholdsByWindow: [.session: [50, 75, 90]]),
        now: now
    )

    #expect(firstRun.notifications.isEmpty)

    let crossed = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 49)],
        currentSnapshots: [snapshot(usedPercent: 51)],
        predictions: [],
        preferences: preferences(),
        now: now
    )

    #expect(crossed.notifications == [
        .thresholdCrossed(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 51)), threshold: 50)
    ])

    let restarted = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 51)],
        currentSnapshots: [snapshot(usedPercent: 55)],
        predictions: [],
        preferences: preferences(),
        state: crossed.state,
        now: now
    )

    #expect(restarted.notifications.isEmpty)
}

@Test
func thresholdCanRefireAfterReset() {
    let oldReset = Date(timeIntervalSince1970: 20_000)
    let newReset = Date(timeIntervalSince1970: 30_000)

    let first = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 49, resetsAt: oldReset)],
        currentSnapshots: [snapshot(usedPercent: 51, resetsAt: oldReset)],
        predictions: [],
        preferences: preferences(),
        now: now
    )

    let second = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 5, resetsAt: newReset)],
        currentSnapshots: [snapshot(usedPercent: 52, resetsAt: newReset)],
        predictions: [],
        preferences: preferences(),
        state: first.state,
        now: now
    )

    #expect(second.notifications == [
        .thresholdCrossed(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 52, resetsAt: newReset)), threshold: 50)
    ])
}

@Test
func multipleThresholdsEmitForSameCrossingRefresh() {
    let decision = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 40)],
        currentSnapshots: [snapshot(usedPercent: 80)],
        predictions: [],
        preferences: preferences(thresholdsByWindow: [.session: [50, 75, 90]]),
        now: now
    )

    #expect(decision.notifications == [
        .thresholdCrossed(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 80)), threshold: 50),
        .thresholdCrossed(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 80)), threshold: 75)
    ])
}

@Test
func staleSnapshotsSuppressNotifications() {
    let stale = now.addingTimeInterval(-601)
    let decision = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 49, observedAt: stale)],
        currentSnapshots: [snapshot(usedPercent: 91, observedAt: stale)],
        predictions: [atRiskPrediction(observedAt: stale)],
        preferences: preferences(
            kinds: [.thresholdCrossed, .windowReset, .atRiskPrediction],
            thresholdsByWindow: [.session: [50, 75, 90]]
        ),
        now: now
    )

    #expect(decision.notifications.isEmpty)
}

@Test
func predictionAlertDeduplicatesPerResetCycle() {
    let first = QuotaNotificationPolicy.decide(
        previousSnapshots: [],
        currentSnapshots: [],
        predictions: [atRiskPrediction()],
        preferences: preferences(kinds: [.atRiskPrediction]),
        now: now
    )

    #expect(first.notifications == [
        .atRiskPrediction(QuotaNotificationPayload(prediction: atRiskPrediction()), projectedAt: Date(timeIntervalSince1970: 15_000))
    ])

    let second = QuotaNotificationPolicy.decide(
        previousSnapshots: [],
        currentSnapshots: [],
        predictions: [atRiskPrediction(projectedAt: Date(timeIntervalSince1970: 16_000))],
        preferences: preferences(kinds: [.atRiskPrediction]),
        state: first.state,
        now: now
    )

    #expect(second.notifications.isEmpty)
}

@Test
func resetNotificationEmitsOnNewCycle() {
    let oldReset = Date(timeIntervalSince1970: 20_000)
    let newReset = Date(timeIntervalSince1970: 30_000)
    let decision = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 98, resetsAt: oldReset)],
        currentSnapshots: [snapshot(usedPercent: 1, resetsAt: newReset)],
        predictions: [],
        preferences: preferences(kinds: [.windowReset]),
        now: now
    )

    #expect(decision.notifications == [
        .windowReset(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 1, resetsAt: newReset)))
    ])
}

@Test
func resetNotificationIgnoresSameCycleDipAndBareReschedule() {
    let oldReset = Date(timeIntervalSince1970: 20_000)
    let newReset = Date(timeIntervalSince1970: 30_000)

    let sameCycleDip = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 60, resetsAt: oldReset)],
        currentSnapshots: [snapshot(usedPercent: 55, resetsAt: oldReset)],
        predictions: [],
        preferences: preferences(kinds: [.windowReset]),
        now: now
    )

    #expect(sameCycleDip.notifications.isEmpty)

    let bareReschedule = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 60, resetsAt: oldReset)],
        currentSnapshots: [snapshot(usedPercent: 65, resetsAt: newReset)],
        predictions: [],
        preferences: preferences(kinds: [.windowReset]),
        now: now
    )

    #expect(bareReschedule.notifications.isEmpty)
}

@Test
func resetNotificationEmitsOnlyOnGenuineRefill() {
    let oldReset = Date(timeIntervalSince1970: 20_000)
    let newReset = Date(timeIntervalSince1970: 30_000)

    let decision = QuotaNotificationPolicy.decide(
        previousSnapshots: [snapshot(usedPercent: 98, resetsAt: oldReset)],
        currentSnapshots: [snapshot(usedPercent: 1, resetsAt: newReset)],
        predictions: [],
        preferences: preferences(kinds: [.windowReset]),
        now: now
    )

    #expect(decision.notifications == [
        .windowReset(QuotaNotificationPayload(snapshot: snapshot(usedPercent: 1, resetsAt: newReset)))
    ])
}
