import Foundation
import Testing
@testable import UsageCore

private let fixedNow = Date(timeIntervalSince1970: 1_000)
private let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

@Test
func defaultLabelUsesIconOnlyToPreserveMenuBarSpace() {
    let label = MenuBarFormatter().label(
        summaries: [
            summary(
                provider: .claude,
                sessionPercent: 42,
                sessionReset: fixedNow.addingTimeInterval(78 * 60)
            ),
            summary(
                provider: .codex,
                sessionPercent: 68,
                sessionReset: fixedNow.addingTimeInterval(184 * 60)
            ),
        ],
        preferences: .default,
        now: fixedNow
    )

    #expect(label == "")
}

@Test
func defaultIconOnlyModeUsesSelectedProviderIcons() {
    #expect(MenuBarFormatter().iconProviders(preferences: .default) == [.claude, .codex])
    #expect(
        MenuBarFormatter().iconProviders(
            preferences: UserPreferences(providers: [.claude], menuBarMetrics: [])
        ) == [.claude]
    )
    #expect(
        MenuBarFormatter().iconProviders(
            preferences: UserPreferences(providers: [.claude], menuBarMetrics: [.sessionPercentage])
        ) == []
    )
    #expect(MenuBarFormatter().iconProviders(preferences: UserPreferences.iconOnly) == [])
}

@Test
func formatterReturnsProviderTextSegments() {
    let preferences = UserPreferences(menuBarMetrics: [.sessionPercentage])

    let segments = MenuBarFormatter().segments(
        summaries: [
            summary(
                provider: .claude,
                sessionPercent: 42,
                sessionReset: fixedNow.addingTimeInterval(78 * 60)
            ),
            summary(
                provider: .codex,
                sessionPercent: 68,
                sessionReset: fixedNow.addingTimeInterval(184 * 60)
            ),
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(
        segments == [
            MenuBarTextSegment(provider: .claude, text: "Claude 58% left"),
            MenuBarTextSegment(provider: .codex, text: "Codex 32% left"),
        ]
    )
}

@Test
func iconOnlyPreferenceProducesNoMetricText() {
    let label = MenuBarFormatter().label(
        summaries: [],
        preferences: .iconOnly,
        now: fixedNow
    )

    #expect(label == "")
}

@Test
func weeklyMetricsUseWeeklyQuotaAndResetCountdown() {
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.weeklyPercentage, .resetCountdown]
    )

    let label = MenuBarFormatter().label(
        summaries: [
            summary(
                provider: .claude,
                weeklyPercent: 12.5,
                weeklyReset: fixedNow.addingTimeInterval(25 * 60)
            ),
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(label == "Claude 87.5% left 25m")
}

@Test
func weeklyCountdownUsesDaysAndHoursForLongResetWindows() {
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.weeklyPercentage, .resetCountdown]
    )

    let label = MenuBarFormatter().label(
        summaries: [
            summary(
                provider: .claude,
                weeklyPercent: 12.5,
                weeklyReset: fixedNow.addingTimeInterval((5 * 24 * 60 * 60) + (4 * 60 * 60))
            ),
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(label == "Claude 87.5% left 5d 4h")
}

@Test
func quotaDisplayModeCanShowUsedPercentagesInMenuBar() {
    let preferences = UserPreferences(
        providers: [.claude, .codex],
        menuBarMetrics: [.sessionPercentage, .resetCountdown, .weeklyPercentage],
        quotaDisplayMode: .used
    )

    let label = MenuBarFormatter().label(
        summaries: [
            summary(
                provider: .claude,
                sessionPercent: 42,
                sessionReset: fixedNow.addingTimeInterval(78 * 60),
                weeklyPercent: 12.5,
                weeklyReset: fixedNow.addingTimeInterval(25 * 60)
            ),
            summary(
                provider: .codex,
                sessionPercent: 45,
                sessionReset: fixedNow.addingTimeInterval(246 * 60),
                weeklyPercent: 39,
                weeklyReset: fixedNow.addingTimeInterval(7 * 24 * 60 * 60)
            )
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(label == "Claude 42/12% used 1h 18m  •  Codex 45/39% used 4h")
}

@Test
func multiPercentMenuBarLabelKeepsResetAtEndAndUnavailableCompact() {
    let preferences = UserPreferences(
        providers: [.claude, .codex],
        menuBarMetrics: [.sessionPercentage, .resetCountdown, .weeklyPercentage]
    )

    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(provider: .claude, tokens: [], quota: [], state: .unavailable),
            summary(
                provider: .codex,
                sessionPercent: 45,
                sessionReset: fixedNow.addingTimeInterval(246 * 60),
                weeklyPercent: 39,
                weeklyReset: fixedNow.addingTimeInterval(7 * 24 * 60 * 60)
            )
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(label == "Claude no data  •  Codex 55/61% left 4h")
}

@Test
func unavailableProvidersOnlyShowCompactFallbackWhenNoLiveDataExists() {
    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(provider: .claude, tokens: [], quota: [], state: .unavailable),
            ProviderSummary(provider: .codex, tokens: [], quota: [], state: .unavailable),
        ],
        preferences: UserPreferences(menuBarMetrics: [.sessionPercentage]),
        now: fixedNow
    )

    #expect(label == "Claude no data  •  Codex no data")
}

@Test
func unavailableProviderWithObservedTokensStillAppearsBesideLiveQuota() {
    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: fixedNow, total: 1_200),
                ],
                quota: [],
                state: .unavailable
            ),
            summary(
                provider: .codex,
                sessionPercent: 68,
                sessionReset: fixedNow.addingTimeInterval(184 * 60)
            ),
        ],
        preferences: UserPreferences(menuBarMetrics: [.sessionPercentage]),
        now: fixedNow
    )

    #expect(label == "Claude 1.2K  •  Codex 32% left")
}

@Test
func providerPreferencesControlWhichProvidersAppearInMenuBar() {
    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: fixedNow, total: 1_200),
                ],
                quota: [],
                state: .unavailable
            ),
            summary(
                provider: .codex,
                sessionPercent: 68,
                sessionReset: fixedNow.addingTimeInterval(184 * 60)
            ),
        ],
        preferences: UserPreferences(providers: [.codex], menuBarMetrics: [.sessionPercentage]),
        now: fixedNow
    )

    #expect(label == "Codex 32% left")
}

@Test
func tokenWindowsSumProviderTokensInSelectedWindow() {
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.dailyTokens, .weeklyTokens, .monthlyTokens]
    )
    let now = date(year: 2026, month: 6, day: 5, hour: 12, minute: 0)

    let label = MenuBarFormatter(calendar: calendar).label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: date(year: 2026, month: 6, day: 5, hour: 10), total: 1_200),
                    token(provider: .claude, observedAt: date(year: 2026, month: 6, day: 3, hour: 10), total: 34_000),
                    token(provider: .claude, observedAt: date(year: 2026, month: 5, day: 27, hour: 10), total: 5_000_000),
                    token(provider: .claude, observedAt: date(year: 2026, month: 4, day: 26, hour: 10), total: 9_000_000),
                ],
                quota: [],
                state: .fresh
            ),
        ],
        preferences: preferences,
        now: now
    )

    #expect(label == "Claude 1.2K today · 35.2K week · 35.2K month")
}

@Test
func estimatedMonthlyCostUsesKnownPricingAndFormatsCurrency() {
    let preferences = UserPreferences(
        providers: [.claude, .codex],
        menuBarMetrics: [.estimatedMonthlyCost]
    )

    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(
                        provider: .claude,
                        observedAt: fixedNow,
                        model: "claude-sonnet-4-6",
                        input: 1_000_000,
                        output: 1_000_000,
                        total: 2_000_000
                    ),
                ],
                quota: [],
                state: .fresh
            ),
            ProviderSummary(
                provider: .codex,
                tokens: [
                    token(
                        provider: .codex,
                        observedAt: fixedNow,
                        model: "codex",
                        input: 1_000_000,
                        output: 1_000_000,
                        reasoning: 500_000,
                        total: 2_000_000
                    ),
                ],
                quota: [],
                state: .fresh
            ),
        ],
        preferences: preferences,
        now: fixedNow
    )

    #expect(label == "Claude $18.00/mo  •  Codex $15.75/mo")
}

@Test
func gracefulOutputForUnavailableStaleAndSourceChangedSummaries() {
    let preferences = UserPreferences(
        providers: [.claude, .codex],
        menuBarMetrics: [.sessionPercentage, .resetCountdown]
    )

    let unavailableLabel = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(provider: .claude, tokens: [], quota: [], state: .unavailable),
        ],
        preferences: preferences,
        now: fixedNow
    )
    let staleLabel = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [],
                quota: [
                    QuotaSnapshot(
                        provider: .claude,
                        window: .session,
                        usedPercent: 42,
                        resetsAt: fixedNow.addingTimeInterval(-60),
                        observedAt: fixedNow.addingTimeInterval(-601)
                    ),
                ],
                state: .stale
            ),
        ],
        preferences: UserPreferences(providers: [.claude], menuBarMetrics: [.sessionPercentage, .resetCountdown]),
        now: fixedNow
    )
    let sourceChangedLabel = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(provider: .codex, tokens: [], quota: [], state: .sourceChanged),
        ],
        preferences: UserPreferences(providers: [.codex], menuBarMetrics: [.sessionPercentage]),
        now: fixedNow
    )

    #expect(unavailableLabel == "Claude no data")
    #expect(staleLabel == "Claude no quota")
    #expect(sourceChangedLabel == "Codex updating")
}

@Test
func staleQuotaIsNotDisplayedAsLiveCapacity() {
    let label = MenuBarFormatter().label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: fixedNow.addingTimeInterval(-60), total: 1_000),
                ],
                quota: [
                    QuotaSnapshot(
                        provider: .claude,
                        window: .session,
                        usedPercent: 42,
                        resetsAt: fixedNow.addingTimeInterval(60),
                        observedAt: fixedNow.addingTimeInterval(-3 * 60 * 60)
                    ),
                ],
                state: .stale
            ),
        ],
        preferences: UserPreferences(providers: [.claude], menuBarMetrics: [.sessionPercentage]),
        now: fixedNow
    )

    #expect(label == "Claude 1K")
}

@Test
func tokenWindowsUseCalendarDayAndMonthBoundaries() {
    let now = date(year: 2026, month: 6, day: 1, hour: 0, minute: 5)
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.dailyTokens, .monthlyTokens]
    )

    let label = MenuBarFormatter(calendar: calendar).label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: date(year: 2026, month: 5, day: 31, hour: 23, minute: 55), total: 100_000),
                    token(provider: .claude, observedAt: date(year: 2026, month: 6, day: 1, hour: 0, minute: 1), total: 2_000),
                ],
                quota: [],
                state: .fresh
            ),
        ],
        preferences: preferences,
        now: now
    )

    #expect(label == "Claude 2K today · 2K month")
}

@Test
func estimatedMonthlyCostUsesCalendarMonthBoundary() {
    let now = date(year: 2026, month: 6, day: 1, hour: 0, minute: 5)
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.estimatedMonthlyCost]
    )

    let label = MenuBarFormatter(calendar: calendar).label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(
                        provider: .claude,
                        observedAt: date(year: 2026, month: 5, day: 31, hour: 23, minute: 55),
                        input: 1_000_000,
                        output: 1_000_000,
                        total: 2_000_000
                    ),
                    token(
                        provider: .claude,
                        observedAt: date(year: 2026, month: 6, day: 1, hour: 0, minute: 1),
                        input: 1_000_000,
                        output: 0,
                        total: 1_000_000
                    ),
                ],
                quota: [],
                state: .fresh
            ),
        ],
        preferences: preferences,
        now: now
    )

    #expect(label == "Claude $3.00/mo")
}

@Test
func compactTokenFormattingPromotesRoundedThousandKToOneMillion() {
    let preferences = UserPreferences(
        providers: [.claude],
        menuBarMetrics: [.dailyTokens]
    )

    let label = MenuBarFormatter(calendar: calendar).label(
        summaries: [
            ProviderSummary(
                provider: .claude,
                tokens: [
                    token(provider: .claude, observedAt: date(year: 2026, month: 6, day: 5, hour: 12), total: 999_950),
                ],
                quota: [],
                state: .fresh
            ),
        ],
        preferences: preferences,
        now: date(year: 2026, month: 6, day: 5, hour: 13)
    )

    #expect(label == "Claude 1M today")
}

private func summary(
    provider: Provider,
    sessionPercent: Double? = nil,
    sessionReset: Date? = nil,
    weeklyPercent: Double? = nil,
    weeklyReset: Date? = nil
) -> ProviderSummary {
    var quota: [QuotaSnapshot] = []
    if let sessionPercent, let sessionReset {
        quota.append(
            QuotaSnapshot(
                provider: provider,
                window: .session,
                usedPercent: sessionPercent,
                resetsAt: sessionReset,
                observedAt: fixedNow
            )
        )
    }
    if let weeklyPercent, let weeklyReset {
        quota.append(
            QuotaSnapshot(
                provider: provider,
                window: .weekly,
                usedPercent: weeklyPercent,
                resetsAt: weeklyReset,
                observedAt: fixedNow
            )
        )
    }

    return ProviderSummary(provider: provider, tokens: [], quota: quota, state: .fresh)
}

private func token(
    provider: Provider,
    observedAt: Date,
    model: String = "claude-sonnet-4-6",
    input: Int = 0,
    output: Int = 0,
    reasoning: Int = 0,
    total: Int
) -> TokenSample {
    TokenSample(
        provider: provider,
        observedAt: observedAt,
        model: model,
        inputTokens: input,
        outputTokens: output,
        reasoningOutputTokens: reasoning,
        totalTokens: total
    )
}

private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0
) -> Date {
    calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}
