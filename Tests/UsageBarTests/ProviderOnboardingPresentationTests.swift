import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func onboardingShowsConnectedAccountSource() {
    let now = Date(timeIntervalSince1970: 1_000)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .codex,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .weekly,
                    source: .account,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now
                )
            ],
            state: .fresh
        ),
        connectionReport: ProviderConnectionReport(
            provider: .codex,
            state: .connected,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Connected")
    #expect(presentation.sourceTitle == "Account quota")
    #expect(presentation.needsAttention == false)
    #expect(presentation.connectionVisualState == .verifiedAccount)
}

@Test
func connectedReportWithoutCurrentAccountQuotaIsNotVerified() {
    let now = Date(timeIntervalSince1970: 1_200)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .codex,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .weekly,
                    source: .account,
                    usedPercent: 20,
                    resetsAt: now,
                    observedAt: now.addingTimeInterval(-60)
                )
            ],
            state: .stale
        ),
        connectionReport: ProviderConnectionReport(
            provider: .codex,
            state: .connected,
            source: .codexAppServer,
            checkedAt: now.addingTimeInterval(-60)
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Waiting for quota")
    #expect(!presentation.isConnectionEstablished)
    #expect(presentation.connectionVisualState == .pausedOrStale)
    #expect(presentation.shouldOfferAccountCheck)
}

@Test
func revokedAccountChecksNeverPresentCachedQuotaAsConnected() {
    let now = Date(timeIntervalSince1970: 1_500)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .weekly,
                    source: .account,
                    usedPercent: 25,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now
                )
            ],
            state: .fresh
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .connected,
            source: .claudeOAuth,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: false
    )

    #expect(presentation.statusTitle == "Account checks off")
    #expect(presentation.sourceTitle == "Saved account quota")
    #expect(presentation.connectionSourceTitle == "Checks off")
    #expect(presentation.connectionVisualState == .pausedOrStale)
    #expect(!presentation.isConnectionEstablished)
    #expect(!presentation.needsAttention)
    #expect(presentation.detail.contains("will not refresh account-wide limits"))
    #expect(presentation.detail.contains("remains visible until it resets"))
}

@Test
func onboardingExplainsHistoryOnlyInsteadOfClaimingProviderIsAbsent() {
    let now = Date(timeIntervalSince1970: 1_000)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [
                TokenSample(
                    provider: .claude,
                    observedAt: now,
                    model: "claude-sonnet",
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15
                )
            ],
            quota: [],
            state: .fresh
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .authenticationRequired,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Finish setup")
    #expect(presentation.sourceTitle == "History only")
    #expect(
        presentation.detail
            == "Local history is updating, but live quota is not connected. No Claude Code account credential was found. Connect Claude to add account-wide quota."
    )
    #expect(presentation.needsAttention)
}

@Test
func newerAuthenticationFailureDoesNotPresentCachedQuotaAsConnected() {
    let now = Date(timeIntervalSince1970: 2_000)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .weekly,
                    source: .account,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now.addingTimeInterval(-600)
                )
            ],
            state: .stale
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .authenticationRequired,
            source: .claudeOAuth,
            issue: .credentialsMissing,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Finish setup")
    #expect(presentation.sourceTitle == "Last-known account quota")
    #expect(presentation.detail.contains("Last-known quota remains visible until reset."))
    #expect(presentation.needsAttention)
    #expect(presentation.connectionVisualState == .needsAttention)
}

@Test
func newerLocalSnapshotDoesNotHideAccountAuthenticationFailure() {
    let now = Date(timeIntervalSince1970: 3_000)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .weekly,
                    source: .account,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now.addingTimeInterval(-1_200)
                ),
                QuotaSnapshot(
                    provider: .claude,
                    window: .session,
                    source: .local,
                    usedPercent: 10,
                    resetsAt: now.addingTimeInterval(1_800),
                    observedAt: now
                )
            ],
            state: .fresh
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .authenticationRequired,
            source: .claudeOAuth,
            issue: .credentialsMissing,
            checkedAt: now.addingTimeInterval(-600)
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Connected locally")
    #expect(presentation.sourceTitle == "Local quota; account stale")
    #expect(presentation.detail.contains("Account-wide quota is unavailable"))
    #expect(presentation.needsAttention == false)
    #expect(presentation.connectionVisualState == .localOnly)
}

@Test
func localOnlyQuotaUsesANeutralConnectionState() {
    let now = Date(timeIntervalSince1970: 3_500)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .session,
                    source: .local,
                    usedPercent: 10,
                    resetsAt: now.addingTimeInterval(1_800),
                    observedAt: now
                )
            ],
            state: .fresh
        ),
        connectionReport: nil,
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Connected locally")
    #expect(presentation.connectionVisualState == .localOnly)
}

@Test
func rateLimitedLastKnownAccountQuotaUsesPausedState() {
    let now = Date(timeIntervalSince1970: 3_750)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .weekly,
                    source: .account,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600),
                    observedAt: now.addingTimeInterval(-600)
                )
            ],
            state: .stale
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .rateLimited,
            source: .claudeOAuth,
            issue: .rateLimited,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Account check paused")
    #expect(presentation.sourceTitle == "Last-known account quota")
    #expect(presentation.connectionVisualState == .pausedOrStale)
}

@Test
func everyProviderHasAnOnboardingDescriptor() {
    #expect(Set(ProviderOnboardingDescriptor.all.map(\.provider)) == Set(Provider.allCases))
    #expect(ProviderOnboardingDescriptor.all.allSatisfy { !$0.steps.isEmpty })
}

@Test
func claudeOnboardingRecommendsOnlyTheNextAccountAction() throws {
    let descriptor = try #require(
        ProviderOnboardingDescriptor.all.first { $0.provider == .claude }
    )

    #expect(descriptor.primaryAction(for: nil)?.kind == .signIn(.claude))
    #expect(descriptor.steps.contains("Approve the Keychain prompt if macOS asks."))
    #expect(descriptor.primaryAction(for: ProviderConnectionReport(
        provider: .claude,
        state: .authenticationRequired,
        source: .claudeOAuth,
        issue: .credentialsMissing,
        checkedAt: .now
    ))?.kind == .signIn(.claude))
    #expect(descriptor.primaryAction(for: ProviderConnectionReport(
        provider: .claude,
        state: .permissionRequired,
        source: .claudeOAuth,
        issue: .keychainAccessDenied,
        checkedAt: .now
    ))?.kind == .authorizeClaudeAccount)
    #expect(descriptor.primaryAction(for: ProviderConnectionReport(
        provider: .claude,
        state: .permissionRequired,
        source: .claudeOAuth,
        issue: .permissionDenied,
        checkedAt: .now
    ))?.kind == .signIn(.claude))
    #expect(descriptor.primaryAction(for: ProviderConnectionReport(
        provider: .claude,
        state: .rateLimited,
        source: .claudeOAuth,
        issue: .rateLimited,
        checkedAt: .now
    )) == nil)
    #expect(descriptor.primaryAction(for: ProviderConnectionReport(
        provider: .claude,
        state: .connected,
        source: .claudeOAuth,
        checkedAt: .now
    )) == nil)
}

@Test
func claudeOnboardingExplainsSpecificAuthenticationFailures() {
    let now = Date(timeIntervalSince1970: 4_500)
    let summary = ProviderSummary(
        provider: .claude,
        tokens: [],
        quota: [],
        state: .unavailable
    )

    let expired = ProviderOnboardingPresentation(
        summary: summary,
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .authenticationRequired,
            source: .claudeOAuth,
            issue: .credentialExpired,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )
    let denied = ProviderOnboardingPresentation(
        summary: summary,
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .permissionRequired,
            source: .claudeOAuth,
            issue: .keychainAccessDenied,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )
    let scope = ProviderOnboardingPresentation(
        summary: summary,
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .permissionRequired,
            source: .claudeOAuth,
            issue: .insufficientScope,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(expired.detail.contains("Claude Code login has expired"))
    #expect(denied.detail.contains("Grant Access"))
    #expect(scope.detail.contains("cannot read account usage"))
}

@Test
func claudeOnboardingExplainsMCPOnlyAndNoUsableQuotaWithoutSecrets() throws {
    let now = Date(timeIntervalSince1970: 4_600)
    let summary = ProviderSummary(provider: .claude, tokens: [], quota: [], state: .unavailable)
    let descriptor = try #require(
        ProviderOnboardingDescriptor.all.first { $0.provider == .claude }
    )
    let mcpReport = ProviderConnectionReport(
        provider: .claude,
        state: .authenticationRequired,
        source: .claudeOAuth,
        issue: .mcpOnlyCredential,
        checkedAt: now
    )
    let emptyReport = ProviderConnectionReport(
        provider: .claude,
        state: .unavailable,
        source: .claudeOAuth,
        issue: .noUsableQuota,
        checkedAt: now
    )

    let mcpPresentation = ProviderOnboardingPresentation(
        summary: summary,
        connectionReport: mcpReport,
        now: now,
        accountChecksAuthorized: true
    )
    let emptyPresentation = ProviderOnboardingPresentation(
        summary: summary,
        connectionReport: emptyReport,
        now: now,
        accountChecksAuthorized: true
    )

    #expect(descriptor.primaryAction(for: mcpReport)?.kind == .signIn(.claude))
    #expect(descriptor.primaryAction(for: emptyReport) == nil)
    #expect(mcpPresentation.detail.contains("MCP authorization"))
    #expect(emptyPresentation.detail.contains("did not return a current general session or weekly quota"))
    #expect(!mcpPresentation.detail.localizedCaseInsensitiveContains("token"))
}

@Test
func codexOnboardingStartsARealSignInFlow() throws {
    let descriptor = try #require(
        ProviderOnboardingDescriptor.all.first { $0.provider == .codex }
    )

    #expect(descriptor.primaryAction(for: nil)?.kind == .signIn(.codex))
    #expect(descriptor.steps.first == "Quotakin opens Codex sign-in in your browser.")
}

@Test
func fallbackMaintenanceActionsStayOutOfThePrimaryFlow() throws {
    let descriptor = try #require(
        ProviderOnboardingDescriptor.all.first { $0.provider == .claude }
    )

    #expect(descriptor.fallbackInstallAction?.kind == .installClaudeFallback)
    #expect(Set(descriptor.fallbackMaintenanceActions.map(\.kind)) == [
        .replaceClaudeFallback,
        .uninstallClaudeFallback
    ])
}

@Test
func claudeRequestThrottleIsNotPresentedAsUsageExhaustion() {
    let now = Date(timeIntervalSince1970: 4_000)
    let presentation = ProviderOnboardingPresentation(
        summary: ProviderSummary(
            provider: .claude,
            tokens: [
                TokenSample(
                    provider: .claude,
                    observedAt: now,
                    model: "claude-sonnet",
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15
                )
            ],
            quota: [],
            state: .fresh
        ),
        connectionReport: ProviderConnectionReport(
            provider: .claude,
            state: .rateLimited,
            source: .claudeOAuth,
            issue: .rateLimited,
            checkedAt: now
        ),
        now: now,
        accountChecksAuthorized: true
    )

    #expect(presentation.statusTitle == "Account check paused")
    #expect(presentation.detail.contains("does not mean your Claude usage is exhausted"))
}
