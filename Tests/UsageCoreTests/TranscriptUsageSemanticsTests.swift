import Foundation
import Testing
@testable import UsageCore

private func record(
    provider: Provider = .codex,
    key: String = "request-1",
    source: String = "source-a",
    output: Int = 12,
    reasoning: Int = 3,
    reportedTotal: Int? = 117,
    reportedCostUSD: Decimal? = nil
) -> TranscriptUsageRecord {
    TranscriptUsageRecord(
        provider: provider,
        timestamp: Date(timeIntervalSince1970: 1_000),
        model: "gpt-test",
        totals: TranscriptTokenTotals(
            uncachedInputTokens: 80,
            cachedInputTokens: 20,
            cacheCreationInputTokens: 5,
            outputTokens: output,
            reasoningOutputTokens: reasoning
        ),
        physicalIdentity: .init(sourceID: source, sourceGeneration: "generation-1", byteOffset: 42),
        logicalDedupeKey: key,
        providerReportedTotalTokens: reportedTotal,
        reportedCostUSD: reportedCostUSD
    )
}

@Test
func canonicalProcessedTotalUsesOnlyDisjointBuckets() {
    let totals = record().totals
    #expect(totals.processedTokens == 117)
    #expect(totals.reasoningOutputTokens == 3)
}

@Test
func reasoningMustRemainAnOutputSubset() {
    let usage = record(output: 4, reasoning: 5, reportedTotal: 109)
    #expect(usage.totals.processedTokens == 109)
    #expect(usage.diagnostics == [.reasoningExceedsOutput])
}

@Test
func reportedTotalIsEvidenceNotTheCanonicalTotal() {
    let usage = record(reportedTotal: 999)
    #expect(usage.totals.processedTokens == 117)
    #expect(usage.diagnostics == [.reportedTotalMismatch])
}

@Test
func logicalIdentityDeduplicatesAcrossPhysicalSources() {
    let summary = UsageAccountingSummary(records: [
        record(source: "source-a"),
        record(source: "source-b"),
    ])
    #expect(summary.recordCount == 1)
    #expect(summary.duplicateRecordCount == 1)
    #expect(summary.processedTokens == 117)
    #expect(summary.issueCounts == [.duplicateLogicalIdentity: 1])
}

@Test
func logicalIdentityIsProviderScoped() {
    let summary = UsageAccountingSummary(records: [record(provider: .codex), record(provider: .claude)])
    #expect(summary.recordCount == 2)
    #expect(summary.processedTokens == 234)
}

@Test
func summaryDoesNotAddReasoningTwice() {
    let summary = UsageAccountingSummary(records: [
        record(key: "one", reasoning: 3),
        record(key: "two", reasoning: 7),
    ])
    #expect(summary.totals.outputTokens == 24)
    #expect(summary.totals.reasoningOutputTokens == 10)
    #expect(summary.processedTokens == 234)
}

@Test
func historyCategoryTotalDoesNotAddReasoningTwice() {
    let totals = TokenCategoryTotals(
        input: 10,
        output: 4,
        cachedInput: 3,
        cacheCreationInput: 2,
        reasoningOutput: 4
    )

    #expect(totals.total == 19)
    #expect(totals.reasoningOutput == 4)
}

@Test
func providerReportedCostAndModelPricingHaveDistinctProvenance() {
    let summary = UsageAccountingSummary(records: [record(reportedCostUSD: 1.25)])
    let reported = UsageCostSummary(amountUSD: summary.providerReportedCostUSD, provenance: .providerReported)
    let priced = UsageCostSummary(
        amountUSD: 1.25,
        provenance: .modelPriced(catalogID: "bundled", effectiveDate: "2026-08-01")
    )
    let unpriced = UsageCostSummary(amountUSD: nil, provenance: .unpriced)

    #expect(reported.provenance != priced.provenance)
    #expect(unpriced.amountUSD == nil)
}

@Test
func scanDiagnosticsExposeOnlyAggregateCounts() throws {
    let diagnostics = TranscriptScanDiagnostics(
        scannedSourceCount: 2,
        parsedRecordCount: 4,
        acceptedRecordCount: 2,
        duplicateRecordCount: 1,
        issueCounts: [.malformedRecord: 1]
    )
    let encoded = String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self)
    #expect(encoded.contains("malformedRecord"))
    #expect(!encoded.contains("/Users/"))
    #expect(!encoded.contains("prompt"))
}
