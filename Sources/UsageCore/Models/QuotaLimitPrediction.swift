import Foundation

public enum QuotaLimitVerdict: Equatable, Sendable {
    case onTrack
    case atRisk(projectedAt: Date)
    case unknown(reason: String)
}

public struct QuotaPace: Equatable, Sendable {
    public let idealUsedPercent: Double
    public let reservePercent: Double
    public let deficitPercent: Double
    public let isOnPace: Bool
    public let runsOutIn: TimeInterval?
    public let lastsUntilReset: Bool

    public init(
        idealUsedPercent: Double,
        reservePercent: Double,
        deficitPercent: Double,
        isOnPace: Bool,
        runsOutIn: TimeInterval?,
        lastsUntilReset: Bool
    ) {
        self.idealUsedPercent = idealUsedPercent
        self.reservePercent = reservePercent
        self.deficitPercent = deficitPercent
        self.isOnPace = isOnPace
        self.runsOutIn = runsOutIn
        self.lastsUntilReset = lastsUntilReset
    }
}

public struct QuotaLimitPrediction: Equatable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let source: QuotaSource
    public let observedAt: Date
    public let resetsAt: Date
    public let usedPercent: Double
    public let burnRatePercentPerHour: Double?
    public let lookback: TimeInterval
    public let verdict: QuotaLimitVerdict
    public let pace: QuotaPace?

    public init(
        provider: Provider,
        window: QuotaWindow,
        source: QuotaSource,
        observedAt: Date,
        resetsAt: Date,
        usedPercent: Double,
        burnRatePercentPerHour: Double?,
        lookback: TimeInterval,
        verdict: QuotaLimitVerdict,
        pace: QuotaPace?
    ) {
        self.provider = provider
        self.window = window
        self.source = source
        self.observedAt = observedAt
        self.resetsAt = resetsAt
        self.usedPercent = usedPercent
        self.burnRatePercentPerHour = burnRatePercentPerHour
        self.lookback = lookback
        self.verdict = verdict
        self.pace = pace
    }
}

public struct QuotaLimitPredictor: Sendable {
    public static let defaultLookback: TimeInterval = 90 * 60

    public let lookback: TimeInterval

    public init(lookback: TimeInterval = Self.defaultLookback) {
        self.lookback = lookback
    }

    public func prediction(
        for snapshots: [QuotaSnapshot],
        provider: Provider,
        window: QuotaWindow,
        source: QuotaSource? = nil
    ) -> QuotaLimitPrediction {
        let candidates = snapshots
            .filter { snapshot in
                snapshot.provider == provider
                    && snapshot.window == window
                    && source.map { snapshot.source == $0 } ?? true
            }
            .sorted { first, second in
                if first.observedAt == second.observedAt {
                    return first.resetsAt < second.resetsAt
                }
                return first.observedAt < second.observedAt
            }

        guard let latest = candidates.last else {
            return unknown(
                provider: provider,
                window: window,
                source: source ?? .local,
                reason: "no snapshots"
            )
        }

        let latestSegment = currentSegment(endingAt: latest, in: candidates)
        let segmentStart = latest.observedAt.addingTimeInterval(-lookback)
        let lookbackSegment = latestSegment.filter { $0.observedAt >= segmentStart }

        guard lookbackSegment.count >= 2,
              let first = lookbackSegment.first else {
            return unknown(
                latest: latest,
                reason: "single snapshot in lookback"
            )
        }

        let elapsed = latest.observedAt.timeIntervalSince(first.observedAt)
        guard elapsed >= 60 else {
            return unknown(
                latest: latest,
                reason: "insufficient elapsed time"
            )
        }

        let usedDelta = max(0, latest.clampedUsedPercent - first.clampedUsedPercent)
        let burnRate = usedDelta / elapsed * 3_600
        let pace = pacePayload(
            for: latest,
            burnRatePercentPerHour: burnRate,
            projectedAt: projectedLimitDate(from: latest, burnRatePercentPerHour: burnRate)
        )

        guard burnRate > 0 else {
            return prediction(
                latest: latest,
                burnRatePercentPerHour: burnRate,
                verdict: .onTrack,
                pace: pace
            )
        }

        guard let projectedAt = projectedLimitDate(from: latest, burnRatePercentPerHour: burnRate),
              projectedAt <= latest.resetsAt else {
            return prediction(
                latest: latest,
                burnRatePercentPerHour: burnRate,
                verdict: .onTrack,
                pace: pace
            )
        }

        return prediction(
            latest: latest,
            burnRatePercentPerHour: burnRate,
            verdict: .atRisk(projectedAt: projectedAt),
            pace: pace
        )
    }

    public func predictions(
        for snapshots: [QuotaSnapshot],
        provider: Provider,
        source: QuotaSource? = nil
    ) -> [QuotaLimitPrediction] {
        QuotaWindow.allCases.map {
            prediction(for: snapshots, provider: provider, window: $0, source: source)
        }
    }

    private func currentSegment(endingAt latest: QuotaSnapshot, in snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        var segment: [QuotaSnapshot] = [latest]
        var previous = latest

        for snapshot in snapshots.dropLast().reversed() {
            guard snapshot.resetsAt == previous.resetsAt,
                  snapshot.usedPercent <= previous.usedPercent else {
                break
            }
            segment.append(snapshot)
            previous = snapshot
        }

        return segment.reversed()
    }

    private func projectedLimitDate(
        from latest: QuotaSnapshot,
        burnRatePercentPerHour: Double
    ) -> Date? {
        guard burnRatePercentPerHour > 0 else {
            return nil
        }
        let remaining = latest.remainingPercent
        let secondsUntilLimit = remaining / burnRatePercentPerHour * 3_600
        return latest.observedAt.addingTimeInterval(secondsUntilLimit)
    }

    private func pacePayload(
        for latest: QuotaSnapshot,
        burnRatePercentPerHour: Double,
        projectedAt: Date?
    ) -> QuotaPace {
        let ideal = idealUsedPercent(for: latest)
        let actual = latest.clampedUsedPercent
        let reserve = max(0, ideal - actual)
        let deficit = max(0, actual - ideal)
        let atRisk = projectedAt.map { $0 <= latest.resetsAt } ?? false

        return QuotaPace(
            idealUsedPercent: ideal,
            reservePercent: reserve,
            deficitPercent: deficit,
            isOnPace: deficit == 0,
            runsOutIn: atRisk ? projectedAt?.timeIntervalSince(latest.observedAt) : nil,
            lastsUntilReset: !atRisk
        )
    }

    private func idealUsedPercent(for snapshot: QuotaSnapshot) -> Double {
        let duration = snapshot.window.predictionWindowDuration
        let windowStart = snapshot.resetsAt.addingTimeInterval(-duration)
        let elapsed = snapshot.observedAt.timeIntervalSince(windowStart)
        guard elapsed > 0 else {
            return 0
        }
        return min(max(elapsed / duration * 100, 0), 100)
    }

    private func prediction(
        latest: QuotaSnapshot,
        burnRatePercentPerHour: Double?,
        verdict: QuotaLimitVerdict,
        pace: QuotaPace?
    ) -> QuotaLimitPrediction {
        QuotaLimitPrediction(
            provider: latest.provider,
            window: latest.window,
            source: latest.source,
            observedAt: latest.observedAt,
            resetsAt: latest.resetsAt,
            usedPercent: latest.clampedUsedPercent,
            burnRatePercentPerHour: burnRatePercentPerHour,
            lookback: lookback,
            verdict: verdict,
            pace: pace
        )
    }

    private func unknown(latest: QuotaSnapshot, reason: String) -> QuotaLimitPrediction {
        prediction(
            latest: latest,
            burnRatePercentPerHour: nil,
            verdict: .unknown(reason: reason),
            pace: nil
        )
    }

    private func unknown(
        provider: Provider,
        window: QuotaWindow,
        source: QuotaSource,
        reason: String
    ) -> QuotaLimitPrediction {
        QuotaLimitPrediction(
            provider: provider,
            window: window,
            source: source,
            observedAt: .distantPast,
            resetsAt: .distantPast,
            usedPercent: 0,
            burnRatePercentPerHour: nil,
            lookback: lookback,
            verdict: .unknown(reason: reason),
            pace: nil
        )
    }
}

private extension QuotaWindow {
    var predictionWindowDuration: TimeInterval {
        switch self {
        case .session:
            5 * 60 * 60
        case .weekly:
            7 * 24 * 60 * 60
        }
    }
}
