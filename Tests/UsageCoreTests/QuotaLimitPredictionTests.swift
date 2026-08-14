import Foundation
import Testing
@testable import UsageCore

private func snapshot(
    usedPercent: Double,
    observedAt: TimeInterval,
    resetsAt: TimeInterval = 5 * 60 * 60,
    provider: Provider = .codex,
    window: QuotaWindow = .session,
    source: QuotaSource = .account
) -> QuotaSnapshot {
    QuotaSnapshot(
        provider: provider,
        window: window,
        source: source,
        usedPercent: usedPercent,
        resetsAt: Date(timeIntervalSince1970: resetsAt),
        observedAt: Date(timeIntervalSince1970: observedAt)
    )
}

@Test
func steadyBurnProjectsAtRiskBeforeReset() {
    let predictor = QuotaLimitPredictor()
    let prediction = predictor.prediction(
        for: [
            snapshot(usedPercent: 10, observedAt: 0),
            snapshot(usedPercent: 30, observedAt: 60 * 60),
            snapshot(usedPercent: 50, observedAt: 2 * 60 * 60)
        ],
        provider: .codex,
        window: .session
    )

    #expect(prediction.burnRatePercentPerHour == 20)
    #expect(prediction.pace?.deficitPercent == 10)
    #expect(prediction.pace?.reservePercent == 0)
    #expect(prediction.pace?.runsOutIn == 2.5 * 60 * 60)
    #expect(prediction.pace?.lastsUntilReset == false)

    guard case .atRisk(let projectedAt) = prediction.verdict else {
        Issue.record("Expected atRisk verdict")
        return
    }
    #expect(projectedAt == Date(timeIntervalSince1970: 4.5 * 60 * 60))
}

@Test
func burstThenIdleUsesSlidingLookbackAndLastsUntilReset() {
    let predictor = QuotaLimitPredictor()
    let prediction = predictor.prediction(
        for: [
            snapshot(usedPercent: 5, observedAt: 0),
            snapshot(usedPercent: 70, observedAt: 10 * 60),
            snapshot(usedPercent: 70, observedAt: 2 * 60 * 60),
            snapshot(usedPercent: 70, observedAt: 3 * 60 * 60)
        ],
        provider: .codex,
        window: .session
    )

    #expect(prediction.burnRatePercentPerHour == 0)
    #expect(prediction.verdict == .onTrack)
    #expect(prediction.pace?.runsOutIn == nil)
    #expect(prediction.pace?.lastsUntilReset == true)
}

@Test
func resetCrossingStartsANewSegment() {
    let predictor = QuotaLimitPredictor()
    let oldReset = 5 * 60 * 60.0
    let newReset = 10 * 60 * 60.0
    let prediction = predictor.prediction(
        for: [
            snapshot(usedPercent: 95, observedAt: 4.5 * 60 * 60, resetsAt: oldReset),
            snapshot(usedPercent: 8, observedAt: 5.1 * 60 * 60, resetsAt: newReset),
            snapshot(usedPercent: 13, observedAt: 5.6 * 60 * 60, resetsAt: newReset)
        ],
        provider: .codex,
        window: .session
    )

    #expect(prediction.burnRatePercentPerHour == 10)
    #expect(prediction.verdict == .onTrack)
    #expect(prediction.pace?.lastsUntilReset == true)
}

@Test
func sparseDataOutsideLookbackIsUnknown() {
    let predictor = QuotaLimitPredictor()
    let prediction = predictor.prediction(
        for: [
            snapshot(usedPercent: 20, observedAt: 0),
            snapshot(usedPercent: 60, observedAt: 2 * 60 * 60)
        ],
        provider: .codex,
        window: .session
    )

    #expect(prediction.burnRatePercentPerHour == nil)
    #expect(prediction.pace == nil)
    guard case .unknown(let reason) = prediction.verdict else {
        Issue.record("Expected unknown verdict")
        return
    }
    #expect(reason == "single snapshot in lookback")
}

@Test
func singleSnapshotIsUnknownWithoutInventedRate() {
    let predictor = QuotaLimitPredictor()
    let prediction = predictor.prediction(
        for: [
            snapshot(usedPercent: 42, observedAt: 60 * 60)
        ],
        provider: .codex,
        window: .session
    )

    #expect(prediction.burnRatePercentPerHour == nil)
    #expect(prediction.pace == nil)
    guard case .unknown(let reason) = prediction.verdict else {
        Issue.record("Expected unknown verdict")
        return
    }
    #expect(reason == "single snapshot in lookback")
}
