import Foundation

public protocol UsageCollector: Sendable {
    var provider: Provider { get }
    var sourceDirectories: [URL] { get }
    var transcriptIndexSources: [TranscriptIndexSource] { get }

    func collect() async throws -> CollectorBatch
    // Store-backed collectors may persist during collection and return a persisted batch.
    func collect(into store: UsageStore) async throws -> CollectorBatch
}

public extension UsageCollector {
    var sourceDirectories: [URL] { [] }
    var transcriptIndexSources: [TranscriptIndexSource] { [] }

    func collect(into store: UsageStore) async throws -> CollectorBatch {
        try await collect()
    }
}

public struct CollectorError: Error, CustomStringConvertible, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case readFailed = "read failed"
        case parseFailed = "parse failed"
    }

    public let provider: Provider
    public let reason: Reason
    public let sourceID: String?

    public var description: String {
        let message = "\(provider.rawValue) collector \(reason.rawValue)"
        guard let sourceID else {
            return message
        }

        return "\(message) (source: \(sourceID))"
    }

    static func readFailure(provider: Provider, path: String) -> CollectorError {
        CollectorError(
            provider: provider,
            reason: .readFailed,
            sourceID: hashedSourceID(path: path)
        )
    }

    static func parseFailure(provider: Provider) -> CollectorError {
        CollectorError(provider: provider, reason: .parseFailed, sourceID: nil)
    }

    static func parseFailure(provider: Provider, path: String) -> CollectorError {
        CollectorError(
            provider: provider,
            reason: .parseFailed,
            sourceID: hashedSourceID(path: path)
        )
    }

    private init(provider: Provider, reason: Reason, sourceID: String?) {
        self.provider = provider
        self.reason = reason
        self.sourceID = sourceID
    }

    private static func hashedSourceID(path: String) -> String {
        SourceID.hash(path: path)
    }
}

public struct CollectorBatch: Sendable {
    public let tokens: [TokenSample]
    public let quota: [QuotaSnapshot]
    public let planType: String?
    public let isPersisted: Bool

    public init(
        tokens: [TokenSample],
        quota: [QuotaSnapshot],
        planType: String? = nil,
        isPersisted: Bool = false
    ) {
        self.tokens = tokens
        self.quota = quota
        self.planType = planType
        self.isPersisted = isPersisted
    }
}

struct IncrementalJSONLChunk {
    let data: Data
    let expectedByteOffset: Int
    let nextByteOffset: Int
    let resetAfterTruncation: Bool

    func advanceCursor(sourceID: String, in store: UsageStore) async throws {
        // A failed CAS means an overlapping import already moved the cursor.
        if resetAfterTruncation {
            _ = try await store.resetCursorAfterTruncation(
                sourceID: sourceID,
                from: expectedByteOffset,
                to: nextByteOffset
            )
        } else {
            _ = try await store.advanceCursor(
                sourceID: sourceID,
                from: expectedByteOffset,
                to: nextByteOffset
            )
        }
    }
}

enum IncrementalJSONL {
    static func files(in roots: [URL]) -> [URL] {
        var files: [URL] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            files.append(contentsOf: enumerator.compactMap { element in
                guard
                    let url = element as? URL,
                    url.pathExtension == "jsonl",
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else {
                    return nil
                }
                return url
            })
        }

        return files.sorted { $0.path < $1.path }
    }

    static func read(
        from url: URL,
        storedOffset: Int,
        provider: Provider
    ) throws -> IncrementalJSONLChunk {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let resetAfterTruncation = storedOffset > currentSize
            let startingOffset = ImportCursor.nextOffset(
                storedOffset: storedOffset,
                currentSize: currentSize
            )
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startingOffset))
            let appendedData = try handle.readToEnd() ?? Data()
            let completed = completedData(in: appendedData)
            return IncrementalJSONLChunk(
                data: completed.data,
                expectedByteOffset: storedOffset,
                nextByteOffset: startingOffset + completed.consumedByteCount,
                resetAfterTruncation: resetAfterTruncation
            )
        } catch {
            throw CollectorError.readFailure(provider: provider, path: url.path)
        }
    }

    private static func completedData(in data: Data) -> (data: Data, consumedByteCount: Int) {
        guard !data.isEmpty else {
            return (Data(), 0)
        }

        guard let newlineIndex = data.lastIndex(of: UInt8(ascii: "\n")) else {
            if isWhitespaceOnly(data) {
                return (Data(), data.count)
            }

            return isCompleteJSONRecord(data) ? (data, data.count) : (Data(), 0)
        }

        let prefix = Data(data[...newlineIndex])
        let suffix = Data(data[data.index(after: newlineIndex)...])

        if isWhitespaceOnly(suffix) {
            return (prefix, data.count)
        }

        return isCompleteJSONRecord(suffix)
            ? (data, data.count)
            : (prefix, prefix.count)
    }

    private static func isCompleteJSONRecord(_ data: Data) -> Bool {
        guard !data.isEmpty, !isWhitespaceOnly(data) else {
            return false
        }

        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isWhitespaceOnly(_ data: Data) -> Bool {
        data.allSatisfy { byte in
            byte == UInt8(ascii: " ")
                || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\r")
                || byte == UInt8(ascii: "\n")
        }
    }
}
