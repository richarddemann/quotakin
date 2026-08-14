import Foundation
import UsageCore

private enum ClaudeRecoveryAction {
    case connect
    case authorize
    case none
}

private struct ClaudeRecovery {
    let action: ClaudeRecoveryAction
    let detail: String?

    static func resolve(_ report: ProviderConnectionReport?) -> ClaudeRecovery {
        switch report?.issue {
        case .keychainAccessDenied:
            return ClaudeRecovery(
                action: .authorize,
                detail: "Quotakin cannot read Claude Code's saved account. Choose Grant Access to allow it once."
            )
        case .credentialExpired, .unauthorized:
            return ClaudeRecovery(
                action: .connect,
                detail: "Your Claude Code login has expired. Reconnect through Claude Code, then check again."
            )
        case .insufficientScope, .permissionDenied:
            return ClaudeRecovery(
                action: .connect,
                detail: "The saved Claude credential cannot read account usage. Reconnect Claude Code to restore account access."
            )
        case .mcpOnlyCredential:
            return ClaudeRecovery(
                action: .connect,
                detail: "Claude Code has MCP authorization, but no Claude account sign-in. Connect Claude to add account-wide quota."
            )
        case .noUsableQuota:
            return ClaudeRecovery(
                action: .none,
                detail: "Claude responded successfully but did not return a current general session or weekly quota. Check again later."
            )
        default:
            switch report?.state {
            case nil, .authenticationRequired, .unavailable:
                return ClaudeRecovery(action: .connect, detail: nil)
            case .permissionRequired:
                return ClaudeRecovery(action: .authorize, detail: nil)
            case .connected, .rateLimited:
                return ClaudeRecovery(action: .none, detail: nil)
            }
        }
    }
}

enum ProviderSetupActionKind: Hashable, Sendable {
    case signIn(Provider)
    case checkConnection(Provider)
    case authorizeClaudeAccount
    case installClaudeFallback
    case replaceClaudeFallback
    case uninstallClaudeFallback
}

struct ProviderSetupActionDescriptor: Identifiable, Hashable, Sendable {
    let kind: ProviderSetupActionKind
    let title: String

    var id: ProviderSetupActionKind { kind }
}

struct ProviderOnboardingDescriptor: Identifiable, Sendable {
    let provider: Provider
    let summary: String
    let steps: [String]
    let recommendedAction: @Sendable (ProviderConnectionReport?) -> ProviderSetupActionDescriptor?
    let checkAction: ProviderSetupActionDescriptor
    let fallbackInstallAction: ProviderSetupActionDescriptor?
    let fallbackMaintenanceActions: [ProviderSetupActionDescriptor]

    var id: Provider { provider }

    func primaryAction(for report: ProviderConnectionReport?) -> ProviderSetupActionDescriptor? {
        recommendedAction(report)
    }

    static let all = Provider.allCases.map(descriptor(for:))

    private static func descriptor(for provider: Provider) -> ProviderOnboardingDescriptor {
        switch provider {
        case .claude:
            let signIn = ProviderSetupActionDescriptor(
                kind: .signIn(provider),
                title: "Connect Claude"
            )
            let authorize = ProviderSetupActionDescriptor(
                kind: .authorizeClaudeAccount,
                title: "Grant Access…"
            )
            let check = ProviderSetupActionDescriptor(
                kind: .checkConnection(provider),
                title: "Check Again"
            )
            return ProviderOnboardingDescriptor(
                provider: provider,
                summary: "Connect your Claude subscription for account-wide limits. Local history remains separate.",
                steps: [
                    "Quotakin opens Claude's secure sign-in in your browser.",
                    "Complete sign-in with your Anthropic account.",
                    "Approve the Keychain prompt if macOS asks.",
                    "Quotakin verifies live quota automatically."
                ],
                recommendedAction: { report in
                    switch ClaudeRecovery.resolve(report).action {
                    case .authorize:
                        authorize
                    case .connect:
                        signIn
                    case .none:
                        nil
                    }
                },
                checkAction: check,
                fallbackInstallAction: ProviderSetupActionDescriptor(
                    kind: .installClaudeFallback,
                    title: "Install Helper"
                ),
                fallbackMaintenanceActions: [
                    ProviderSetupActionDescriptor(
                        kind: .replaceClaudeFallback,
                        title: "Replace Helper…"
                    ),
                    ProviderSetupActionDescriptor(
                        kind: .uninstallClaudeFallback,
                        title: "Uninstall Helper…"
                    )
                ]
            )
        case .codex:
            let signIn = ProviderSetupActionDescriptor(
                kind: .signIn(provider),
                title: "Connect Codex"
            )
            let check = ProviderSetupActionDescriptor(
                kind: .checkConnection(provider),
                title: "Check Connection"
            )
            return ProviderOnboardingDescriptor(
                provider: provider,
                summary: "Connect your Codex account for account-wide limits. Local history remains separate.",
                steps: [
                    "Quotakin opens Codex sign-in in your browser.",
                    "Complete sign-in with your OpenAI account.",
                    "Quotakin verifies live quota automatically."
                ],
                recommendedAction: { report in
                    switch report?.state {
                    case nil, .authenticationRequired, .permissionRequired, .unavailable:
                        signIn
                    case .connected, .rateLimited:
                        nil
                    }
                },
                checkAction: check,
                fallbackInstallAction: nil,
                fallbackMaintenanceActions: []
            )
        }
    }
}

enum ProviderConnectionVisualState: Equatable {
    case verifiedAccount
    case localOnly
    case pausedOrStale
    case needsAttention
    case unverified
}

struct ProviderOnboardingPresentation {
    let summary: ProviderSummary
    let connectionReport: ProviderConnectionReport?
    let now: Date
    let accountChecksAuthorized: Bool

    private var currentQuota: [QuotaSnapshot] {
        summary.quota.filter { $0.resetsAt > now }
    }

    private var hasAccountQuota: Bool {
        currentQuota.contains { $0.source == .account }
    }

    private var hasLocalQuota: Bool {
        currentQuota.contains { $0.source == .local }
    }

    private var newestAccountQuotaObservedAt: Date? {
        currentQuota
            .filter { $0.source == .account }
            .map(\.observedAt)
            .max()
    }

    private var hasNewerFailedProbe: Bool {
        guard let connectionReport, connectionReport.state != .connected else {
            return false
        }
        guard let newestAccountQuotaObservedAt else {
            return true
        }
        return connectionReport.checkedAt > newestAccountQuotaObservedAt
    }

    var statusTitle: String {
        if !accountChecksAuthorized {
            return "Account checks off"
        }
        if hasAccountQuota && !hasNewerFailedProbe {
            return "Connected"
        }
        if hasLocalQuota {
            return "Connected locally"
        }
        switch connectionReport?.state {
        case .authenticationRequired, .permissionRequired:
            return "Finish setup"
        case .rateLimited:
            return "Account check paused"
        case .unavailable:
            return "Unavailable"
        case .connected:
            return "Waiting for quota"
        case nil:
            return "Not checked"
        }
    }

    var sourceTitle: String {
        if !accountChecksAuthorized {
            if hasAccountQuota {
                return "Saved account quota"
            }
            if hasLocalQuota {
                return "Local quota"
            }
            return summary.tokens.isEmpty ? "No quota source" : "History only"
        }
        if hasAccountQuota {
            if hasNewerFailedProbe && hasLocalQuota {
                return "Local quota; account stale"
            }
            return hasNewerFailedProbe ? "Last-known account quota" : "Account quota"
        }
        if hasLocalQuota {
            return "Local quota"
        }
        if !summary.tokens.isEmpty {
            return "History only"
        }
        return "No data source"
    }

    var connectionSourceTitle: String {
        guard accountChecksAuthorized else {
            return "Checks off"
        }
        switch connectionReport?.source {
        case .claudeOAuth:
            return "Claude OAuth"
        case .codexAppServer:
            return "Codex CLI"
        case .accountProbe:
            return "Account probe"
        case nil:
            return "Not checked"
        }
    }

    var detail: String {
        if !accountChecksAuthorized {
            let saved = hasAccountQuota
                ? " Saved account quota remains visible until it resets."
                : ""
            return "Account checks are off. Quotakin will not refresh account-wide limits. Local history is unchanged.\(saved)"
        }
        if hasAccountQuota && !hasNewerFailedProbe {
            return "Quotakin can read current limits for this account."
        }
        if hasLocalQuota && !hasNewerFailedProbe {
            return "Current limits come from this Mac; other machines may not be reflected."
        }
        let failureDetail: String
        if summary.provider == .claude,
           let detail = ClaudeRecovery.resolve(connectionReport).detail {
            failureDetail = detail
        } else {
            switch connectionReport?.issue {
            case .clientMissing:
                failureDetail = "The provider client could not be started."
            case .timedOut:
                failureDetail = "The provider client did not respond in time."
            case .invalidResponse:
                failureDetail = "The provider returned an unreadable account response."
            case .requestRejected:
                failureDetail = "The provider rejected the account check."
            case .credentialsMissing, .keychainAccessDenied, .credentialExpired,
                 .insufficientScope, .unauthorized, .permissionDenied, .mcpOnlyCredential,
                 .rateLimited, .noUsableQuota, .unavailable, nil:
                failureDetail = ""
            }
        }

        let detail: String
        switch connectionReport?.state {
        case .authenticationRequired:
            detail = failureDetail.isEmpty
                ? "No Claude Code account credential was found. Connect Claude to add account-wide quota."
                : failureDetail
        case .permissionRequired:
            detail = failureDetail.isEmpty
                ? "The saved credential cannot read account usage."
                : failureDetail
        case .rateLimited:
            detail = "\(summary.provider.displayName) temporarily throttled Quotakin's account check. This does not mean your \(summary.provider.displayName) usage is exhausted."
        case .unavailable:
            detail = failureDetail.isEmpty
                ? "The account check failed. Check the provider setup and try again."
                : failureDetail
        case .connected:
            detail = "The account is reachable, but it returned no current quota windows."
        case nil:
            detail = "Run a connection check to verify account quota."
        }
        let retained = hasAccountQuota && hasNewerFailedProbe
            ? " Last-known quota remains visible until reset."
            : ""
        let localFallback = hasLocalQuota
            ? "Local quota is available. Account-wide quota is unavailable, but setup is optional. "
            : ""
        return localFallback + historyAware(detail + retained)
    }

    var needsAttention: Bool {
        guard accountChecksAuthorized else {
            return false
        }
        guard !hasLocalQuota else {
            return false
        }
        return hasNewerFailedProbe || !hasAccountQuota
    }

    var isConnectionEstablished: Bool {
        guard accountChecksAuthorized else {
            return false
        }
        return hasAccountQuota && !hasNewerFailedProbe
    }

    var shouldOfferAccountCheck: Bool {
        accountChecksAuthorized
            && !isConnectionEstablished
            && connectionReport?.state == .connected
    }

    var connectionVisualState: ProviderConnectionVisualState {
        guard accountChecksAuthorized else {
            return .pausedOrStale
        }
        if hasAccountQuota && !hasNewerFailedProbe {
            return .verifiedAccount
        }
        if hasLocalQuota {
            return .localOnly
        }
        switch connectionReport?.state {
        case .rateLimited:
            return .pausedOrStale
        case .authenticationRequired, .permissionRequired, .unavailable:
            return .needsAttention
        case .connected:
            return .pausedOrStale
        case nil:
            return .unverified
        }
    }

    private func historyAware(_ liveQuotaDetail: String) -> String {
        guard !summary.tokens.isEmpty else {
            return liveQuotaDetail
        }
        return "Local history is updating, but live quota is not connected. \(liveQuotaDetail)"
    }
}
