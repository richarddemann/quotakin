import Testing
import UsageCore
@testable import UsageBar

@Test
func addableMetricsKeepsDisabledOrderAndExcludesSelectedMetrics() {
    let addable = MenuBarMetricPickerPresentation.addableMetrics(
        selectedMetrics: [.weeklyPercentage, .dailyTokens],
        disabledMetrics: [
            .sessionPercentage,
            .dailyTokens,
            .resetCountdown,
            .weeklyPercentage,
            .estimatedMonthlyCost
        ]
    )

    #expect(addable == [.sessionPercentage, .resetCountdown, .estimatedMonthlyCost])
}

@Test
func addableMetricsHavePopoverPresentationMetadata() {
    for metric in MenuBarMetric.allCases {
        #expect(!MenuBarMetricPickerPresentation.systemImage(for: metric).isEmpty)
        #expect(!MenuBarMetricPickerPresentation.detail(for: metric, quotaDisplayMode: .remaining).isEmpty)
        #expect(!MenuBarMetricPickerPresentation.detail(for: metric, quotaDisplayMode: .used).isEmpty)
    }
}

@Test
func quotaMetricDescriptionsFollowDisplayMode() {
    #expect(MenuBarMetricPickerPresentation.detail(for: .sessionPercentage, quotaDisplayMode: .remaining) == "5-hour quota left")
    #expect(MenuBarMetricPickerPresentation.detail(for: .weeklyPercentage, quotaDisplayMode: .used) == "Weekly quota used")
}
