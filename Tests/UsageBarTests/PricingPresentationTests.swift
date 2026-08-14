import Testing
@testable import UsageBar

@Test
func costChartExplainsUnavailablePricingWhenTokensExist() {
    #expect(
        UsageChartAvailability.resolve(
            metric: .cost,
            totalTokens: 42,
            hasNonZeroPoints: false,
            hasUnpricedSamples: true
        )
            == .costUnavailable
    )
}

@Test
func chartReportsNoUsageOnlyWhenThereAreNoTokens() {
    #expect(
        UsageChartAvailability.resolve(
            metric: .cost,
            totalTokens: 0,
            hasNonZeroPoints: false,
            hasUnpricedSamples: false
        )
            == .noUsage
    )
}

@Test
func zeroPricedUsageRemainsAvailableWhenPricingCoverageIsComplete() {
    #expect(
        UsageChartAvailability.resolve(
            metric: .cost,
            totalTokens: 42,
            hasNonZeroPoints: false,
            hasUnpricedSamples: false
        ) == .available
    )
}
