import CryptoKit
import Foundation

public struct TranscriptIndexResult: Equatable, Sendable {
    public let sourceID: String
    public let generation: String
    public let previousOffset: Int64
    public let committedOffset: Int64
    public let indexedRecordCount: Int
    public let records: [TranscriptUsageRecord]
    public let diagnostics: [TranscriptParserDiagnostic]
    public let replacedGeneration: Bool

    public var didChange: Bool { committedOffset != previousOffset || replacedGeneration }
}

/// Incrementally indexes complete JSONL records. File bytes, prompts, and paths
/// never cross the persistence boundary; a batch and its parser checkpoint are
/// published by `UsageStore` in one transaction.
public struct TranscriptIndexer: Sendable {
    public static let parserVersion = 3
    public static let parserStateVersion = 2

    public init() {}

    public func index(
        file url: URL,
        provider: Provider,
        into store: UsageStore,
        replacingPriorGenerations: Bool = true
    ) async throws -> TranscriptIndexResult {
        try Task.checkCancellation()
        let identity = try sourceIdentity(for: url)
        let fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        let saved = try await store.checkpoint(sourceID: identity.sourceID, generation: identity.generation)
        let savedSource = try await store.transcriptSource(sourceID: identity.sourceID, generation: identity.generation)
        let storedOffset = saved?.byteOffset ?? 0
        let prefixMatches = storedOffset <= Int64(fileData.count)
            && savedSource?.sourceFingerprint == Self.digest(Data(fileData.prefix(Int(storedOffset))))
            && savedSource?.parserVersion == Self.parserVersion
        let reset = saved != nil && !prefixMatches
        let startOffset = reset ? 0 : storedOffset
        let suffix = fileData.dropFirst(Int(startOffset))
        let suffixData = Data(suffix)
        let completeCount = TranscriptJSONL.completedPrefixLength(in: suffixData)
        let completeData = Data(suffixData.prefix(completeCount))

        let parsed: ParsedBatch
        switch provider {
        case .claude:
            let initial = reset ? ClaudeUsageParserState() : try decodeClaude(saved, offset: startOffset)
            let result = ClaudeUsageParser.parse(
                completeData,
                sourceID: identity.sourceID,
                sourceGeneration: identity.generation,
                state: initial
            )
            parsed = ParsedBatch(
                records: result.records,
                diagnostics: result.diagnostics,
                offset: result.state.byteOffset,
                stateData: try StateCodec.encode(result.state)
            )
        case .codex:
            let initial = reset ? CodexUsageParserState() : try decodeCodex(saved, offset: startOffset)
            let result = CodexUsageParser.parse(
                completeData,
                sourceID: identity.sourceID,
                sourceGeneration: identity.generation,
                state: initial
            )
            parsed = ParsedBatch(
                records: result.records,
                diagnostics: result.diagnostics,
                offset: result.state.byteOffset,
                stateData: try StateCodec.encode(result.state)
            )
        }

        // A partial final line deliberately leaves the checkpoint before it.
        // Cancellation here leaves both records and checkpoint unchanged.
        try Task.checkCancellation()
        if saved == nil || parsed.offset != storedOffset || reset {
            try await store.commitTranscriptBatch(
                source: TranscriptSourceMetadata(
                    sourceID: identity.sourceID,
                    sourceFingerprint: Self.digest(Data(fileData.prefix(Int(parsed.offset)))),
                    provider: provider,
                    generation: identity.generation,
                    parserVersion: Self.parserVersion
                ),
                records: parsed.records,
                checkpoint: TranscriptCheckpoint(
                    sourceID: identity.sourceID,
                    sourceGeneration: identity.generation,
                    byteOffset: parsed.offset,
                    parserState: parsed.stateData,
                    parserStateVersion: Self.parserStateVersion
                ),
                replacingPriorGenerations: replacingPriorGenerations,
                resettingSource: reset
            )
        }
        return TranscriptIndexResult(
            sourceID: identity.sourceID,
            generation: identity.generation,
            previousOffset: storedOffset,
            committedOffset: parsed.offset,
            indexedRecordCount: parsed.records.count,
            records: parsed.records,
            diagnostics: parsed.diagnostics,
            replacedGeneration: reset
        )
    }

    private func decodeClaude(_ checkpoint: TranscriptCheckpoint?, offset: Int64) throws -> ClaudeUsageParserState {
        guard let checkpoint else { return .init(byteOffset: offset) }
        guard checkpoint.parserStateVersion == Self.parserStateVersion else { throw TranscriptIndexerError.unsupportedParserState }
        return try StateCodec.decodeClaude(checkpoint.parserState)
    }

    private func decodeCodex(_ checkpoint: TranscriptCheckpoint?, offset: Int64) throws -> CodexUsageParserState {
        guard let checkpoint else { return .init(byteOffset: offset) }
        guard checkpoint.parserStateVersion == Self.parserStateVersion else { throw TranscriptIndexerError.unsupportedParserState }
        return try StateCodec.decodeCodex(checkpoint.parserState)
    }

    private func sourceIdentity(for url: URL) throws -> (sourceID: String, generation: String) {
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .creationDateKey])
        let resource = values.fileResourceIdentifier.map { String(describing: $0) } ?? "unknown"
        let creation = values.creationDate?.timeIntervalSince1970.description ?? "unknown"
        let generationMaterial = "\(resource)|\(creation)"
        return (SourceID.hash(path: canonicalPath), Self.digest(generationMaterial))
    }

    private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TranscriptIndexerError: Error, Equatable, Sendable {
    case unsupportedParserState
    case corruptParserState
}

private struct ParsedBatch {
    let records: [TranscriptUsageRecord]
    let diagnostics: [TranscriptParserDiagnostic]
    let offset: Int64
    let stateData: Data
}

private enum StateCodec {
    private struct ClaudeState: Codable {
        let lineNumber: Int; let byteOffset: Int64; let sessionID: String?
    }
    private struct Snapshot: Codable {
        let inputTokens: Int; let cachedInputTokens: Int; let cacheCreationInputTokens: Int; let outputTokens: Int
        let reasoningOutputTokens: Int; let totalTokens: Int
    }
    private struct CodexState: Codable {
        let lineNumber: Int; let byteOffset: Int64; let sessionID: String?
        let model: String?; let previousUsage: Snapshot?; let sawSessionMeta: Bool
        let suppressCopiedUsage: Bool; let forkCopyAnchorAt: Date?
    }

    static func encode(_ state: ClaudeUsageParserState) throws -> Data {
        try JSONEncoder().encode(ClaudeState(lineNumber: state.lineNumber, byteOffset: state.byteOffset, sessionID: state.sessionID))
    }

    static func encode(_ state: CodexUsageParserState) throws -> Data {
        let snapshot = state.previousUsage.map {
            Snapshot(inputTokens: $0.inputTokens, cachedInputTokens: $0.cachedInputTokens, cacheCreationInputTokens: $0.cacheCreationInputTokens, outputTokens: $0.outputTokens, reasoningOutputTokens: $0.reasoningOutputTokens, totalTokens: $0.totalTokens)
        }
        return try JSONEncoder().encode(CodexState(
            lineNumber: state.lineNumber, byteOffset: state.byteOffset, sessionID: state.sessionID,
            model: state.model, previousUsage: snapshot, sawSessionMeta: state.sawSessionMeta,
            suppressCopiedUsage: state.suppressCopiedUsage, forkCopyAnchorAt: state.forkCopyAnchorAt
        ))
    }

    static func decodeClaude(_ data: Data) throws -> ClaudeUsageParserState {
        guard let value = try? JSONDecoder().decode(ClaudeState.self, from: data) else { throw TranscriptIndexerError.corruptParserState }
        return .init(lineNumber: value.lineNumber, byteOffset: value.byteOffset, sessionID: value.sessionID)
    }

    static func decodeCodex(_ data: Data) throws -> CodexUsageParserState {
        guard let value = try? JSONDecoder().decode(CodexState.self, from: data) else { throw TranscriptIndexerError.corruptParserState }
        let snapshot = value.previousUsage.map {
            CodexUsageParserState.UsageSnapshot(inputTokens: $0.inputTokens, cachedInputTokens: $0.cachedInputTokens, cacheCreationInputTokens: $0.cacheCreationInputTokens, outputTokens: $0.outputTokens, reasoningOutputTokens: $0.reasoningOutputTokens, totalTokens: $0.totalTokens)
        }
        return .init(
            lineNumber: value.lineNumber, byteOffset: value.byteOffset, sessionID: value.sessionID,
            model: value.model, previousUsage: snapshot, sawSessionMeta: value.sawSessionMeta,
            suppressCopiedUsage: value.suppressCopiedUsage, forkCopyAnchorAt: value.forkCopyAnchorAt
        )
    }
}
