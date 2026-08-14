import Foundation

/// USD rates per million tokens. Reasoning tokens are deliberately absent:
/// providers report them as a subset of output tokens, not an additional billable category.
public struct ModelPricing: Equatable, Sendable {
    public let input: Decimal
    public let cacheWrite: Decimal
    public let cachedInput: Decimal
    public let output: Decimal

    public init(input: Decimal, cacheWrite: Decimal, cachedInput: Decimal, output: Decimal) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cachedInput = cachedInput
        self.output = output
    }
}

public struct EstimatedCost: Equatable, Sendable {
    public let input: Decimal
    public let cacheWrite: Decimal
    public let cachedInput: Decimal
    public let output: Decimal

    /// Always zero. Retained for source compatibility and to make the non-additive
    /// relationship between reasoning and output explicit to presentation code.
    public let reasoningOutput: Decimal

    public init(
        input: Decimal,
        cacheWrite: Decimal,
        cachedInput: Decimal,
        output: Decimal,
        reasoningOutput: Decimal = 0
    ) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cachedInput = cachedInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    public var total: Decimal { input + cacheWrite + cachedInput + output }
}

public struct CostEstimate: Equatable, Sendable {
    public let cost: EstimatedCost?
    public let amountUSD: Decimal?
    public let provenance: UsageCostProvenance

    public init(cost: EstimatedCost?, amountUSD: Decimal?, provenance: UsageCostProvenance) {
        self.cost = cost
        self.amountUSD = amountUSD
        self.provenance = provenance
    }
}

public enum PricingCatalogProvenance: String, Codable, Equatable, Sendable {
    case bundledAudited = "bundled-audited"
    case remoteLiteLLM = "remote-litellm"
}

public enum PricingCatalogStatus: String, Codable, Equatable, Sendable {
    case fallback
    case current
}

public enum PricingCatalogError: Error, Equatable, Sendable {
    case unknownModel(String)
    case invalidLiteLLMPayload
}

public struct PricingCatalog: Sendable {
    public let effectiveDate: String
    public let limitations: [String]
    public let provenance: PricingCatalogProvenance
    public let status: PricingCatalogStatus

    private let pricingByModel: [String: ModelPricing]
    private let modelAliases: [String: String]

    public init(
        effectiveDate: String,
        pricingByModel: [String: ModelPricing],
        modelAliases: [String: String] = [:],
        limitations: [String] = [],
        provenance: PricingCatalogProvenance = .bundledAudited,
        status: PricingCatalogStatus = .fallback
    ) {
        self.effectiveDate = effectiveDate
        self.pricingByModel = pricingByModel.reduce(into: [:]) { result, entry in
            result[Self.normalizeModelIdentifier(entry.key)] = entry.value
        }
        self.modelAliases = modelAliases.reduce(into: [:]) { result, entry in
            result[Self.normalizeModelIdentifier(entry.key)] = Self.normalizeModelIdentifier(entry.value)
        }
        self.limitations = limitations
        self.provenance = provenance
        self.status = status
    }

    /// Stable, deliberately conservative normalization for transcript identifiers and
    /// LiteLLM keys. It only removes well-known namespace prefixes; it never guesses a model family.
    public static func normalizeModelIdentifier(_ model: String) -> String {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix("models/") {
            normalized.removeFirst("models/".count)
        }
        for prefix in ["openai/", "anthropic/", "claude/"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            break
        }
        return normalized
    }

    public func pricing(for model: String) throws -> ModelPricing {
        let normalized = Self.normalizeModelIdentifier(model)
        let canonicalModel = modelAliases[normalized] ?? normalized
        guard let pricing = pricingByModel[canonicalModel] else {
            throw PricingCatalogError.unknownModel(model)
        }
        return pricing
    }

    public func estimatedCost(for sample: TokenSample) throws -> EstimatedCost {
        let pricing = try pricing(for: sample.model)
        return Self.calculateCost(for: sample, pricing: pricing)
    }

    /// Returns an explicit unpriced result rather than inventing a price for unknown models.
    /// A provider-reported cost, when supplied by a future collector, takes precedence over a model-rate estimate.
    public func costEstimate(
        for sample: TokenSample,
        providerReportedCostUSD: Decimal? = nil
    ) -> CostEstimate {
        if let providerReportedCostUSD = providerReportedCostUSD ?? sample.reportedCostUSD {
            return CostEstimate(
                cost: nil,
                amountUSD: providerReportedCostUSD,
                provenance: .providerReported
            )
        }
        guard let pricing = try? pricing(for: sample.model) else {
            return CostEstimate(cost: nil, amountUSD: nil, provenance: .unpriced)
        }
        let cost = Self.calculateCost(for: sample, pricing: pricing)
        return CostEstimate(
            cost: cost,
            amountUSD: cost.total,
            provenance: .modelPriced(
                catalogID: provenance.rawValue,
                effectiveDate: effectiveDate
            )
        )
    }

    public func costEstimate(for record: TranscriptUsageRecord) -> CostEstimate {
        costEstimate(
            for: record.tokenSample,
            providerReportedCostUSD: record.reportedCostUSD
        )
    }

    public func cacheSavings(for sample: TokenSample) -> Decimal? {
        guard let pricing = try? pricing(for: sample.model) else { return nil }
        return max(pricing.input - pricing.cachedInput, 0)
            * Decimal(sample.cachedInputTokens) / 1_000_000
    }

    private static func calculateCost(for sample: TokenSample, pricing: ModelPricing) -> EstimatedCost {
        EstimatedCost(
            input: pricing.input.cost(for: sample.inputTokens),
            cacheWrite: pricing.cacheWrite.cost(for: sample.cacheCreationInputTokens),
            cachedInput: pricing.cachedInput.cost(for: sample.cachedInputTokens),
            output: pricing.output.cost(for: sample.outputTokens),
            reasoningOutput: 0
        )
    }
}

public extension PricingCatalog {
    /// Audited, versioned fallback used when a remote catalogue is unavailable.
    static let bundled = PricingCatalog(
        effectiveDate: "2026-06-01",
        pricingByModel: [
            "claude-sonnet-4-6": ModelPricing(input: 3, cacheWrite: 3.75, cachedInput: 0.30, output: 15),
            "claude-opus-4-6": ModelPricing(input: 5, cacheWrite: 6.25, cachedInput: 0.50, output: 25),
            "claude-haiku-4-5-20251001": ModelPricing(input: 1, cacheWrite: 1.25, cachedInput: 0.10, output: 5),
            "gpt-5.2-codex": ModelPricing(input: 1.75, cacheWrite: 0, cachedInput: 0.175, output: 14),
        ],
        modelAliases: ["codex": "gpt-5.2-codex"],
        limitations: [
            "Claude cache creation tokens are estimated using the bundled cache-write rate because local transcripts may not distinguish cache TTL pricing.",
            "Reasoning output is a provider-reported subset of output and is not charged separately.",
        ],
        provenance: .bundledAudited,
        status: .fallback
    )
}

private extension Decimal {
    func cost(for tokens: Int) -> Decimal { self * Decimal(tokens) / 1_000_000 }
}
