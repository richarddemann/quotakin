import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func unavailableProviderWithoutCurrentQuotaUsesCompactUnavailableCard() {
    let presentation = ProviderCardPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [
                TokenSample(
                    provider: .claude,
                    observedAt: Date(timeIntervalSince1970: 1_780_308_000),
                    model: "claude-sonnet-4-6",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120
                )
            ],
            quota: [],
            state: .unavailable
        ),
        quotaDisplayMode: .remaining,
        now: Date(timeIntervalSince1970: 1_780_308_100)
    )

    #expect(presentation.layout == .compactUnavailable)
    #expect(presentation.primaryTitle == "Claude")
    #expect(presentation.primarySubtitle == "No live quota available")
    #expect(presentation.shouldShowQuotaBars == false)
    #expect(presentation.shouldShowStatusBadge)
    #expect(presentation.badgeText == "Unavailable")
}

@Test
func providerWithCurrentQuotaKeepsQuotaGlanceCard() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let presentation = ProviderCardPresentation(
        summary: ProviderSummary(
            provider: .codex,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .session,
                    usedPercent: 40,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now.addingTimeInterval(-30)
                )
            ],
            state: .fresh
        ),
        quotaDisplayMode: .remaining,
        now: now
    )

    #expect(presentation.layout == .quotaGlance)
    #expect(presentation.primaryTitle == "60% left")
    #expect(presentation.primarySubtitle == "5-hour window")
    #expect(presentation.shouldShowQuotaBars)
    #expect(!presentation.shouldShowStatusBadge)
}

@Test
func staleUnexpiredQuotaStillShowsAsQuotaGlance() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let presentation = ProviderCardPresentation(
        summary: ProviderSummary(
            provider: .codex,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .session,
                    usedPercent: 40,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now.addingTimeInterval(-900)
                )
            ],
            state: .stale
        ),
        quotaDisplayMode: .remaining,
        now: now
    )

    #expect(presentation.layout == .quotaGlance)
    #expect(presentation.primaryTitle == "60% left")
    #expect(presentation.primarySubtitle == "Last live quota is stale")
    #expect(presentation.badgeText == "Stale")
    #expect(presentation.shouldShowStatusBadge)
}

@Test
func weeklyQuotaRemainsUsefulWhenSessionQuotaHasExpired() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let presentation = ProviderCardPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .session,
                    source: .account,
                    usedPercent: 80,
                    resetsAt: now.addingTimeInterval(-60),
                    observedAt: now.addingTimeInterval(-120)
                ),
                QuotaSnapshot(
                    provider: .claude,
                    window: .weekly,
                    source: .account,
                    usedPercent: 40,
                    resetsAt: now.addingTimeInterval(86_400),
                    observedAt: now.addingTimeInterval(-120)
                )
            ],
            state: .fresh
        ),
        quotaDisplayMode: .remaining,
        now: now
    )

    #expect(presentation.layout == .quotaGlance)
    #expect(presentation.primaryTitle == "60% left")
    #expect(presentation.primarySubtitle == "Weekly window")
}

@Test
func bothUsableWindowsRemainVisibleWithStableWindowOrderAndResetTiming() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let presentation = presentation(
        now: now,
        quota: [
            snapshot(window: .weekly, resetsAt: now.addingTimeInterval(3 * 86_400), observedAt: now),
            snapshot(window: .session, resetsAt: now.addingTimeInterval(2 * 3_600), observedAt: now)
        ]
    )

    #expect(presentation.usableQuotas.map(\.window) == [.session, .weekly])
    #expect(presentation.quotaLineText(for: presentation.usableQuotas[0]).contains("Resets"))
    #expect(presentation.quotaLineText(for: presentation.usableQuotas[1]).contains("Resets"))
}

@Test
func provenanceIsAlwaysTruthfulAndMixedSourcesAreAttributedPerWindow() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let account = snapshot(
        window: .session,
        source: .account,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now.addingTimeInterval(-120)
    )
    let local = snapshot(
        window: .weekly,
        source: .local,
        resetsAt: now.addingTimeInterval(86_400),
        observedAt: now.addingTimeInterval(-900)
    )
    let presentation = presentation(now: now, quota: [local, account])

    #expect(presentation.sourcesMateriallyDiffer)
    #expect(presentation.sourceDetail(for: account) == "5-hour: Account quota · updated 2m ago")
    #expect(presentation.sourceDetail(for: local) == "Weekly: Last known on this Mac · updated 15m ago")
}

@Test
func sharedFreshAccountProvenanceUsesOneUnattributedLine() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let presentation = presentation(
        now: now,
        quota: [
            snapshot(window: .session, source: .account, resetsAt: now.addingTimeInterval(3_600), observedAt: now),
            snapshot(window: .weekly, source: .account, resetsAt: now.addingTimeInterval(86_400), observedAt: now)
        ]
    )

    #expect(!presentation.sourcesMateriallyDiffer)
    #expect(presentation.sourceDetail(for: presentation.primaryQuota!) == "Account quota · updated now")
    #expect(presentation.sourceDetail(for: presentation.secondaryQuota!) == nil)
}

@Test
func freshLocalAndLastKnownAccountProvenanceAreExplicit() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let freshLocal = presentation(now: now, quota: [
        snapshot(window: .session, source: .local, resetsAt: now.addingTimeInterval(3_600), observedAt: now)
    ])
    let staleAccount = presentation(now: now, quota: [
        snapshot(
            window: .session,
            source: .account,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now.addingTimeInterval(-900)
        )
    ])

    #expect(freshLocal.sourceDetail(for: freshLocal.primaryQuota!) == "This Mac only · updated now")
    #expect(staleAccount.sourceDetail(for: staleAccount.primaryQuota!) == "Last known account quota · updated 15m ago")
}

@Test
func mixedFreshnessAttributesSharedSourcePerWindow() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let session = snapshot(
        window: .session,
        source: .account,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now.addingTimeInterval(-900)
    )
    let weekly = snapshot(
        window: .weekly,
        source: .account,
        resetsAt: now.addingTimeInterval(86_400),
        observedAt: now
    )
    let presentation = presentation(now: now, quota: [session, weekly])

    #expect(presentation.sourcesMateriallyDiffer)
    #expect(presentation.sourceDetail(for: session)?.contains("5-hour: Last known account quota") == true)
    #expect(presentation.sourceDetail(for: weekly)?.contains("Weekly: Account quota") == true)
}

@Test
func materiallyDifferentSourceAgesAreAttributedPerWindow() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let session = snapshot(
        window: .session,
        source: .account,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now.addingTimeInterval(-60)
    )
    let weekly = snapshot(
        window: .weekly,
        source: .account,
        resetsAt: now.addingTimeInterval(86_400),
        observedAt: now.addingTimeInterval(-540)
    )
    let presentation = presentation(now: now, quota: [session, weekly])

    #expect(presentation.sourcesMateriallyDiffer)
    #expect(presentation.sourceDetail(for: session)?.contains("updated 1m ago") == true)
    #expect(presentation.sourceDetail(for: weekly)?.contains("updated 9m ago") == true)
}

@Test
func bothLimitsOnTrackRequiresTwoMatchedFreshConfidentPredictions() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let session = snapshot(window: .session, resetsAt: now.addingTimeInterval(3_600), observedAt: now)
    let weekly = snapshot(window: .weekly, resetsAt: now.addingTimeInterval(86_400), observedAt: now)
    let presentation = presentation(now: now, quota: [session, weekly])
    let sessionSafe = prediction(for: session, observedAt: now, burnRate: 0, verdict: .onTrack)
    let weeklySafe = prediction(for: weekly, observedAt: now, burnRate: 0, verdict: .onTrack)

    #expect(presentation.paceDetail(from: [sessionSafe]) == nil)
    #expect(presentation.paceDetail(from: [sessionSafe, weeklySafe])?.text == "Both limits on track")
    #expect(presentation.paceDetail(from: [
        sessionSafe,
        prediction(
            for: weekly,
            source: .local,
            observedAt: now,
            burnRate: 0,
            verdict: .onTrack
        )
    ]) == nil)
}

@Test
func paceVerdictRequiresProviderWindowSourceResetCycleAndFreshPrediction() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let session = snapshot(
        window: .session,
        source: .account,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now
    )
    let presentation = presentation(now: now, quota: [session])
    let base = prediction(for: session, observedAt: now, verdict: .atRisk(projectedAt: now.addingTimeInterval(600)))

    #expect(presentation.paceDetail(from: [base])?.text.contains("5-hour limit runs out") == true)
    #expect(presentation.paceDetail(from: [prediction(
        for: session,
        provider: .claude,
        observedAt: now,
        verdict: base.verdict
    )]) == nil)
    #expect(presentation.paceDetail(from: [prediction(
        for: session,
        source: .local,
        observedAt: now,
        verdict: base.verdict
    )]) == nil)
    #expect(presentation.paceDetail(from: [prediction(
        for: session,
        resetsAt: session.resetsAt.addingTimeInterval(60),
        observedAt: now,
        verdict: base.verdict
    )]) == nil)
    #expect(presentation.paceDetail(from: [prediction(
        for: session,
        observedAt: now.addingTimeInterval(-601),
        verdict: base.verdict
    )]) == nil)
}

@Test
func pacePrimaryCopyIsHumanConsequenceAndRawTelemetryIsDetail() {
    let now = Date(timeIntervalSince1970: 1_780_308_100)
    let session = snapshot(window: .session, resetsAt: now.addingTimeInterval(3_600), observedAt: now)
    let presentation = presentation(now: now, quota: [session])
    let detail = presentation.paceDetail(from: [
        prediction(
            for: session,
            observedAt: now,
            burnRate: 44,
            verdict: .atRisk(projectedAt: now.addingTimeInterval(600))
        )
    ])

    #expect(detail?.text.contains("At this pace, the 5-hour limit runs out around") == true)
    #expect(detail?.text.contains("%/hr") == false)
    #expect(detail?.telemetryDetail.contains("44%/hr") == true)
    #expect(detail?.telemetryDetail.contains("90m lookback") == true)
    #expect(detail?.window == .session)
    #expect(presentation.accessibilitySummary(from: [
        prediction(
            for: session,
            observedAt: now,
            burnRate: 44,
            verdict: .atRisk(projectedAt: now.addingTimeInterval(600))
        )
    ]).hasPrefix("Codex. 5-hour, 60% left, Resets"))
}

private func presentation(now: Date, quota: [QuotaSnapshot]) -> ProviderCardPresentation {
    ProviderCardPresentation(
        summary: ProviderSummary(provider: .codex, tokens: [], quota: quota, state: .fresh),
        quotaDisplayMode: .remaining,
        now: now
    )
}

private func snapshot(
    window: QuotaWindow,
    source: QuotaSource = .account,
    resetsAt: Date,
    observedAt: Date
) -> QuotaSnapshot {
    QuotaSnapshot(
        provider: .codex,
        window: window,
        source: source,
        usedPercent: 40,
        resetsAt: resetsAt,
        observedAt: observedAt
    )
}

private func prediction(
    for snapshot: QuotaSnapshot,
    provider: Provider? = nil,
    source: QuotaSource? = nil,
    resetsAt: Date? = nil,
    observedAt: Date,
    burnRate: Double? = 44,
    verdict: QuotaLimitVerdict
) -> QuotaLimitPrediction {
    QuotaLimitPrediction(
        provider: provider ?? snapshot.provider,
        window: snapshot.window,
        source: source ?? snapshot.source,
        observedAt: observedAt,
        resetsAt: resetsAt ?? snapshot.resetsAt,
        usedPercent: snapshot.usedPercent,
        burnRatePercentPerHour: burnRate,
        lookback: 90 * 60,
        verdict: verdict,
        pace: QuotaPace(
            idealUsedPercent: 20,
            reservePercent: 0,
            deficitPercent: 20,
            isOnPace: false,
            runsOutIn: 600,
            lastsUntilReset: false
        )
    )
}
