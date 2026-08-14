import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func historyLayoutSwitchesToCompactBelowBreakpoint() {
    #expect(HistoryLayout(availableWidth: 799).isCompact)
    #expect(!HistoryLayout(availableWidth: 800).isCompact)
}

@Test
func compactHistoryLayoutUsesTighterDocumentSpacing() {
    let compact = HistoryLayout(availableWidth: 620)
    let regular = HistoryLayout(availableWidth: 1_060)

    #expect(compact.horizontalPadding < regular.horizontalPadding)
    #expect(compact.sectionSpacing < regular.sectionSpacing)
    #expect(compact.metricColumns.count == 2)
}

@Test
func quotaHistorySegmentsBreakAtResetBoundaries() {
    let start = Date(timeIntervalSince1970: 1_000)
    let firstReset = start.addingTimeInterval(3_600)
    let secondReset = start.addingTimeInterval(7_200)
    let points = [
        quotaPoint(observedAt: start, usedPercent: 20, resetsAt: firstReset),
        quotaPoint(observedAt: start.addingTimeInterval(60), usedPercent: 40, resetsAt: firstReset),
        quotaPoint(observedAt: start.addingTimeInterval(120), usedPercent: 5, resetsAt: secondReset),
        quotaPoint(observedAt: start.addingTimeInterval(180), usedPercent: 15, resetsAt: secondReset)
    ]

    let segments = QuotaChartSegmenter.segments(from: points)

    #expect(segments.count == 2)
    #expect(segments.map { $0.map(\.usedPercent) } == [[20, 40], [5, 15]])
}

@Test
func quotaHistoryDisplayPrefersAccountPointsWhenAvailable() {
    let start = Date(timeIntervalSince1970: 2_000)
    let reset = start.addingTimeInterval(3_600)
    let points = [
        QuotaHistoryPoint(
            window: .weekly,
            source: .local,
            observedAt: start,
            usedPercent: 10,
            resetsAt: reset
        ),
        QuotaHistoryPoint(
            window: .weekly,
            source: .account,
            observedAt: start.addingTimeInterval(60),
            usedPercent: 50,
            resetsAt: reset
        )
    ]

    let displayPoints = QuotaChartSegmenter.displayPoints(from: points)

    #expect(displayPoints.map(\.source) == [.account])
}

@Test
func quotaHistoryDisplayFallsBackToLocalPoints() {
    let start = Date(timeIntervalSince1970: 3_000)
    let reset = start.addingTimeInterval(3_600)
    let points = [
        QuotaHistoryPoint(
            window: .weekly,
            source: .local,
            observedAt: start,
            usedPercent: 25,
            resetsAt: reset
        )
    ]

    let displayPoints = QuotaChartSegmenter.displayPoints(from: points)

    #expect(displayPoints.map(\.source) == [.local])
}

@Test
func quotaHistoryDisplayKeepsLocalFallbackForAResetCycleWithoutAccountCoverage() {
    let start = Date(timeIntervalSince1970: 4_000)
    let firstReset = start.addingTimeInterval(3_600)
    let secondReset = start.addingTimeInterval(7_200)
    let points = [
        QuotaHistoryPoint(
            window: .session,
            source: .account,
            observedAt: start,
            usedPercent: 40,
            resetsAt: firstReset
        ),
        QuotaHistoryPoint(
            window: .session,
            source: .local,
            observedAt: start.addingTimeInterval(3_700),
            usedPercent: 10,
            resetsAt: secondReset
        )
    ]

    let displayPoints = QuotaChartSegmenter.displayPoints(from: points)

    #expect(displayPoints.map(\.source) == [.account, .local])
}

private func quotaPoint(
    observedAt: Date,
    usedPercent: Double,
    resetsAt: Date
) -> QuotaHistoryPoint {
    QuotaHistoryPoint(
        window: .session,
        source: .account,
        observedAt: observedAt,
        usedPercent: usedPercent,
        resetsAt: resetsAt
    )
}
