import Foundation

public struct TranscriptIndexSource: Equatable, Sendable {
    public let url: URL
    public let provider: Provider

    public init(url: URL, provider: Provider) {
        self.url = url
        self.provider = provider
    }
}

public struct UsageReindexResult: Equatable, Sendable {
    public let id: String
    public let backupURL: URL
    public let validation: TranscriptIndexValidation
    public let indexedRecordCount: Int
    public let duplicateRecordCount: Int
    public let parserDiagnosticCounts: [TranscriptParserDiagnostic.Reason: Int]
}

public enum UsageReindexError: Error, Equatable, Sendable {
    case sourceListChanged
    case validationFailed(TranscriptIndexValidation)
    case activeVersionChanged
}

/// Builds accounting v2 in its inactive shadow tables and flips the active
/// version only after a second catch-up scan and structural validation.
public actor UsageReindexCoordinator {
    public typealias SourceSnapshot = @Sendable () async throws -> [TranscriptIndexSource]

    private let store: UsageStore
    private let indexer: TranscriptIndexer
    private let backupDirectory: URL
    private let now: @Sendable () -> Date

    public init(
        store: UsageStore,
        backupDirectory: URL,
        indexer: TranscriptIndexer = TranscriptIndexer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.indexer = indexer
        self.now = now
    }

    public func run(
        id: String = UUID().uuidString,
        sources: @escaping SourceSnapshot
    ) async throws -> UsageReindexResult {
        let from = try await store.activeAccountingVersion()
        let target = UsageIndexVersion.transcriptAccountingV2.rawValue
        guard from != target else {
            let validation = try await store.validateTranscriptIndex()
            let canonicalCount = try await store.canonicalTranscriptRecords().count
            return UsageReindexResult(
                id: id,
                backupURL: backupURL(id: id),
                validation: validation,
                indexedRecordCount: 0,
                duplicateRecordCount: max(validation.physicalRecordCount - canonicalCount, 0),
                parserDiagnosticCounts: [:]
            )
        }

        let started = now()
        let backup = backupURL(id: id, at: started)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try await store.backup(to: backup.path)
        try await store.saveReindexMetadata(.init(
            id: id, fromAccountingVersion: from, toAccountingVersion: target,
            state: .running, startedAt: started
        ))

        do {
            try Task.checkCancellation()
            // Explicitly discard only the inactive v2 shadow. Legacy samples and
            // v5 import cursors remain untouched and readable throughout.
            try await store.resetInactiveTranscriptIndex(accountingVersion: target)
            let initialSources = try await sources().sorted(by: Self.sourceOrder)
            var indexSummary = try await index(initialSources)

            try Task.checkCancellation()
            let catchUpSources = try await sources().sorted(by: Self.sourceOrder)
            guard Set(initialSources.map(Self.sourceKey)) == Set(catchUpSources.map(Self.sourceKey)) else {
                throw UsageReindexError.sourceListChanged
            }
            indexSummary.merge(try await index(catchUpSources))

            try Task.checkCancellation()
            let validation = try await store.validateTranscriptIndex()
            guard validation.isValid else { throw UsageReindexError.validationFailed(validation) }
            guard try await store.activeAccountingVersion() == from else { throw UsageReindexError.activeVersionChanged }
            try Task.checkCancellation()
            try await store.setActiveAccountingVersion(target)
            try await store.saveReindexMetadata(.init(
                id: id, fromAccountingVersion: from, toAccountingVersion: target,
                state: .completed, startedAt: started, completedAt: now()
            ))
            let canonicalCount = try await store.canonicalTranscriptRecords().count
            return UsageReindexResult(
                id: id,
                backupURL: backup,
                validation: validation,
                indexedRecordCount: indexSummary.recordCount,
                duplicateRecordCount: max(validation.physicalRecordCount - canonicalCount, 0),
                parserDiagnosticCounts: indexSummary.diagnosticCounts
            )
        } catch {
            // The activation is the final write, so every pre-activation failure
            // leaves legacy active. The retained shadow/checkpoints are safe to
            // inspect; a retry starts by transactionally clearing that shadow.
            if (try? await store.activeAccountingVersion()) == from {
                try? await store.saveReindexMetadata(.init(
                    id: id, fromAccountingVersion: from, toAccountingVersion: target,
                    state: .failed, startedAt: started, completedAt: now()
                ))
            }
            throw error
        }
    }

    public func rollback(id: String) async throws {
        try await store.rollbackReindex(id: id, at: now())
    }

    private func index(_ sources: [TranscriptIndexSource]) async throws -> IndexSummary {
        var summary = IndexSummary()
        for source in sources {
            try Task.checkCancellation()
            let result = try await indexer.index(
                file: source.url, provider: source.provider, into: store,
                replacingPriorGenerations: true
            )
            summary.recordCount += result.indexedRecordCount
            for diagnostic in result.diagnostics {
                summary.diagnosticCounts[diagnostic.reason, default: 0] += 1
            }
        }
        return summary
    }

    private func backupURL(id: String, at date: Date? = nil) -> URL {
        let stamp = String(Int((date ?? now()).timeIntervalSince1970))
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return backupDirectory.appendingPathComponent("usage-before-v2-\(stamp)-\(safeID).sqlite3")
    }

    private static func sourceOrder(_ lhs: TranscriptIndexSource, _ rhs: TranscriptIndexSource) -> Bool {
        sourceKey(lhs) < sourceKey(rhs)
    }

    private static func sourceKey(_ source: TranscriptIndexSource) -> String {
        "\(source.provider.rawValue):\(source.url.standardizedFileURL.path)"
    }

}

private struct IndexSummary {
    var recordCount = 0
    var diagnosticCounts: [TranscriptParserDiagnostic.Reason: Int] = [:]

    mutating func merge(_ other: IndexSummary) {
        recordCount += other.recordCount
        for (reason, count) in other.diagnosticCounts {
            diagnosticCounts[reason, default: 0] += count
        }
    }
}
