import Foundation

struct TranscriptJSONLLine: Sendable {
    let data: Data
    let consumedByteCount: Int
}

enum TranscriptJSONL {
    static func lines(in data: Data) -> [TranscriptJSONLLine] {
        guard !data.isEmpty else { return [] }
        var lines: [TranscriptJSONLLine] = []
        var start = data.startIndex
        var cursor = start
        while cursor < data.endIndex {
            if data[cursor] == UInt8(ascii: "\n") {
                lines.append(TranscriptJSONLLine(
                    data: Data(data[start..<cursor]),
                    consumedByteCount: data.distance(from: start, to: cursor) + 1
                ))
                start = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }
        if start < data.endIndex {
            lines.append(TranscriptJSONLLine(
                data: Data(data[start..<data.endIndex]),
                consumedByteCount: data.distance(from: start, to: data.endIndex)
            ))
        }
        return lines
    }

    static func completedPrefixLength(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        if data.last == UInt8(ascii: "\n") { return data.count }

        let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        let tailStart = lastNewline.map { data.index(after: $0) } ?? data.startIndex
        let tail = Data(data[tailStart..<data.endIndex])
        if tail.allSatisfy(Self.isWhitespace) || (try? JSONSerialization.jsonObject(with: tail)) != nil {
            return data.count
        }
        guard let lastNewline else { return 0 }
        return data.distance(from: data.startIndex, to: lastNewline) + 1
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}

public struct TranscriptParserDiagnostic: Equatable, Sendable {
    public enum Reason: String, Equatable, Hashable, Sendable {
        case malformedJSON
        case invalidUsage
        case missingTimestamp
        case missingModel
        case missingSession
    }

    public let lineNumber: Int
    public let reason: Reason

    public init(lineNumber: Int, reason: Reason) {
        self.lineNumber = lineNumber
        self.reason = reason
    }
}

public struct TranscriptParseResult<State: Equatable & Sendable>: Equatable, Sendable {
    public let records: [TranscriptUsageRecord]
    public let diagnostics: [TranscriptParserDiagnostic]
    public let state: State

    public init(
        records: [TranscriptUsageRecord],
        diagnostics: [TranscriptParserDiagnostic],
        state: State
    ) {
        self.records = records
        self.diagnostics = diagnostics
        self.state = state
    }
}

public struct ClaudeUsageParserState: Equatable, Sendable {
    public var lineNumber: Int
    public var byteOffset: Int64
    public var sessionID: String?

    public init(lineNumber: Int = 0, byteOffset: Int64 = 0, sessionID: String? = nil) {
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
        self.sessionID = sessionID
    }
}

public struct CodexUsageParserState: Equatable, Sendable {
    public struct UsageSnapshot: Equatable, Sendable {
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let cacheCreationInputTokens: Int
        public let outputTokens: Int
        public let reasoningOutputTokens: Int
        public let totalTokens: Int

        public init(
            inputTokens: Int,
            cachedInputTokens: Int,
            cacheCreationInputTokens: Int = 0,
            outputTokens: Int,
            reasoningOutputTokens: Int,
            totalTokens: Int
        ) {
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.outputTokens = outputTokens
            self.reasoningOutputTokens = reasoningOutputTokens
            self.totalTokens = totalTokens
        }
    }

    public var lineNumber: Int
    public var byteOffset: Int64
    public var sessionID: String?
    public var model: String?
    public var previousUsage: UsageSnapshot?
    public var sawSessionMeta: Bool
    public var suppressCopiedUsage: Bool
    public var forkCopyAnchorAt: Date?

    public init(
        lineNumber: Int = 0,
        byteOffset: Int64 = 0,
        sessionID: String? = nil,
        model: String? = nil,
        previousUsage: UsageSnapshot? = nil,
        sawSessionMeta: Bool = false,
        suppressCopiedUsage: Bool = false,
        forkCopyAnchorAt: Date? = nil
    ) {
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
        self.sessionID = sessionID
        self.model = model
        self.previousUsage = previousUsage
        self.sawSessionMeta = sawSessionMeta
        self.suppressCopiedUsage = suppressCopiedUsage
        self.forkCopyAnchorAt = forkCopyAnchorAt
    }
}
