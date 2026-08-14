import Foundation

public enum UsageCostProvenance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case providerReported, modelPriced, unpriced }

    case providerReported
    case modelPriced(catalogID: String, effectiveDate: String)
    case unpriced

    public init(kind: Kind, source: String, effectiveDate: String? = nil) {
        switch kind {
        case .providerReported:
            self = .providerReported
        case .modelPriced:
            self = .modelPriced(catalogID: source, effectiveDate: effectiveDate ?? "unknown")
        case .unpriced:
            self = .unpriced
        }
    }

    public var kind: Kind {
        switch self {
        case .providerReported: .providerReported
        case .modelPriced: .modelPriced
        case .unpriced: .unpriced
        }
    }
}

public struct UsageCostSummary: Codable, Equatable, Sendable {
    public let amountUSD: Decimal?
    public let provenance: UsageCostProvenance

    public init(amountUSD: Decimal?, provenance: UsageCostProvenance) {
        precondition(amountUSD.map { $0 >= 0 } ?? true, "Cost must not be negative")
        if case .unpriced = provenance {
            precondition(amountUSD == nil, "Unpriced usage cannot have an amount")
        } else {
            precondition(amountUSD != nil, "Priced usage must have an amount")
        }
        self.amountUSD = amountUSD
        self.provenance = provenance
    }
}

/// A global logical-deduplication projection over normalized transcript records.
public struct UsageAccountingSummary: Codable, Equatable, Sendable {
    public let recordCount: Int
    public let duplicateRecordCount: Int
    public let totals: TranscriptTokenTotals
    public let providerReportedCostUSD: Decimal
    public let issueCounts: [TranscriptAccountingIssue: Int]

    public init(records: [TranscriptUsageRecord]) {
        var seen: Set<String> = []
        var accepted: [TranscriptUsageRecord] = []
        var duplicateCount = 0
        var issues: [TranscriptAccountingIssue: Int] = [:]

        for record in records {
            guard seen.insert(record.scopedLogicalDedupeKey).inserted else {
                duplicateCount += 1
                issues[.duplicateLogicalIdentity, default: 0] += 1
                continue
            }
            accepted.append(record)
            for issue in record.diagnostics { issues[issue, default: 0] += 1 }
        }

        recordCount = accepted.count
        duplicateRecordCount = duplicateCount
        totals = TranscriptTokenTotals(
            uncachedInputTokens: accepted.reduce(0) { $0 + $1.totals.uncachedInputTokens },
            cachedInputTokens: accepted.reduce(0) { $0 + $1.totals.cachedInputTokens },
            cacheCreationInputTokens: accepted.reduce(0) { $0 + $1.totals.cacheCreationInputTokens },
            outputTokens: accepted.reduce(0) { $0 + $1.totals.outputTokens },
            reasoningOutputTokens: accepted.reduce(0) { $0 + $1.totals.reasoningOutputTokens }
        )
        providerReportedCostUSD = accepted.compactMap(\.reportedCostUSD).reduce(0, +)
        issueCounts = issues
    }

    public var processedTokens: Int { totals.processedTokens }
}
