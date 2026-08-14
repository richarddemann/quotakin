import Foundation
import Testing
@testable import UsageCore

@Test
func quotaSnapshotBecomesStaleAfterTenMinutes() {
    let observed = Date(timeIntervalSince1970: 1_000)
    let snapshot = QuotaSnapshot(
        provider: .claude,
        window: .session,
        usedPercent: 42,
        resetsAt: Date(timeIntervalSince1970: 5_000),
        observedAt: observed
    )

    #expect(snapshot.freshness(at: observed.addingTimeInterval(600)) == .fresh)
    #expect(snapshot.freshness(at: observed.addingTimeInterval(601)) == .stale)
}

@Test
func quotaSnapshotWithFutureObservationIsStale() {
    let observed = Date(timeIntervalSince1970: 1_000)
    let snapshot = QuotaSnapshot(
        provider: .claude,
        window: .session,
        usedPercent: 42,
        resetsAt: Date(timeIntervalSince1970: 5_000),
        observedAt: observed
    )

    #expect(snapshot.freshness(at: observed.addingTimeInterval(-1)) == .stale)
}

@Test
func quotaSnapshotIsCurrentOnlyWhenFreshAndResetIsFuture() {
    let observed = Date(timeIntervalSince1970: 1_000)
    let now = observed.addingTimeInterval(120)

    #expect(
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            usedPercent: 42,
            resetsAt: now.addingTimeInterval(60),
            observedAt: observed
        ).isCurrent(at: now)
    )
    #expect(
        !QuotaSnapshot(
            provider: .claude,
            window: .session,
            usedPercent: 42,
            resetsAt: now.addingTimeInterval(60),
            observedAt: now.addingTimeInterval(-601)
        ).isCurrent(at: now)
    )
    #expect(
        !QuotaSnapshot(
            provider: .claude,
            window: .session,
            usedPercent: 42,
            resetsAt: now.addingTimeInterval(-1),
            observedAt: observed
        ).isCurrent(at: now)
    )
}

@Test
func quotaSnapshotExposesClampedRemainingPercent() {
    #expect(
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            usedPercent: 36,
            resetsAt: Date(timeIntervalSince1970: 5_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        ).remainingPercent == 64
    )
    #expect(
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            usedPercent: 125,
            resetsAt: Date(timeIntervalSince1970: 5_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        ).remainingPercent == 0
    )
}

@Test
func tokenSampleStoresClaudeNormalizedTotal() {
    let sample = TokenSample(
        provider: .claude,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "claude-sonnet-4-6",
        inputTokens: 3,
        outputTokens: 20,
        cachedInputTokens: 100,
        cacheCreationInputTokens: 50,
        reasoningOutputTokens: 0,
        totalTokens: 173
    )

    #expect(sample.totalTokens == 173)
}

@Test
func tokenSampleStoresCodexNormalizedTotal() {
    let sample = TokenSample(
        provider: .codex,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "codex",
        inputTokens: 80,
        outputTokens: 12,
        cachedInputTokens: 40,
        reasoningOutputTokens: 3,
        totalTokens: 132
    )

    #expect(sample.totalTokens == 132)
}

@Test
func refreshIntervalsMatchProfiles() {
    #expect(RefreshProfile.realTime.fallbackInterval == 300)
    #expect(RefreshProfile.efficient.fallbackInterval == 900)
    #expect(RefreshProfile.responsive.fallbackInterval == 600)
    #expect(RefreshProfile.manual.fallbackInterval == nil)
}

@Test
func defaultPreferencesUseIconOnlyMenuBarForBothProviders() {
    #expect(UserPreferences.default.refreshProfile == .efficient)
    #expect(UserPreferences.default.liveQuotaRefreshInterval == .oneMinute)
    #expect(UserPreferences.default.providers == [.claude, .codex])
    #expect(UserPreferences.default.accountQuotaConsents.isEmpty)
    #expect(UserPreferences.default.quotaDisplayMode == .remaining)
    #expect(UserPreferences.default.menuBarMetrics == [])
    #expect(UserPreferences.default.notificationPreferences == QuotaNotificationPreferences())
    #expect(UserPreferences.default.petModeEnabled == false)
    #expect(UserPreferences.default.showProviderNamesInPetMode == false)
    #expect(UserPreferences.default.petSelection == [:])
}

@Test
func legacyPreferencesDefaultPetProviderNamesToHidden() throws {
    let data = Data(#"{"petModeEnabled":true}"#.utf8)
    let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(preferences.petModeEnabled)
    #expect(preferences.showProviderNamesInPetMode == false)
}

@Test
func preferencesDecodeMissingQuotaDisplayModeAsRemaining() throws {
    let data = """
    {
      "refreshProfile": "responsive",
      "providers": ["claude"],
      "menuBarMetrics": ["sessionPercentage"]
    }
    """.data(using: .utf8)!

    let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(preferences.refreshProfile == .responsive)
    #expect(preferences.providers == [.claude])
    #expect(preferences.accountQuotaConsents.isEmpty)
    #expect(preferences.menuBarMetrics == [.sessionPercentage])
    #expect(preferences.quotaDisplayMode == .remaining)
    #expect(preferences.notificationPreferences == QuotaNotificationPreferences())
    #expect(preferences.petModeEnabled == false)
    #expect(preferences.petSelection == [:])
}

@Test
func preferencesRoundTripPetModeFields() throws {
    let preferences = UserPreferences(
        refreshProfile: .responsive,
        liveQuotaRefreshInterval: .fiveMinutes,
        providers: [.claude],
        accountQuotaConsents: [.claude],
        menuBarMetrics: [.weeklyPercentage],
        quotaDisplayMode: .used,
        notificationPreferences: QuotaNotificationPreferences(enabledKinds: [.windowReset]),
        petModeEnabled: true,
        showProviderNamesInPetMode: true,
        petSelection: [.claude: "calico", .codex: "cloudling"]
    )

    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(decoded == preferences)
}

@Test
func explicitlyEmptyAccountQuotaConsentSurvivesRoundTrip() throws {
    let preferences = UserPreferences(accountQuotaConsents: [])

    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(decoded.accountQuotaConsents.isEmpty)
    #expect((object["accountQuotaConsents"] as? [String]) == [])
}

@Test
func preferencesDecodePetSelectionObjectForm() throws {
    let data = """
    {
      "refreshProfile": "responsive",
      "providers": ["claude"],
      "petModeEnabled": true,
      "petSelection": {
        "claude": "calico",
        "codex": "cloudling",
        "unknown": "ignored"
      }
    }
    """.data(using: .utf8)!

    let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(preferences.refreshProfile == .responsive)
    #expect(preferences.providers == [.claude])
    #expect(preferences.petModeEnabled)
    #expect(preferences.petSelection == [.claude: "calico", .codex: "cloudling"])
}

@Test
func preferencesDecodeLegacyPetSelectionFlatArray() throws {
    let data = """
    {
      "petSelection": ["claude", "calico", "codex", "cloudling", "unknown", "ignored"]
    }
    """.data(using: .utf8)!

    let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(preferences.petSelection == [.claude: "calico", .codex: "cloudling"])
}

@Test
func preferencesDecodeMalformedPetSelectionAsEmptyWithoutDroppingPayload() throws {
    let data = """
    {
      "refreshProfile": "manual",
      "providers": ["codex"],
      "petModeEnabled": true,
      "petSelection": {
        "claude": 42
      }
    }
    """.data(using: .utf8)!

    let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

    #expect(preferences.refreshProfile == .manual)
    #expect(preferences.providers == [.codex])
    #expect(preferences.petModeEnabled)
    #expect(preferences.petSelection == [:])
}

@Test
func preferencesEncodePetSelectionAsObjectForm() throws {
    let preferences = UserPreferences(
        petSelection: [.claude: "calico", .codex: "cloudling"]
    )

    let data = try JSONEncoder().encode(preferences)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let petSelection = try #require(object["petSelection"] as? [String: String])

    #expect(petSelection == ["claude": "calico", "codex": "cloudling"])
}
