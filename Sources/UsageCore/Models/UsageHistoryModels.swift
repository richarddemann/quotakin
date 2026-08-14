import Foundation

public enum UsageHistoryRange: String, CaseIterable, Codable, Sendable {
    case fiveHours
    case twentyFourHours
    case sevenDays
    case thirtyDays
    case ninetyDays

    public var bucketSize: UsageHistoryBucketSize {
        switch self {
        case .fiveHours:
            .fifteenMinutes
        case .twentyFourHours:
            .hour
        case .sevenDays, .thirtyDays, .ninetyDays:
            .day
        }
    }

    public func startDate(endingAt endDate: Date, calendar: Calendar) -> Date {
        switch self {
        case .fiveHours:
            calendar.date(byAdding: .hour, value: -5, to: endDate) ?? endDate
        case .twentyFourHours:
            calendar.date(byAdding: .hour, value: -24, to: endDate) ?? endDate
        case .sevenDays:
            calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: endDate)) ?? endDate
        case .thirtyDays:
            calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: endDate)) ?? endDate
        case .ninetyDays:
            calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: endDate)) ?? endDate
        }
    }
}

public enum UsageHistoryBucketSize: String, Codable, Sendable {
    case fifteenMinutes
    case hour
    case day
}

public struct TokenCategoryTotals: Codable, Equatable, Sendable {
    public let input: Int
    public let output: Int
    public let cachedInput: Int
    public let cacheCreationInput: Int
    public let reasoningOutput: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cachedInput: Int = 0,
        cacheCreationInput: Int = 0,
        reasoningOutput: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.cacheCreationInput = cacheCreationInput
        self.reasoningOutput = reasoningOutput
    }

    public var total: Int {
        input + output + cachedInput + cacheCreationInput
    }

    func adding(_ sample: TokenSample) -> TokenCategoryTotals {
        TokenCategoryTotals(
            input: input + sample.inputTokens,
            output: output + sample.outputTokens,
            cachedInput: cachedInput + sample.cachedInputTokens,
            cacheCreationInput: cacheCreationInput + sample.cacheCreationInputTokens,
            reasoningOutput: reasoningOutput + sample.reasoningOutputTokens
        )
    }
}

public struct UsageHistoryBucket: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let tokens: TokenCategoryTotals
    public let estimatedCost: Decimal
    public let estimatedCostProvenance: UsageCostProvenance
    public let unknownPricingSampleCount: Int

    public init(
        start: Date,
        end: Date,
        tokens: TokenCategoryTotals = TokenCategoryTotals(),
        estimatedCost: Decimal = 0,
        estimatedCostProvenance: UsageCostProvenance = .unpriced,
        unknownPricingSampleCount: Int = 0
    ) {
        self.start = start
        self.end = end
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.estimatedCostProvenance = estimatedCostProvenance
        self.unknownPricingSampleCount = unknownPricingSampleCount
    }
}

public struct QuotaHistoryPoint: Codable, Equatable, Sendable {
    public let window: QuotaWindow
    public let source: QuotaSource
    public let observedAt: Date
    public let usedPercent: Double
    public let resetsAt: Date

    public init(
        window: QuotaWindow,
        source: QuotaSource,
        observedAt: Date,
        usedPercent: Double,
        resetsAt: Date
    ) {
        self.window = window
        self.source = source
        self.observedAt = observedAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsageHistory: Codable, Equatable, Sendable {
    public let provider: Provider
    public let buckets: [UsageHistoryBucket]
    public let quotaPercentSeries: [QuotaHistoryPoint]

    public init(
        provider: Provider,
        buckets: [UsageHistoryBucket],
        quotaPercentSeries: [QuotaHistoryPoint] = []
    ) {
        self.provider = provider
        self.buckets = buckets
        self.quotaPercentSeries = quotaPercentSeries
    }
}

public struct UsageHistorySeries: Codable, Equatable, Sendable {
    public let range: UsageHistoryRange
    public let bucketSize: UsageHistoryBucketSize
    public let start: Date
    public let end: Date
    public let providers: [ProviderUsageHistory]

    public init(
        range: UsageHistoryRange,
        bucketSize: UsageHistoryBucketSize,
        start: Date,
        end: Date,
        providers: [ProviderUsageHistory]
    ) {
        self.range = range
        self.bucketSize = bucketSize
        self.start = start
        self.end = end
        self.providers = providers
    }
}
