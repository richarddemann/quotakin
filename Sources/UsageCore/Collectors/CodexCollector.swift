import Foundation

public struct CodexCollector: UsageCollector {
    public let provider = Provider.codex
    public let sessionURLs: [URL]
    public let roots: [URL]
    public var sourceDirectories: [URL] { roots }
    public var transcriptIndexSources: [TranscriptIndexSource] {
        let files = sessionURLs.isEmpty ? IncrementalJSONL.files(in: roots) : sessionURLs
        return files.map { TranscriptIndexSource(url: $0, provider: .codex) }
    }

    public init(sessionURLs: [URL] = [], roots: [URL]? = nil) {
        self.sessionURLs = sessionURLs
        self.roots = roots ?? [Self.defaultRoot]
    }

    public func collect() async throws -> CollectorBatch {
        var tokens: [TokenSample] = []
        var quota: [QuotaSnapshot] = []
        var planType: String?

        for sessionURL in sessionURLs {
            do {
                let batch = try Self.parseSession(Self.readData(from: sessionURL))
                tokens.append(contentsOf: batch.tokens)
                quota.append(contentsOf: batch.quota)
                planType = batch.planType ?? planType
            } catch let error as CollectorError
                where error.reason == .parseFailed && error.sourceID == nil {
                throw CollectorError.parseFailure(provider: .codex, path: sessionURL.path)
            }
        }

        return CollectorBatch(tokens: tokens, quota: quota, planType: planType)
    }

    public func collect(into store: UsageStore) async throws -> CollectorBatch {
        if try await store.activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try await collectWithTranscriptIndex(into: store)
        }
        guard sessionURLs.isEmpty else {
            return try await collect()
        }
        return try await collectIncrementally(into: store)
    }

    public func collectIncrementally(into store: UsageStore) async throws -> CollectorBatch {
        if try await store.activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try await collectWithTranscriptIndex(into: store)
        }
        var tokens: [TokenSample] = []
        var quota: [QuotaSnapshot] = []
        var planType: String?

        for sessionURL in IncrementalJSONL.files(in: roots) {
            let sourceID = SourceID.hash(path: sessionURL.path)
            let storedOffset = try await store.cursor(for: sourceID) ?? 0
            let chunk = try IncrementalJSONL.read(
                from: sessionURL,
                storedOffset: storedOffset,
                provider: .codex
            )

            do {
                let batch = chunk.data.isEmpty
                    ? CollectorBatch(tokens: [], quota: [])
                    : try Self.parseSession(chunk.data)
                try await store.save(tokens: batch.tokens, quota: batch.quota)
                try await chunk.advanceCursor(sourceID: sourceID, in: store)
                tokens.append(contentsOf: batch.tokens)
                quota.append(contentsOf: batch.quota)
                planType = batch.planType ?? planType
            } catch let error as CollectorError
                where error.reason == .parseFailed && error.sourceID == nil {
                throw CollectorError.parseFailure(provider: .codex, path: sessionURL.path)
            }
        }

        return CollectorBatch(
            tokens: tokens,
            quota: quota,
            planType: planType,
            isPersisted: true
        )
    }

    private func collectWithTranscriptIndex(into store: UsageStore) async throws -> CollectorBatch {
        var tokens: [TokenSample] = []
        var quota: [QuotaSnapshot] = []
        var planType: String?
        var retainedSourceIDs: Set<String> = []
        let indexer = TranscriptIndexer()

        for source in transcriptIndexSources {
            let result = try await indexer.index(file: source.url, provider: source.provider, into: store)
            retainedSourceIDs.insert(result.sourceID)
            tokens.append(contentsOf: result.records.map(\.tokenSample))

            let sourceID = SourceID.hash(path: source.url.path)
            let storedOffset = try await store.cursor(for: sourceID) ?? 0
            let chunk = try IncrementalJSONL.read(
                from: source.url,
                storedOffset: storedOffset,
                provider: .codex
            )
            let metadata = Self.parseQuotaMetadata(chunk.data)
            try await store.save(tokens: [], quota: metadata.quota)
            try await chunk.advanceCursor(sourceID: sourceID, in: store)
            quota.append(contentsOf: metadata.quota)
            planType = metadata.planType ?? planType
        }
        try await store.reconcileTranscriptSources(
            provider: .codex,
            retainingSourceIDs: retainedSourceIDs
        )

        return CollectorBatch(tokens: tokens, quota: quota, planType: planType, isPersisted: true)
    }

    private static func parseQuotaMetadata(_ data: Data) -> (quota: [QuotaSnapshot], planType: String?) {
        var quota: [QuotaSnapshot] = []
        var planType: String?
        let decoder = jsonDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(SessionRecord.self, from: Data(line)),
                  record.type == "event_msg",
                  let payload = record.payload,
                  payload.type == "token_count",
                  let observedAt = record.timestamp else { continue }
            quota.append(contentsOf: [payload.rateLimits?.primary, payload.rateLimits?.secondary]
                .compactMap { $0 }
                .compactMap { rateLimit in
                    guard let window = codexQuotaWindow(windowMinutes: rateLimit.windowMinutes) else { return nil }
                    return quotaSnapshot(from: rateLimit, window: window, observedAt: observedAt)
                })
            planType = payload.planType ?? planType
        }
        return (quota, planType)
    }

    public static func parseSession(_ data: Data) throws -> CollectorBatch {
        let decoder = jsonDecoder()

        do {
            var tokens: [TokenSample] = []
            var quota: [QuotaSnapshot] = []
            var planType: String?

            for line in data.split(separator: UInt8(ascii: "\n")) {
                let record = try decoder.decode(SessionRecord.self, from: Data(line))
                guard
                    record.type == "event_msg",
                    let payload = record.payload,
                    payload.type == "token_count",
                    let observedAt = record.timestamp,
                    let usage = payload.info?.lastTokenUsage
                else {
                    continue
                }

                tokens.append(
                    TokenSample(
                        provider: .codex,
                        observedAt: observedAt,
                        model: "codex",
                        inputTokens: max(usage.inputTokens - usage.cachedInputTokens, 0),
                        outputTokens: usage.outputTokens,
                        cachedInputTokens: usage.cachedInputTokens,
                        reasoningOutputTokens: usage.reasoningOutputTokens,
                        totalTokens: max(usage.inputTokens - usage.cachedInputTokens, 0)
                            + usage.cachedInputTokens
                            + usage.outputTokens
                    )
                )

                [payload.rateLimits?.primary, payload.rateLimits?.secondary]
                    .compactMap { $0 }
                    .forEach { rateLimit in
                        if let window = codexQuotaWindow(windowMinutes: rateLimit.windowMinutes) {
                            quota.append(quotaSnapshot(from: rateLimit, window: window, observedAt: observedAt))
                        }
                    }
                planType = payload.planType ?? planType
            }

            return CollectorBatch(tokens: tokens, quota: quota, planType: planType)
        } catch {
            throw CollectorError.parseFailure(provider: .codex)
        }
    }

    public static func parseQuotaSnapshots(line data: Data, notBefore cutoff: Date) throws -> [QuotaSnapshot] {
        let decoder = jsonDecoder()

        do {
            let record = try decoder.decode(SessionRecord.self, from: data)
            guard
                record.type == "event_msg",
                let payload = record.payload,
                payload.type == "token_count",
                let observedAt = record.timestamp,
                observedAt >= cutoff
            else {
                return []
            }

            return [payload.rateLimits?.primary, payload.rateLimits?.secondary]
                .compactMap { $0 }
                .compactMap { rateLimit in
                    guard let window = codexQuotaWindow(windowMinutes: rateLimit.windowMinutes) else {
                        return nil
                    }
                    return quotaSnapshot(from: rateLimit, window: window, observedAt: observedAt)
                }
        } catch {
            throw CollectorError.parseFailure(provider: .codex)
        }
    }

    private static func readData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CollectorError.readFailure(provider: .codex, path: url.path)
        }
    }

    private static func quotaSnapshot(
        from rateLimit: RateLimitRecord,
        window: QuotaWindow,
        observedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .codex,
            window: window,
            usedPercent: rateLimit.usedPercent,
            resetsAt: Date(timeIntervalSince1970: rateLimit.resetsAt),
            observedAt: observedAt
        )
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions")
}

private struct SessionRecord: Decodable {
    let timestamp: Date?
    let type: String
    let payload: SessionPayload?
}

private struct SessionPayload: Decodable {
    let type: String?
    let info: TokenCountInfo?
    let rateLimits: RateLimitsRecord?
    let planType: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case info
        case rateLimits = "rate_limits"
        case planType = "plan_type"
    }
}

private struct TokenCountInfo: Decodable {
    let lastTokenUsage: TokenUsageRecord?

    private enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
    }
}

private struct TokenUsageRecord: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct RateLimitsRecord: Decodable {
    let primary: RateLimitRecord?
    let secondary: RateLimitRecord?
}

private struct RateLimitRecord: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

func codexQuotaWindow(windowMinutes: Int) -> QuotaWindow? {
    if (270...330).contains(windowMinutes) {
        return .session
    }
    if (9_900...10_260).contains(windowMinutes) {
        return .weekly
    }
    return nil
}

public struct CodexQuotaHistoryBackfill: Sendable {
    public struct Result: Equatable, Sendable {
        public let filesScanned: Int
        public let snapshotsSaved: Int

        public init(filesScanned: Int, snapshotsSaved: Int) {
            self.filesScanned = filesScanned
            self.snapshotsSaved = snapshotsSaved
        }
    }

    public let roots: [URL]
    public let cutoff: Date
    public let saveBatchSize: Int

    public init(
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")],
        cutoff: Date = Date().addingTimeInterval(-90 * 24 * 60 * 60),
        saveBatchSize: Int = 256
    ) {
        self.roots = roots
        self.cutoff = cutoff
        self.saveBatchSize = saveBatchSize
    }

    public func run(into store: UsageStore) async throws -> Result {
        var filesScanned = 0
        var snapshotsSaved = 0
        var pending: [QuotaSnapshot] = []

        for sessionURL in IncrementalJSONL.files(in: roots) {
            filesScanned += 1
            try await scan(sessionURL) { snapshots in
                pending.append(contentsOf: snapshots)
                guard pending.count >= saveBatchSize else {
                    return
                }

                try await store.save(tokens: [], quota: pending)
                snapshotsSaved += pending.count
                pending.removeAll(keepingCapacity: true)
            }
        }

        if !pending.isEmpty {
            try await store.save(tokens: [], quota: pending)
            snapshotsSaved += pending.count
        }

        return Result(filesScanned: filesScanned, snapshotsSaved: snapshotsSaved)
    }

    private func scan(
        _ url: URL,
        onSnapshots: ([QuotaSnapshot]) async throws -> Void
    ) async throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CollectorError.readFailure(provider: .codex, path: url.path)
        }
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                throw CollectorError.readFailure(provider: .codex, path: url.path)
            }

            if chunk.isEmpty {
                break
            }

            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                try Task.checkCancellation()
                let snapshots = try CodexCollector.parseQuotaSnapshots(line: line, notBefore: cutoff)
                if !snapshots.isEmpty {
                    try await onSnapshots(snapshots)
                }
            }
        }

        if !buffer.isEmpty, !buffer.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\n") }) {
            try Task.checkCancellation()
            let snapshots = try CodexCollector.parseQuotaSnapshots(line: buffer, notBefore: cutoff)
            if !snapshots.isEmpty {
                try await onSnapshots(snapshots)
            }
        }
    }
}
