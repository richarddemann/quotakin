import Foundation
import Testing
@testable import UsageCore

private func accountingFixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures/AccountingV2"
        )
    )
    return try Data(contentsOf: url)
}

private func chunksAroundMiddleLine(_ data: Data) -> (Data, Data) {
    let newlineOffsets = data.indices.filter { data[$0] == UInt8(ascii: "\n") }
    guard let splitNewline = newlineOffsets.dropFirst(max(newlineOffsets.count / 2 - 1, 0)).first else {
        return (data, Data())
    }
    let boundary = data.index(after: splitNewline)
    return (Data(data[..<boundary]), Data(data[boundary...]))
}

@Test
func claudeUsesGlobalLogicalIdentityAndPreservesReportedCost() throws {
    let result = ClaudeUsageParser.parse(
        try accountingFixture("claude-duplicates"),
        sourceID: "claude-source-a"
    )

    #expect(result.records.count == 3)
    #expect(result.records[0].logicalDedupeKey == result.records[1].logicalDedupeKey)
    #expect(result.records[0].logicalDedupeKey.hasPrefix("request:"))
    #expect(!result.records[0].logicalDedupeKey.contains("req-1"))
    #expect(result.records[0].model == "claude-sonnet-4-6")
    #expect(result.records[0].totals.processedTokens == 19)
    #expect(result.records[0].reportedCostUSD == Decimal(string: "0.001"))
}

@Test
func claudeContinuesAfterMalformedAndInvalidLines() throws {
    let result = ClaudeUsageParser.parse(
        try accountingFixture("claude-malformed"),
        sourceID: "claude-source"
    )

    #expect(result.records.count == 1)
    #expect(result.diagnostics == [
        .init(lineNumber: 2, reason: .malformedJSON),
        .init(lineNumber: 3, reason: .invalidUsage),
    ])
}

@Test
func codexTracksModelSuppressesConsecutiveDuplicatesAndUsesDisjointTokens() throws {
    let result = CodexUsageParser.parse(
        try accountingFixture("codex-model-switch-and-duplicates"),
        sourceID: "codex-source"
    )

    #expect(result.records.count == 2)
    #expect(result.records.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-terra"])
    #expect(result.records[0].totals.uncachedInputTokens == 50)
    #expect(result.records[0].totals.cachedInputTokens == 40)
    #expect(result.records[0].totals.cacheCreationInputTokens == 10)
    #expect(result.records[0].totals.outputTokens == 12)
    #expect(result.records[0].totals.reasoningOutputTokens == 3)
    #expect(result.records[0].totals.processedTokens == 112)
    #expect(result.records[0].diagnostics.isEmpty)
}

@Test
func codexSuppressesEntireDirectForkCopyBurstAndClampsReasoning() throws {
    let result = CodexUsageParser.parse(
        try accountingFixture("codex-fork-copy-burst"),
        sourceID: "child-source"
    )

    #expect(result.records.count == 1)
    #expect(result.records[0].totals.uncachedInputTokens == 30)
    #expect(result.records[0].totals.cachedInputTokens == 80)
    #expect(result.records[0].totals.cacheCreationInputTokens == 10)
    #expect(result.records[0].totals.outputTokens == 20)
    #expect(result.records[0].totals.reasoningOutputTokens == 20)
    #expect(result.records[0].totals.processedTokens == 140)
}

@Test
func codexSuppressesCopiedSubagentHistoryAndReportsMalformedLines() throws {
    let result = CodexUsageParser.parse(
        try accountingFixture("codex-subagent-and-malformed"),
        sourceID: "child-source"
    )

    #expect(result.records.count == 1)
    #expect(result.records[0].totals.uncachedInputTokens == 20)
    #expect(result.records[0].totals.processedTokens == 35)
    #expect(result.diagnostics == [.init(lineNumber: 4, reason: .malformedJSON)])
}

@Test
func parserCheckpointReplayMatchesWholeFileParsing() throws {
    let claudeData = try accountingFixture("claude-duplicates")
    let (claudeFirstData, claudeSecondData) = chunksAroundMiddleLine(claudeData)
    let claudeWhole = ClaudeUsageParser.parse(claudeData, sourceID: "claude-source")
    let claudeFirst = ClaudeUsageParser.parse(claudeFirstData, sourceID: "claude-source")
    let claudeSecond = ClaudeUsageParser.parse(
        claudeSecondData,
        sourceID: "claude-source",
        state: claudeFirst.state
    )
    #expect(claudeFirst.records + claudeSecond.records == claudeWhole.records)
    #expect(claudeSecond.state == claudeWhole.state)

    let codexData = try accountingFixture("codex-model-switch-and-duplicates")
    let (codexFirstData, codexSecondData) = chunksAroundMiddleLine(codexData)
    let codexWhole = CodexUsageParser.parse(codexData, sourceID: "codex-source")
    let codexFirst = CodexUsageParser.parse(codexFirstData, sourceID: "codex-source")
    let codexSecond = CodexUsageParser.parse(
        codexSecondData,
        sourceID: "codex-source",
        state: codexFirst.state
    )
    #expect(codexFirst.records + codexSecond.records == codexWhole.records)
    #expect(codexSecond.state == codexWhole.state)
}

@Test
func truncatingSamePhysicalFileRemovesStaleIndexedRecords() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-v2-truncation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("session.jsonl")
    let firstContents = """
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"s","requestId":"old-1","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}
    {"type":"assistant","timestamp":"2026-08-01T10:01:00Z","sessionId":"s","requestId":"old-2","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":20,"output_tokens":3}}}

    """
    try Data(firstContents.utf8).write(to: transcript)
    let store = try UsageStore.inMemory()
    let indexer = TranscriptIndexer()

    let first = try await indexer.index(file: transcript, provider: .claude, into: store)
    #expect(try await store.canonicalTranscriptRecords().count == 2)

    let replacement = """
    {"type":"assistant","timestamp":"2026-08-01T11:00:00Z","sessionId":"s","requestId":"new-1","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":4,"output_tokens":1}}}

    """
    try Data(replacement.utf8).write(to: transcript)
    let second = try await indexer.index(file: transcript, provider: .claude, into: store)

    #expect(second.generation == first.generation)
    #expect(second.replacedGeneration)
    #expect(try await store.canonicalTranscriptRecords().count == 1)
    #expect(try await store.canonicalTranscriptRecords().allSatisfy { !$0.logicalDedupeKey.contains("new-1") })
}

@Test
func indexerAcceptsCompleteEOFRecordAndCheckpointsExactFileSize() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-v2-eof-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("session.jsonl")
    let line = """
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"s","requestId":"eof-1","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}
    """
    let data = Data(line.utf8)
    try data.write(to: transcript)
    let store = try UsageStore.inMemory()
    let indexer = TranscriptIndexer()

    let first = try await indexer.index(file: transcript, provider: .claude, into: store)
    let second = try await indexer.index(file: transcript, provider: .claude, into: store)

    #expect(first.indexedRecordCount == 1)
    #expect(first.committedOffset == Int64(data.count))
    #expect(second.indexedRecordCount == 0)
    #expect(try await store.canonicalTranscriptRecords().count == 1)
    #expect(try await store.canonicalTranscriptRecords().allSatisfy { !$0.logicalDedupeKey.contains("eof-1") })
    let sourceID = SourceID.hash(path: transcript.standardizedFileURL.resolvingSymlinksInPath().path)
    let checkpoint = try #require(try await store.checkpoint(sourceID: sourceID, generation: first.generation))
    #expect(!String(decoding: checkpoint.parserState, as: UTF8.self).contains("\"s\""))
}

@Test
func sameSizeRewriteResetsSourceInsteadOfKeepingStalePrefix() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-v2-rewrite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("session.jsonl")
    let original = """
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"session-a","requestId":"old-id-1","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}

    """
    let replacement = original
        .replacingOccurrences(of: "session-a", with: "session-b")
        .replacingOccurrences(of: "old-id-1", with: "new-id-1")
        .replacingOccurrences(of: "10:00:00", with: "11:00:00")
    #expect(original.utf8.count == replacement.utf8.count)
    try Data(original.utf8).write(to: transcript)
    let store = try UsageStore.inMemory()
    let indexer = TranscriptIndexer()

    _ = try await indexer.index(file: transcript, provider: .claude, into: store)
    try Data(replacement.utf8).write(to: transcript)
    let result = try await indexer.index(file: transcript, provider: .claude, into: store)

    #expect(result.replacedGeneration)
    let records = try await store.canonicalTranscriptRecords()
    #expect(records.count == 1)
    #expect(records.first?.timestamp == Date(timeIntervalSince1970: 1_785_582_000))
}

@Test
func parserPhysicalOffsetsIncludeBlankJSONLLines() {
    let first = """
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"s","requestId":"one","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":1}}}
    """
    let second = """
    {"type":"assistant","timestamp":"2026-08-01T10:01:00Z","sessionId":"s","requestId":"two","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":1}}}
    """
    let data = Data((first + "\n\n" + second + "\n").utf8)

    let result = ClaudeUsageParser.parse(data, sourceID: "source")

    #expect(result.records.map(\.physicalIdentity.byteOffset) == [0, Int64(first.utf8.count + 2)])
    #expect(result.state.byteOffset == Int64(data.count))
}
