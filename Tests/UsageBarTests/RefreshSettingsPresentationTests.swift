import Testing
import Foundation
@testable import UsageBar
@testable import UsageCore

@Test
func refreshModeResolvesWithoutChangingStoredPreferences() {
    #expect(
        RefreshSettingsPresentation.mode(
            localUsage: .efficient,
            accountQuota: .oneMinute
        ) == .automatic
    )
    #expect(
        RefreshSettingsPresentation.mode(
            localUsage: .manual,
            accountQuota: .manual
        ) == .manual
    )
    #expect(
        RefreshSettingsPresentation.mode(
            localUsage: .realTime,
            accountQuota: .fiveMinutes
        ) == .custom
    )
}

@Test
func refreshModesResolveToPredictableExistingPreferencePairs() {
    let automatic = RefreshSettingsPresentation.preferences(for: .automatic)
    #expect(automatic?.localUsage == .efficient)
    #expect(automatic?.accountQuota == .oneMinute)

    let manual = RefreshSettingsPresentation.preferences(for: .manual)
    #expect(manual?.localUsage == .manual)
    #expect(manual?.accountQuota == .manual)

    #expect(RefreshSettingsPresentation.preferences(for: .custom) == nil)
}

@Test
func accountStatusSeparatesConsentFromTheLatestCheckResult() {
    let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let report = ProviderConnectionReport(
        provider: .claude,
        state: .rateLimited,
        checkedAt: checkedAt
    )

    #expect(
        RefreshSettingsPresentation.accountStatus(
            checksEnabled: false,
            report: report
        ) == "Not enabled"
    )
    #expect(
        RefreshSettingsPresentation.accountStatus(
            checksEnabled: true,
            report: nil
        ) == "Waiting for first check"
    )
    #expect(
        RefreshSettingsPresentation.accountStatus(
            checksEnabled: true,
            report: report
        ).hasPrefix("Temporarily throttled · checked ")
    )
}
