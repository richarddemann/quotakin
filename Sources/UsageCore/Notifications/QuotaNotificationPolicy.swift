import Foundation

public enum QuotaNotification: Equatable, Sendable {
    case thresholdCrossed(QuotaNotificationPayload, threshold: Double)
    case windowReset(QuotaNotificationPayload)
    case atRiskPrediction(QuotaNotificationPayload, projectedAt: Date)

    public var payload: QuotaNotificationPayload {
        switch self {
        case .thresholdCrossed(let payload, _), .windowReset(let payload), .atRiskPrediction(let payload, _):
            payload
        }
    }
}

public struct QuotaNotificationPayload: Equatable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let usedPercent: Double
    public let resetsAt: Date
    public let observedAt: Date

    public init(
        provider: Provider,
        window: QuotaWindow,
        usedPercent: Double,
        resetsAt: Date,
        observedAt: Date
    ) {
        self.provider = provider
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public init(snapshot: QuotaSnapshot) {
        self.init(
            provider: snapshot.provider,
            window: snapshot.window,
            usedPercent: snapshot.clampedUsedPercent,
            resetsAt: snapshot.resetsAt,
            observedAt: snapshot.observedAt
        )
    }

    public init(prediction: QuotaLimitPrediction) {
        self.init(
            provider: prediction.provider,
            window: prediction.window,
            usedPercent: min(max(prediction.usedPercent, 0), 100),
            resetsAt: prediction.resetsAt,
            observedAt: prediction.observedAt
        )
    }
}

public struct QuotaNotificationPolicyState: Codable, Equatable, Sendable {
    public var firedThresholds: Set<QuotaThresholdNotificationKey>
    public var firedResets: Set<QuotaResetNotificationKey>
    public var firedPredictions: Set<QuotaPredictionNotificationKey>

    public init(
        firedThresholds: Set<QuotaThresholdNotificationKey> = [],
        firedResets: Set<QuotaResetNotificationKey> = [],
        firedPredictions: Set<QuotaPredictionNotificationKey> = []
    ) {
        self.firedThresholds = firedThresholds
        self.firedResets = firedResets
        self.firedPredictions = firedPredictions
    }
}

public struct QuotaThresholdNotificationKey: Codable, Hashable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let threshold: Double
    public let resetCycle: Date

    public init(provider: Provider, window: QuotaWindow, threshold: Double, resetCycle: Date) {
        self.provider = provider
        self.window = window
        self.threshold = threshold
        self.resetCycle = resetCycle
    }
}

public struct QuotaResetNotificationKey: Codable, Hashable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let resetCycle: Date

    public init(provider: Provider, window: QuotaWindow, resetCycle: Date) {
        self.provider = provider
        self.window = window
        self.resetCycle = resetCycle
    }
}

public struct QuotaPredictionNotificationKey: Codable, Hashable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let resetCycle: Date

    public init(provider: Provider, window: QuotaWindow, resetCycle: Date) {
        self.provider = provider
        self.window = window
        self.resetCycle = resetCycle
    }
}

public struct QuotaNotificationDecision: Equatable, Sendable {
    public let notifications: [QuotaNotification]
    public let state: QuotaNotificationPolicyState

    public init(notifications: [QuotaNotification], state: QuotaNotificationPolicyState) {
        self.notifications = notifications
        self.state = state
    }
}

public enum QuotaNotificationPolicy {
    public static func decide(
        previousSnapshots: [QuotaSnapshot],
        currentSnapshots: [QuotaSnapshot],
        predictions: [QuotaLimitPrediction],
        preferences: QuotaNotificationPreferences,
        state: QuotaNotificationPolicyState = QuotaNotificationPolicyState(),
        now: Date
    ) -> QuotaNotificationDecision {
        guard preferences.isEnabled else {
            return QuotaNotificationDecision(notifications: [], state: state)
        }

        var nextState = state
        var notifications: [QuotaNotification] = []
        let previousByIdentity = latestFreshSnapshotsByIdentity(previousSnapshots, now: now)
        let currentByIdentity = latestFreshSnapshotsByIdentity(currentSnapshots, now: now)

        if preferences.isEnabled(.thresholdCrossed) {
            for (_, current) in currentByIdentity {
                let previous = previousByIdentity[SnapshotIdentity(provider: current.provider, window: current.window)]
                for threshold in preferences.thresholds(for: current.window) {
                    guard crossed(threshold: threshold, previous: previous, current: current) else {
                        continue
                    }
                    let key = QuotaThresholdNotificationKey(
                        provider: current.provider,
                        window: current.window,
                        threshold: threshold,
                        resetCycle: current.resetsAt
                    )
                    guard nextState.firedThresholds.insert(key).inserted else {
                        continue
                    }
                    notifications.append(.thresholdCrossed(QuotaNotificationPayload(snapshot: current), threshold: threshold))
                }
            }
        }

        if preferences.isEnabled(.windowReset) {
            for (identity, current) in currentByIdentity {
                guard let previous = previousByIdentity[identity],
                      QuotaResetDetector.didReset(previous: previous, current: current)
                else {
                    continue
                }
                let key = QuotaResetNotificationKey(
                    provider: current.provider,
                    window: current.window,
                    resetCycle: current.resetsAt
                )
                guard nextState.firedResets.insert(key).inserted else {
                    continue
                }
                notifications.append(.windowReset(QuotaNotificationPayload(snapshot: current)))
            }
        }

        if preferences.isEnabled(.atRiskPrediction) {
            for prediction in latestFreshAtRiskPredictions(predictions, now: now) {
                let key = QuotaPredictionNotificationKey(
                    provider: prediction.provider,
                    window: prediction.window,
                    resetCycle: prediction.resetsAt
                )
                guard nextState.firedPredictions.insert(key).inserted else {
                    continue
                }
                guard case .atRisk(let projectedAt) = prediction.verdict else {
                    continue
                }
                notifications.append(.atRiskPrediction(QuotaNotificationPayload(prediction: prediction), projectedAt: projectedAt))
            }
        }

        return QuotaNotificationDecision(notifications: notifications, state: nextState)
    }

    private static func crossed(
        threshold: Double,
        previous: QuotaSnapshot?,
        current: QuotaSnapshot
    ) -> Bool {
        guard current.clampedUsedPercent >= threshold else {
            return false
        }
        guard let previous, previous.resetsAt == current.resetsAt else {
            return true
        }
        return previous.clampedUsedPercent < threshold
    }

    private static func latestFreshSnapshotsByIdentity(
        _ snapshots: [QuotaSnapshot],
        now: Date
    ) -> [SnapshotIdentity: QuotaSnapshot] {
        snapshots
            .filter { $0.freshness(at: now) == .fresh }
            .reduce(into: [:]) { result, snapshot in
                let identity = SnapshotIdentity(provider: snapshot.provider, window: snapshot.window)
                guard let existing = result[identity] else {
                    result[identity] = snapshot
                    return
                }
                if snapshot.observedAt > existing.observedAt {
                    result[identity] = snapshot
                }
            }
    }

    private static func latestFreshAtRiskPredictions(
        _ predictions: [QuotaLimitPrediction],
        now: Date
    ) -> [QuotaLimitPrediction] {
        let byIdentity = predictions
            .filter { prediction in
                guard case .atRisk = prediction.verdict else {
                    return false
                }
                let age = now.timeIntervalSince(prediction.observedAt)
                return age >= 0 && age <= 600
            }
            .reduce(into: [SnapshotIdentity: QuotaLimitPrediction]()) { result, prediction in
                let identity = SnapshotIdentity(provider: prediction.provider, window: prediction.window)
                guard let existing = result[identity] else {
                    result[identity] = prediction
                    return
                }
                if prediction.observedAt > existing.observedAt {
                    result[identity] = prediction
                }
            }
        return byIdentity.values.sorted {
            if $0.provider == $1.provider {
                return $0.window.rawValue < $1.window.rawValue
            }
            return $0.provider.rawValue < $1.provider.rawValue
        }
    }
}

private struct SnapshotIdentity: Hashable {
    let provider: Provider
    let window: QuotaWindow
}
