import Foundation

public struct ClaudeCollector: UsageCollector {
    public let provider = Provider.claude
    public let transcriptURLs: [URL]
    public let quotaSnapshotURL: URL?
    public let quotaProvider: (any ClaudeQuotaProvider)?
    public let roots: [URL]
    private let now: @Sendable () -> Date
    public var sourceDirectories: [URL] {
        roots
    }
    public var transcriptIndexSources: [TranscriptIndexSource] {
        let files = transcriptURLs.isEmpty ? IncrementalJSONL.files(in: roots) : transcriptURLs
        return files.map { TranscriptIndexSource(url: $0, provider: .claude) }
    }

    public init(
        transcriptURLs: [URL] = [],
        quotaSnapshotURL: URL? = nil,
        quotaProvider: (any ClaudeQuotaProvider)? = nil,
        roots: [URL]? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcriptURLs = transcriptURLs
        self.quotaSnapshotURL = quotaSnapshotURL
        self.quotaProvider = quotaProvider
        self.roots = roots ?? [Self.defaultRoot]
        self.now = now
    }

    public func collect() async throws -> CollectorBatch {
        var tokens: [TokenSample] = []

        for transcriptURL in transcriptURLs {
            do {
                tokens.append(contentsOf: try Self.parseTranscript(Self.readData(from: transcriptURL)))
            } catch let error as CollectorError
                where error.reason == .parseFailed && error.sourceID == nil {
                throw CollectorError.parseFailure(provider: .claude, path: transcriptURL.path)
            }
        }

        return CollectorBatch(tokens: tokens, quota: try await collectQuota())
    }

    public func collect(into store: UsageStore) async throws -> CollectorBatch {
        if try await store.activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try await collectWithTranscriptIndex(into: store)
        }
        guard transcriptURLs.isEmpty else {
            return try await collect()
        }
        return try await collectIncrementally(into: store)
    }

    public func collectIncrementally(into store: UsageStore) async throws -> CollectorBatch {
        if try await store.activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try await collectWithTranscriptIndex(into: store)
        }
        var tokens: [TokenSample] = []

        for transcriptURL in IncrementalJSONL.files(in: roots) {
            let sourceID = SourceID.hash(path: transcriptURL.path)
            let storedOffset = try await store.cursor(for: sourceID) ?? 0
            let chunk = try IncrementalJSONL.read(
                from: transcriptURL,
                storedOffset: storedOffset,
                provider: .claude
            )

            do {
                let importedTokens = chunk.data.isEmpty
                    ? []
                    : try Self.parseTranscript(chunk.data)
                try await store.save(tokens: importedTokens, quota: [])
                try await chunk.advanceCursor(sourceID: sourceID, in: store)
                tokens.append(contentsOf: importedTokens)
            } catch let error as CollectorError
                where error.reason == .parseFailed && error.sourceID == nil {
                throw CollectorError.parseFailure(provider: .claude, path: transcriptURL.path)
            }
        }

        let quota = try await collectQuota()
        try await store.save(tokens: [], quota: quota)
        return CollectorBatch(tokens: tokens, quota: quota, isPersisted: true)
    }

    private func collectWithTranscriptIndex(into store: UsageStore) async throws -> CollectorBatch {
        var tokens: [TokenSample] = []
        var retainedSourceIDs: Set<String> = []
        let indexer = TranscriptIndexer()
        for source in transcriptIndexSources {
            let result = try await indexer.index(file: source.url, provider: source.provider, into: store)
            retainedSourceIDs.insert(result.sourceID)
            tokens.append(contentsOf: result.records.map(\.tokenSample))
        }
        try await store.reconcileTranscriptSources(
            provider: .claude,
            retainingSourceIDs: retainedSourceIDs
        )

        let quota = try await collectQuota()
        try await store.save(tokens: [], quota: quota)
        return CollectorBatch(tokens: tokens, quota: quota, isPersisted: true)
    }

    public static func parseTranscript(_ data: Data) throws -> [TokenSample] {
        let decoder = jsonDecoder()

        do {
            return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
                let record = try decoder.decode(TranscriptRecord.self, from: Data(line))
                guard
                    record.type == "assistant",
                    let observedAt = record.timestamp,
                    let model = record.message?.model,
                    let usage = record.message?.usage
                else {
                    return nil
                }

                let inputTokens = usage.inputTokens ?? 0
                let outputTokens = usage.outputTokens ?? 0
                let cachedInputTokens = usage.cacheReadInputTokens ?? 0
                let cacheCreationInputTokens = usage.cacheCreationInputTokens ?? 0

                return TokenSample(
                    provider: .claude,
                    observedAt: observedAt,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cachedInputTokens: cachedInputTokens,
                    cacheCreationInputTokens: cacheCreationInputTokens,
                    totalTokens: inputTokens
                        + outputTokens
                        + cachedInputTokens
                        + cacheCreationInputTokens
                )
            }
        } catch {
            throw CollectorError.parseFailure(provider: .claude)
        }
    }

    public static func parseQuotaSnapshot(_ data: Data) throws -> [QuotaSnapshot] {
        do {
            let snapshot = try jsonDecoder().decode(QuotaRecord.self, from: data)

            return [
                quotaSnapshot(from: snapshot.fiveHour, window: .session, observedAt: snapshot.observedAt),
                quotaSnapshot(from: snapshot.sevenDay, window: .weekly, observedAt: snapshot.observedAt)
            ]
        } catch {
            throw CollectorError.parseFailure(provider: .claude)
        }
    }

    private static func readData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CollectorError.readFailure(provider: .claude, path: url.path)
        }
    }

    private func collectQuota() async throws -> [QuotaSnapshot] {
        let currentDate = now()
        if let localQuota = try? collectLocalQuota(),
           Self.isFreshStatusSnapshot(localQuota, at: currentDate) {
            return localQuota
        }

        if let remoteQuota = try? await quotaProvider?.quotaSnapshots(), !remoteQuota.isEmpty {
            return remoteQuota
        }

        return []
    }

    private static func isFreshStatusSnapshot(
        _ quota: [QuotaSnapshot],
        at date: Date
    ) -> Bool {
        !quota.isEmpty && quota.allSatisfy { $0.freshness(at: date) == .fresh }
    }

    private func collectLocalQuota() throws -> [QuotaSnapshot]? {
        guard let quotaSnapshotURL,
              FileManager.default.fileExists(atPath: quotaSnapshotURL.path) else {
            return nil
        }

        do {
            return try Self.parseQuotaSnapshot(Self.readData(from: quotaSnapshotURL))
        } catch let error as CollectorError
            where error.reason == .parseFailed && error.sourceID == nil {
            throw CollectorError.parseFailure(provider: .claude, path: quotaSnapshotURL.path)
        }
    }

    private static func quotaSnapshot(
        from windowRecord: QuotaWindowRecord,
        window: QuotaWindow,
        observedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            window: window,
            usedPercent: windowRecord.usedPercent,
            resetsAt: Date(timeIntervalSince1970: windowRecord.resetsAt),
            observedAt: observedAt
        )
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/projects")
}

private struct TranscriptRecord: Decodable {
    let type: String
    let timestamp: Date?
    let message: TranscriptMessage?
}

private struct TranscriptMessage: Decodable {
    let model: String?
    let usage: TranscriptUsage?
}

private struct TranscriptUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

private struct QuotaRecord: Decodable {
    let observedAt: Date
    let fiveHour: QuotaWindowRecord
    let sevenDay: QuotaWindowRecord
}

private struct QuotaWindowRecord: Decodable {
    let usedPercent: Double
    let resetsAt: TimeInterval
}
