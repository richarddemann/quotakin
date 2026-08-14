import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

public enum QuotaWindow: String, Codable, CaseIterable, Sendable {
    case session
    case weekly
}

public enum QuotaSource: String, Codable, CaseIterable, Sendable {
    case account
    case local
}

public enum Freshness: String, Codable, Sendable {
    case fresh
    case stale
}

public struct TokenSample: Codable, Equatable, Sendable {
    public let provider: Provider
    public let observedAt: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    public let reportedCostUSD: Decimal?

    public init(
        provider: Provider,
        observedAt: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int,
        reportedCostUSD: Decimal? = nil
    ) {
        self.provider = provider
        self.observedAt = observedAt
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.reportedCostUSD = reportedCostUSD
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    public let window: QuotaWindow
    public let source: QuotaSource
    public let usedPercent: Double
    public let resetsAt: Date
    public let observedAt: Date

    public init(
        provider: Provider,
        window: QuotaWindow,
        source: QuotaSource = .local,
        usedPercent: Double,
        resetsAt: Date,
        observedAt: Date
    ) {
        self.provider = provider
        self.window = window
        self.source = source
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public func freshness(at now: Date) -> Freshness {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= 600 ? .fresh : .stale
    }

    public func isCurrent(at now: Date) -> Bool {
        freshness(at: now) == .fresh && resetsAt > now
    }

    public var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    public var clampedUsedPercent: Double {
        min(max(usedPercent, 0), 100)
    }
}

public enum CollectorState: String, Codable, Sendable {
    case fresh
    case stale
    case unavailable
    case sourceChanged
}

public struct ProviderSummary: Codable, Equatable, Sendable {
    public let provider: Provider
    public let tokens: [TokenSample]
    public let quota: [QuotaSnapshot]
    public let state: CollectorState

    public init(
        provider: Provider,
        tokens: [TokenSample],
        quota: [QuotaSnapshot],
        state: CollectorState
    ) {
        self.provider = provider
        self.tokens = tokens
        self.quota = quota
        self.state = state
    }
}

public enum ProviderConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case authenticationRequired
    case permissionRequired
    case rateLimited
    case unavailable
}

public enum ProviderConnectionSource: String, Codable, Equatable, Sendable {
    case accountProbe
    case claudeOAuth
    case codexAppServer
}

public enum ProviderConnectionIssue: String, Codable, Equatable, Sendable {
    case credentialsMissing
    case keychainAccessDenied
    case credentialExpired
    case mcpOnlyCredential
    case insufficientScope
    case unauthorized
    case clientMissing
    case permissionDenied
    case rateLimited
    case timedOut
    case invalidResponse
    case noUsableQuota
    case requestRejected
    case unavailable
}

/// Sanitized result of the provider's account-level connection probe.
/// It deliberately carries no credential, path, response body, or account identity.
public struct ProviderConnectionReport: Codable, Equatable, Sendable {
    public let provider: Provider
    public let state: ProviderConnectionState
    public let source: ProviderConnectionSource
    public let issue: ProviderConnectionIssue?
    public let checkedAt: Date

    public init(
        provider: Provider,
        state: ProviderConnectionState,
        source: ProviderConnectionSource = .accountProbe,
        issue: ProviderConnectionIssue? = nil,
        checkedAt: Date
    ) {
        self.provider = provider
        self.state = state
        self.source = source
        self.issue = issue
        self.checkedAt = checkedAt
    }
}

public struct DailyProviderTokenTotal: Codable, Equatable, Sendable {
    public let provider: Provider
    public let totalTokens: Int
    public let estimatedCost: Decimal
    public let unknownPricingSampleCount: Int

    public init(
        provider: Provider,
        totalTokens: Int,
        estimatedCost: Decimal = 0,
        unknownPricingSampleCount: Int = 0
    ) {
        self.provider = provider
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.unknownPricingSampleCount = unknownPricingSampleCount
    }
}

public struct DailyActivityGridDay: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let providerTotals: [DailyProviderTokenTotal]

    public init(dayStart: Date, providerTotals: [DailyProviderTokenTotal]) {
        self.dayStart = dayStart
        self.providerTotals = providerTotals
    }

    public var totalTokens: Int {
        providerTotals.reduce(0) { $0 + $1.totalTokens }
    }

    public var estimatedCost: Decimal {
        providerTotals.reduce(0) { $0 + $1.estimatedCost }
    }

    public var unknownPricingSampleCount: Int {
        providerTotals.reduce(0) { $0 + $1.unknownPricingSampleCount }
    }
}

public struct DailyActivityGrid: Codable, Equatable, Sendable {
    public let days: [DailyActivityGridDay]
    public let minTotalTokens: Int
    public let maxTotalTokens: Int

    public init(days: [DailyActivityGridDay], minTotalTokens: Int, maxTotalTokens: Int) {
        self.days = days
        self.minTotalTokens = minTotalTokens
        self.maxTotalTokens = maxTotalTokens
    }
}
