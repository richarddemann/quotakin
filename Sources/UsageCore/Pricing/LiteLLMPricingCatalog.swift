import Foundation

/// The stable subset of LiteLLM's `model_prices_and_context_window.json` schema
/// needed for local accounting. Unknown fields are intentionally ignored.
public struct LiteLLMPricingEntry: Decodable, Sendable {
    public let inputCostPerToken: Decimal?
    public let outputCostPerToken: Decimal?
    public let cacheReadInputTokenCost: Decimal?
    public let cacheCreationInputTokenCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case cacheReadInputTokenCost = "cache_read_input_token_cost"
        case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
    }
}

public extension PricingCatalog {
    /// Parses a LiteLLM model-price document into a current remote catalogue.
    /// Models without both base input and output rates are excluded rather than guessed.
    static func liteLLM(
        data: Data,
        effectiveDate: String,
        aliases: [String: String] = [:],
        limitations: [String] = []
    ) throws -> PricingCatalog {
        let entries = try JSONDecoder().decode([String: LiteLLMPricingEntry].self, from: data)
        let prices = entries.reduce(into: [String: ModelPricing]()) { result, element in
            let (model, entry) = element
            guard let input = entry.inputCostPerToken, let output = entry.outputCostPerToken else { return }
            result[model] = ModelPricing(
                input: input * 1_000_000,
                cacheWrite: (entry.cacheCreationInputTokenCost ?? input) * 1_000_000,
                cachedInput: (entry.cacheReadInputTokenCost ?? input) * 1_000_000,
                output: output * 1_000_000
            )
        }
        guard !prices.isEmpty else { throw PricingCatalogError.invalidLiteLLMPayload }
        return PricingCatalog(
            effectiveDate: effectiveDate,
            pricingByModel: prices,
            modelAliases: aliases,
            limitations: limitations + ["Rates were parsed from a LiteLLM-compatible remote catalogue."],
            provenance: .remoteLiteLLM,
            status: .current
        )
    }
}
