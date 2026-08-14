import CryptoKit
import Foundation

/// Compatibility identity accepted at parser boundaries. New persistence uses
/// `logicalDedupeKey` on `TranscriptUsageRecord`.
public struct TranscriptUsageIdentity: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, message, event, derived }
    public let provider: Provider
    public let kind: Kind
    public let value: String

    public init(provider: Provider, kind: Kind, value: String) {
        self.provider = provider
        self.kind = kind
        self.value = value
    }

    /// Opaque provider-scoped identity. Raw request, message, event, and session
    /// identifiers never cross the parser boundary.
    public var logicalDedupeKey: String {
        let material = "\(provider.rawValue)\u{0}\(kind.rawValue)\u{0}\(value)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(kind.rawValue):\(digest)"
    }
}

public struct TranscriptSourceIdentity: Codable, Hashable, Sendable {
    public let provider: Provider
    public let opaqueSourceID: String

    public init(provider: Provider, opaqueSourceID: String) {
        self.provider = provider
        self.opaqueSourceID = opaqueSourceID
    }
}

public struct UsageCost: Codable, Equatable, Sendable {
    public let amount: Decimal
    public let currency: String
    public let provenance: UsageCostProvenance

    public init(amount: Decimal, currency: String, provenance: UsageCostProvenance) {
        self.amount = amount
        self.currency = currency
        self.provenance = provenance
    }
}

/// Provider-neutral token semantics. The first four fields are disjoint;
/// reasoning is a labelled subset of output.
public struct TranscriptTokenTotals: Codable, Equatable, Sendable {
    public let uncachedInputTokens: Int
    public let cachedInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(
        uncachedInputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    /// Canonical processed tokens. Reasoning is not added because it is already
    /// included in `outputTokens`.
    public var processedTokens: Int {
        uncachedInputTokens + cachedInputTokens + cacheCreationInputTokens + outputTokens
    }
}

/// Location of the physical JSONL record. This supports incremental scans but
/// must never be used as the logical deduplication key.
public struct TranscriptPhysicalIdentity: Codable, Hashable, Sendable {
    public let sourceID: String
    public let sourceGeneration: String
    public let byteOffset: Int64

    public init(sourceID: String, sourceGeneration: String, byteOffset: Int64) {
        precondition(!sourceID.isEmpty, "Source ID must not be empty")
        precondition(!sourceGeneration.isEmpty, "Source generation must not be empty")
        precondition(byteOffset >= 0, "Byte offset must not be negative")
        self.sourceID = sourceID
        self.sourceGeneration = sourceGeneration
        self.byteOffset = byteOffset
    }
}

/// One normalized usage event. `logicalDedupeKey` is stable across copied files
/// and should be based on provider request/message identity, not physical source.
public struct TranscriptUsageRecord: Codable, Equatable, Sendable {
    public let provider: Provider
    public let timestamp: Date
    public let model: String
    public let totals: TranscriptTokenTotals
    public let physicalIdentity: TranscriptPhysicalIdentity
    public let logicalDedupeKey: String
    public let providerReportedTotalTokens: Int?
    public let reportedCostUSD: Decimal?

    public init(
        provider: Provider,
        timestamp: Date,
        model: String,
        totals: TranscriptTokenTotals,
        physicalIdentity: TranscriptPhysicalIdentity,
        logicalDedupeKey: String,
        providerReportedTotalTokens: Int? = nil,
        reportedCostUSD: Decimal? = nil
    ) {
        precondition(!logicalDedupeKey.isEmpty, "Logical dedupe key must not be empty")
        precondition(reportedCostUSD.map { $0 >= 0 } ?? true, "Reported cost must not be negative")
        self.provider = provider
        self.timestamp = timestamp
        self.model = model
        self.totals = totals
        self.physicalIdentity = physicalIdentity
        self.logicalDedupeKey = Self.opaqueLogicalDedupeKey(
            provider: provider,
            candidate: logicalDedupeKey
        )
        self.providerReportedTotalTokens = providerReportedTotalTokens
        self.reportedCostUSD = reportedCostUSD
    }

    /// Transitional parser initializer. Physical generation and offset are filled
    /// by the scanner when it promotes parser output to persisted records.
    public init(
        identity: TranscriptUsageIdentity,
        source: TranscriptSourceIdentity,
        observedAt: Date,
        model: String,
        uncachedInputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        providerReportedTotalTokens: Int? = nil,
        cost: UsageCost? = nil
    ) {
        self.init(
            provider: identity.provider,
            timestamp: observedAt,
            model: model,
            totals: TranscriptTokenTotals(
                uncachedInputTokens: uncachedInputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens
            ),
            physicalIdentity: TranscriptPhysicalIdentity(
                sourceID: source.opaqueSourceID,
                sourceGeneration: "parser-pending",
                byteOffset: 0
            ),
            logicalDedupeKey: identity.logicalDedupeKey,
            providerReportedTotalTokens: providerReportedTotalTokens,
            reportedCostUSD: cost?.currency.uppercased() == "USD" ? cost?.amount : nil
        )
    }

    /// Provider-scoped key used for global semantic deduplication.
    public var scopedLogicalDedupeKey: String {
        "\(provider.rawValue):\(logicalDedupeKey)"
    }

    public var identity: TranscriptUsageIdentity {
        let parts = logicalDedupeKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.first.flatMap { TranscriptUsageIdentity.Kind(rawValue: String($0)) } ?? .derived
        let value = parts.count == 2 ? String(parts[1]) : logicalDedupeKey
        return TranscriptUsageIdentity(provider: provider, kind: kind, value: value)
    }

    public var processedTokens: Int { totals.processedTokens }
    public var uncachedInputTokens: Int { totals.uncachedInputTokens }
    public var cachedInputTokens: Int { totals.cachedInputTokens }
    public var cacheCreationInputTokens: Int { totals.cacheCreationInputTokens }
    public var outputTokens: Int { totals.outputTokens }
    public var reasoningOutputTokens: Int { totals.reasoningOutputTokens }
    public var tokenSample: TokenSample {
        TokenSample(
            provider: provider,
            observedAt: timestamp,
            model: model,
            inputTokens: totals.uncachedInputTokens,
            outputTokens: totals.outputTokens,
            cachedInputTokens: totals.cachedInputTokens,
            cacheCreationInputTokens: totals.cacheCreationInputTokens,
            reasoningOutputTokens: totals.reasoningOutputTokens,
            totalTokens: totals.processedTokens,
            reportedCostUSD: reportedCostUSD
        )
    }
    public var cost: UsageCost? {
        reportedCostUSD.map { UsageCost(amount: $0, currency: "USD", provenance: .providerReported) }
    }

    public var diagnostics: [TranscriptAccountingIssue] {
        var issues: [TranscriptAccountingIssue] = []
        let values = [
            totals.uncachedInputTokens,
            totals.cachedInputTokens,
            totals.cacheCreationInputTokens,
            totals.outputTokens,
            totals.reasoningOutputTokens,
        ]
        if values.contains(where: { $0 < 0 }) { issues.append(.negativeTokenCount) }
        if totals.reasoningOutputTokens > totals.outputTokens { issues.append(.reasoningExceedsOutput) }
        if let providerReportedTotalTokens, providerReportedTotalTokens != totals.processedTokens {
            issues.append(.reportedTotalMismatch)
        }
        return issues
    }

    static func isOpaqueLogicalDedupeKey(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              TranscriptUsageIdentity.Kind(rawValue: String(parts[0])) != nil else { return false }
        let digest = parts[1].utf8
        return digest.count == 64 && digest.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func opaqueLogicalDedupeKey(provider: Provider, candidate: String) -> String {
        if isOpaqueLogicalDedupeKey(candidate) { return candidate }
        let parts = candidate.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.first.flatMap { TranscriptUsageIdentity.Kind(rawValue: String($0)) } ?? .derived
        let value = parts.count == 2 ? String(parts[1]) : candidate
        return TranscriptUsageIdentity(provider: provider, kind: kind, value: value).logicalDedupeKey
    }
}

/// Fixed diagnostic codes only: no paths, transcript text, arbitrary payloads,
/// credentials, or account identifiers.
public enum TranscriptAccountingIssue: String, Codable, CaseIterable, Sendable {
    case negativeTokenCount
    case reasoningExceedsOutput
    case reportedTotalMismatch
    case duplicateLogicalIdentity
    case missingModel
    case malformedRecord
}

/// Privacy-safe diagnostics for one scan. Source details and record contents are
/// represented only by aggregate counts.
public struct TranscriptScanDiagnostics: Codable, Equatable, Sendable {
    public let scannedSourceCount: Int
    public let parsedRecordCount: Int
    public let acceptedRecordCount: Int
    public let duplicateRecordCount: Int
    public let issueCounts: [TranscriptAccountingIssue: Int]

    public init(
        scannedSourceCount: Int,
        parsedRecordCount: Int,
        acceptedRecordCount: Int,
        duplicateRecordCount: Int,
        issueCounts: [TranscriptAccountingIssue: Int] = [:]
    ) {
        precondition(scannedSourceCount >= 0 && parsedRecordCount >= 0)
        precondition(acceptedRecordCount >= 0 && duplicateRecordCount >= 0)
        precondition(issueCounts.values.allSatisfy { $0 >= 0 })
        self.scannedSourceCount = scannedSourceCount
        self.parsedRecordCount = parsedRecordCount
        self.acceptedRecordCount = acceptedRecordCount
        self.duplicateRecordCount = duplicateRecordCount
        self.issueCounts = issueCounts
    }
}
