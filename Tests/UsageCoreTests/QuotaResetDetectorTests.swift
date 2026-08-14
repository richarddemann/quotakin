import Foundation
import Testing
@testable import UsageCore

@Test
func detectsResetWhenResetMovesLaterAndRemainingIncreases() {
    let previous = [snapshot(.claude, .session, usedPercent: 80, resetsAt: 1_000)]
    let current = [snapshot(.claude, .session, usedPercent: 20, resetsAt: 2_000)]

    #expect(QuotaResetDetector.resetProviders(previous: previous, current: current) == [.claude])
}

@Test
func noResetWhenOnlyResetTimeMovesLater() {
    let previous = [snapshot(.claude, .session, usedPercent: 80, resetsAt: 1_000)]
    // Reset rescheduled but capacity did not refill.
    let current = [snapshot(.claude, .session, usedPercent: 90, resetsAt: 2_000)]

    #expect(QuotaResetDetector.resetProviders(previous: previous, current: current).isEmpty)
}

@Test
func noResetWhenOnlyRemainingIncreasesWithoutNewCycle() {
    let previous = [snapshot(.claude, .session, usedPercent: 80, resetsAt: 1_000)]
    let current = [snapshot(.claude, .session, usedPercent: 20, resetsAt: 1_000)]

    #expect(QuotaResetDetector.resetProviders(previous: previous, current: current).isEmpty)
}

@Test
func noResetForIdenticalSnapshotsOrMissingPrevious() {
    let same = [snapshot(.claude, .session, usedPercent: 80, resetsAt: 1_000)]
    #expect(QuotaResetDetector.resetProviders(previous: same, current: same).isEmpty)

    // No matching previous window → nothing to compare, no false positive.
    let current = [snapshot(.codex, .weekly, usedPercent: 10, resetsAt: 2_000)]
    #expect(QuotaResetDetector.resetProviders(previous: [], current: current).isEmpty)
}

@Test
func matchesPerProviderAndWindowIndependently() {
    let previous = [
        snapshot(.claude, .weekly, usedPercent: 90, resetsAt: 1_000),
        snapshot(.codex, .weekly, usedPercent: 50, resetsAt: 1_000)
    ]
    let current = [
        // Claude weekly refilled → reset. Codex weekly unchanged → not.
        snapshot(.claude, .weekly, usedPercent: 10, resetsAt: 2_000),
        snapshot(.codex, .weekly, usedPercent: 55, resetsAt: 1_000)
    ]

    #expect(QuotaResetDetector.resetProviders(previous: previous, current: current) == [.claude])
}

private func snapshot(
    _ provider: Provider,
    _ window: QuotaWindow,
    usedPercent: Double,
    resetsAt: TimeInterval
) -> QuotaSnapshot {
    QuotaSnapshot(
        provider: provider,
        window: window,
        usedPercent: usedPercent,
        resetsAt: Date(timeIntervalSince1970: resetsAt),
        observedAt: Date(timeIntervalSince1970: 500)
    )
}
