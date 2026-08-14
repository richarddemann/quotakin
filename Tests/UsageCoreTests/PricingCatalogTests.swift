import Foundation
import Testing
@testable import UsageCore

private let oneMillion = 1_000_000

@Test
func bundledPricingCatalogHasExpectedEffectiveDateAndRates() throws {
    let catalog = PricingCatalog.bundled

    #expect(catalog.effectiveDate == "2026-06-01")
    #expect(
        try catalog.pricing(for: "claude-sonnet-4-6")
            == ModelPricing(
                input: 3,
                cacheWrite: 3.75,
                cachedInput: 0.30,
                output: 15
            )
    )
    #expect(
        try catalog.pricing(for: "claude-opus-4-6")
            == ModelPricing(
                input: 5,
                cacheWrite: 6.25,
                cachedInput: 0.50,
                output: 25
            )
    )
    #expect(
        try catalog.pricing(for: "claude-haiku-4-5-20251001")
            == ModelPricing(
                input: 1,
                cacheWrite: 1.25,
                cachedInput: 0.10,
                output: 5
            )
    )
    #expect(
        try catalog.pricing(for: "gpt-5.2-codex")
            == ModelPricing(
                input: 1.75,
                cacheWrite: 0,
                cachedInput: 0.175,
                output: 14
            )
    )
}

@Test
func sonnetEstimatePricesEachTokenCategoryIndependently() throws {
    let sample = TokenSample(
        provider: .claude,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "claude-sonnet-4-6",
        inputTokens: oneMillion,
        outputTokens: oneMillion,
        cachedInputTokens: oneMillion,
        cacheCreationInputTokens: oneMillion,
        totalTokens: 4 * oneMillion
    )

    let cost = try PricingCatalog.bundled.estimatedCost(for: sample)

    #expect(cost.input == 3)
    #expect(cost.output == 15)
    #expect(cost.cachedInput == 0.30)
    #expect(cost.cacheWrite == 3.75)
    #expect(cost.total == 22.05)
}

@Test
func codexEstimateDoesNotPriceReasoningTwice() throws {
    let sample = TokenSample(
        provider: .codex,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "gpt-5.2-codex",
        inputTokens: oneMillion,
        outputTokens: oneMillion,
        cachedInputTokens: oneMillion,
        cacheCreationInputTokens: oneMillion,
        reasoningOutputTokens: 500_000,
        totalTokens: 4_500_000
    )

    let cost = try PricingCatalog.bundled.estimatedCost(for: sample)

    #expect(cost.input == 1.75)
    #expect(cost.output == 14)
    #expect(cost.reasoningOutput == 0)
    #expect(cost.cachedInput == 0.175)
    #expect(cost.cacheWrite == 0)
    #expect(cost.total == 15.925)
}

@Test
func pricingCatalogNormalizesLocalCodexPlaceholder() throws {
    let directSample = TokenSample(
        provider: .codex,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "gpt-5.2-codex",
        inputTokens: oneMillion,
        outputTokens: oneMillion,
        cachedInputTokens: oneMillion,
        reasoningOutputTokens: 500_000,
        totalTokens: 3_500_000
    )
    let aliasSample = TokenSample(
        provider: directSample.provider,
        observedAt: directSample.observedAt,
        model: "codex",
        inputTokens: directSample.inputTokens,
        outputTokens: directSample.outputTokens,
        cachedInputTokens: directSample.cachedInputTokens,
        reasoningOutputTokens: directSample.reasoningOutputTokens,
        totalTokens: directSample.totalTokens
    )

    #expect(
        try PricingCatalog.bundled.estimatedCost(for: aliasSample)
            == PricingCatalog.bundled.estimatedCost(for: directSample)
    )
}

@Test
func pricingCatalogRejectsArbitraryUnknownModelWithoutSubstitution() {
    let sample = TokenSample(
        provider: .codex,
        observedAt: Date(timeIntervalSince1970: 1_000),
        model: "unknown-codex-model",
        inputTokens: oneMillion,
        outputTokens: 0,
        totalTokens: oneMillion
    )

    #expect(throws: PricingCatalogError.unknownModel("unknown-codex-model")) {
        try PricingCatalog.bundled.estimatedCost(for: sample)
    }
}

@Test
func bundledPricingCatalogDocumentsCacheWriteEstimateLimitation() {
    #expect(
        PricingCatalog.bundled.limitations.contains {
            $0.contains("Claude cache creation tokens")
                && $0.contains("bundled cache-write rate")
                && $0.contains("TTL")
        }
    )
}

@Test
func pricingResultPreservesProviderReportedAndUnpricedProvenance() throws {
    let known = TokenSample(
        provider: .codex,
        observedAt: .now,
        model: "gpt-5.2-codex",
        inputTokens: oneMillion,
        outputTokens: 0,
        totalTokens: oneMillion
    )
    let priced = PricingCatalog.bundled.costEstimate(for: known)
    #expect(
        priced.provenance == .modelPriced(
            catalogID: PricingCatalogProvenance.bundledAudited.rawValue,
            effectiveDate: PricingCatalog.bundled.effectiveDate
        )
    )
    #expect(priced.cost?.total == 1.75)
    #expect(priced.amountUSD == 1.75)

    #expect(
        PricingCatalog.bundled.costEstimate(for: known, providerReportedCostUSD: 4.2).provenance
            == .providerReported
    )
    #expect(PricingCatalog.bundled.costEstimate(for: known, providerReportedCostUSD: 4.2).amountUSD == 4.2)

    let unknown = TokenSample(
        provider: .codex,
        observedAt: .now,
        model: "unknown-codex-model",
        inputTokens: oneMillion,
        outputTokens: 0,
        totalTokens: oneMillion
    )
    let unpriced = PricingCatalog.bundled.costEstimate(for: unknown)
    #expect(unpriced.provenance == .unpriced)
    #expect(unpriced.cost == nil)
}

@Test
func liteLLMCatalogParsesRatesAndNormalizesNames() throws {
    let data = Data("""
    {
      "openai/gpt-test": {
        "input_cost_per_token": 0.000002,
        "output_cost_per_token": 0.000008,
        "cache_read_input_token_cost": 0.0000002,
        "cache_creation_input_token_cost": 0.0000025
      },
      "missing-output": { "input_cost_per_token": 0.000001 }
      ,"anthropic/claude-test": {
        "input_cost_per_token": 0.000003,
        "output_cost_per_token": 0.000015
      },
      "claude-test": {
        "input_cost_per_token": 0.000003,
        "output_cost_per_token": 0.000015
      }
    }
    """.utf8)
    let catalog = try PricingCatalog.liteLLM(data: data, effectiveDate: "2026-08-12")

    #expect(catalog.provenance == .remoteLiteLLM)
    #expect(catalog.status == .current)
    #expect(
        try catalog.pricing(for: " models/OPENAI/gpt-test ")
            == ModelPricing(input: 2, cacheWrite: 2.5, cachedInput: 0.2, output: 8)
    )
    #expect(throws: PricingCatalogError.unknownModel("missing-output")) {
        try catalog.pricing(for: "missing-output")
    }
    #expect(
        try catalog.pricing(for: "claude-test")
            == ModelPricing(input: 3, cacheWrite: 3, cachedInput: 3, output: 15)
    )
}

@Test
func bundledCatalogIsAuditedFallback() {
    #expect(PricingCatalog.bundled.provenance == .bundledAudited)
    #expect(PricingCatalog.bundled.status == .fallback)
}
