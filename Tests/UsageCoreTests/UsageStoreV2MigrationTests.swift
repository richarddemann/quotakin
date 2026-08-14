import Foundation
import Testing
import CSQLite
@testable import UsageCore

private func makeV5Database() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-v5-\(UUID().uuidString).sqlite3")
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE token_samples (id TEXT PRIMARY KEY, provider TEXT NOT NULL, observed_at REAL NOT NULL, model TEXT,
      input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
      cache_creation_input_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL);
    CREATE TABLE quota_snapshots (id TEXT PRIMARY KEY, provider TEXT NOT NULL, window TEXT NOT NULL,
      source TEXT NOT NULL DEFAULT 'local', used_percent REAL NOT NULL, resets_at REAL, observed_at REAL NOT NULL);
    CREATE TABLE quota_snapshot_history (id TEXT PRIMARY KEY, provider TEXT NOT NULL, window TEXT NOT NULL,
      source TEXT NOT NULL DEFAULT 'local', used_percent REAL NOT NULL, resets_at REAL, observed_at REAL NOT NULL);
    CREATE TABLE import_cursors (source_id TEXT PRIMARY KEY, byte_offset INTEGER NOT NULL);
    CREATE TABLE cloud_usage_summaries (id TEXT PRIMARY KEY, provider TEXT NOT NULL, source TEXT NOT NULL,
      data_kind TEXT NOT NULL, observed_at REAL NOT NULL, range_start REAL NOT NULL, range_end REAL NOT NULL,
      input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
      cache_creation_input_tokens INTEGER NOT NULL, request_count INTEGER NOT NULL, session_count INTEGER NOT NULL,
      cost_amount REAL, cost_currency TEXT);
    INSERT INTO import_cursors VALUES ('legacy-hash', 42);
    INSERT INTO token_samples VALUES ('legacy-token', 'claude', 1000, 'legacy-model', 3, 2, 1, 0, 0);
    PRAGMA user_version = 5;
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    return url
}

private func makeUnsafeV6Database() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-v6-unsafe-\(UUID().uuidString).sqlite3")
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE physical_usage_records (
      source_id TEXT NOT NULL, source_generation TEXT NOT NULL, byte_offset INTEGER NOT NULL,
      provider TEXT NOT NULL, observed_at REAL NOT NULL, model TEXT NOT NULL, session_id TEXT,
      uncached_input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
      cache_creation_input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
      reasoning_output_tokens INTEGER NOT NULL, logical_dedupe_key TEXT,
      provider_reported_total_tokens INTEGER, reported_cost_usd TEXT, parser_version INTEGER NOT NULL,
      PRIMARY KEY (source_id, source_generation, byte_offset)
    );
    INSERT INTO physical_usage_records VALUES (
      'source', 'generation', 0, 'claude', 1000, 'model', 'raw-session-secret',
      1, 0, 0, 1, 0, 'request:raw-request-secret', 2, NULL, 2
    );
    CREATE TABLE usage_accounting_metadata (singleton INTEGER PRIMARY KEY, active_version INTEGER NOT NULL);
    INSERT INTO usage_accounting_metadata VALUES (1, 2);
    PRAGMA user_version = 6;
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    return url
}

private func record(
    provider: Provider = .claude,
    sourceID: String,
    generation: String,
    offset: Int64,
    key: String,
    input: Int = 10
) -> TranscriptUsageRecord {
    TranscriptUsageRecord(
        provider: provider,
        timestamp: Date(timeIntervalSince1970: 1_000 + Double(offset)),
        model: "model",
        totals: TranscriptTokenTotals(uncachedInputTokens: input, outputTokens: 2, reasoningOutputTokens: 1),
        physicalIdentity: TranscriptPhysicalIdentity(sourceID: sourceID, sourceGeneration: generation, byteOffset: offset),
        logicalDedupeKey: key,
        providerReportedTotalTokens: input + 2,
        reportedCostUSD: 0.01
    )
}

private func commit(
    _ store: UsageStore,
    sourceID: String,
    generation: String,
    records: [TranscriptUsageRecord],
    replacing: Bool = false
) async throws {
    try await store.commitTranscriptBatch(
        source: TranscriptSourceMetadata(
            sourceID: sourceID,
            sourceFingerprint: SourceID.hash(path: "fingerprint-\(generation)"),
            provider: records.first?.provider ?? .claude,
            generation: generation,
            parserVersion: 2
        ),
        records: records,
        checkpoint: TranscriptCheckpoint(
            sourceID: sourceID,
            sourceGeneration: generation,
            byteOffset: records.last?.physicalIdentity.byteOffset ?? 0,
            parserState: Data("state-\(generation)".utf8),
            parserStateVersion: 1
        ),
        replacingPriorGenerations: replacing
    )
}

@Test
func v2ShadowSchemaLeavesLegacyCursorReadable() async throws {
    let url = try makeV5Database()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try UsageStore(path: url.path)

    #expect(try await store.schemaVersion() == 7)
    #expect(try await store.cursor(for: "legacy-hash") == 42)
    #expect(try await store.tokenSamples(provider: .claude).map(\.model) == ["legacy-model"])
    #expect(try await store.activeAccountingVersion() == 1)
}

@Test
func unsafeV6ShadowIsDiscardedBeforePrivacySafeV7Reindex() async throws {
    let url = try makeUnsafeV6Database()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = try UsageStore(path: url.path)

    #expect(try await store.schemaVersion() == 7)
    #expect(try await store.activeAccountingVersion() == 1)
    #expect(try await store.canonicalTranscriptRecords().isEmpty)
    let persistedText = String(decoding: try await store.databaseText(), as: UTF8.self)
    #expect(!persistedText.contains("session_id"))
    #expect(!persistedText.contains("raw-session-secret"))
    #expect(!persistedText.contains("raw-request-secret"))
}

@Test
func transcriptBatchPersistsRecordsAndCheckpointAtomically() async throws {
    let store = try UsageStore.inMemory()
    let sourceID = SourceID.hash(path: "/private/transcript.jsonl")
    let item = record(sourceID: sourceID, generation: "g1", offset: 20, key: "request:r1")
    try await commit(store, sourceID: sourceID, generation: "g1", records: [item])

    #expect(try await store.canonicalTranscriptRecords() == [item])
    #expect(try await store.checkpoint(sourceID: sourceID, generation: "g1")?.parserState == Data("state-g1".utf8))
}

@Test
func canonicalQueryDeduplicatesLogicalIdentityGloballyButNotAcrossProviders() async throws {
    let store = try UsageStore.inMemory()
    let sourceA = SourceID.hash(path: "a"), sourceB = SourceID.hash(path: "b"), sourceC = SourceID.hash(path: "c")
    let claudeA = record(sourceID: sourceA, generation: "g1", offset: 1, key: "request:same")
    let claudeB = record(sourceID: sourceB, generation: "g1", offset: 2, key: "request:same", input: 99)
    let codex = record(provider: .codex, sourceID: sourceC, generation: "g1", offset: 3, key: "request:same")
    try await commit(store, sourceID: sourceA, generation: "g1", records: [claudeA])
    try await commit(store, sourceID: sourceB, generation: "g1", records: [claudeB])
    try await commit(store, sourceID: sourceC, generation: "g1", records: [codex])

    let canonical = try await store.canonicalTranscriptRecords()
    #expect(canonical.count == 2)
    #expect(canonical.contains(claudeA))
    #expect(canonical.contains(codex))
}

@Test
func replacingSourceGenerationRemovesOnlyThatSourcesPriorShadowRows() async throws {
    let store = try UsageStore.inMemory()
    let sourceA = SourceID.hash(path: "a"), sourceB = SourceID.hash(path: "b")
    let old = record(sourceID: sourceA, generation: "old", offset: 1, key: "event:old")
    let other = record(sourceID: sourceB, generation: "g1", offset: 2, key: "event:other")
    let replacement = record(sourceID: sourceA, generation: "new", offset: 0, key: "event:new")
    try await commit(store, sourceID: sourceA, generation: "old", records: [old])
    try await commit(store, sourceID: sourceB, generation: "g1", records: [other])
    try await commit(store, sourceID: sourceA, generation: "new", records: [replacement], replacing: true)

    let canonical = try await store.canonicalTranscriptRecords()
    #expect(canonical == [replacement, other])
    #expect(try await store.checkpoint(sourceID: sourceA, generation: "old") == nil)
}

@Test
func invalidBatchRollsBackWithoutPublishingSourceOrCheckpoint() async throws {
    let store = try UsageStore.inMemory()
    let expected = SourceID.hash(path: "expected"), different = SourceID.hash(path: "different")
    let mismatched = record(sourceID: different, generation: "g1", offset: 1, key: "event:bad")

    await #expect(throws: Error.self) {
        try await commit(store, sourceID: expected, generation: "g1", records: [mismatched])
    }
    #expect(try await store.canonicalTranscriptRecords().isEmpty)
    #expect(try await store.checkpoint(sourceID: expected, generation: "g1") == nil)
}

@Test
func transcriptPersistenceRejectsRawSourcePaths() async throws {
    let store = try UsageStore.inMemory()
    let rawPath = "/Users/private/transcript.jsonl"
    let item = record(sourceID: rawPath, generation: "g1", offset: 1, key: "event:bad")

    await #expect(throws: Error.self) {
        try await commit(store, sourceID: rawPath, generation: "g1", records: [item])
    }
    #expect(try await store.canonicalTranscriptRecords().isEmpty)
}

@Test
func lifecycleMetadataAndActiveVersionRoundTrip() async throws {
    let store = try UsageStore.inMemory()
    let started = Date(timeIntervalSince1970: 1_000)
    try await store.saveReindexMetadata(UsageReindexMetadata(id: "job-1", fromAccountingVersion: 1, toAccountingVersion: 2, state: .running, startedAt: started))
    #expect(try await store.reindexMetadata(id: "job-1") == UsageReindexMetadata(id: "job-1", fromAccountingVersion: 1, toAccountingVersion: 2, state: .running, startedAt: started))
    try await store.setActiveAccountingVersion(2)
    #expect(try await store.activeAccountingVersion() == 2)
    await #expect(throws: Error.self) { try await store.setActiveAccountingVersion(3) }
}

@Test
func backupCreatesReadableConsistentDatabase() async throws {
    let store = try UsageStore.inMemory()
    try await store.saveCursor(sourceID: "legacy", byteOffset: 81)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-backup-\(UUID().uuidString).sqlite3")
    defer { try? FileManager.default.removeItem(at: url) }
    try await store.backup(to: url.path)
    let backup = try UsageStore(path: url.path)
    #expect(try await backup.cursor(for: "legacy") == 81)
}

@Test
func validationCountsRowsAndInactiveResetIsGuarded() async throws {
    let store = try UsageStore.inMemory()
    let sourceID = SourceID.hash(path: "validation")
    let item = record(sourceID: sourceID, generation: "g1", offset: 1, key: "event:1")
    try await commit(store, sourceID: sourceID, generation: "g1", records: [item])
    #expect(try await store.validateTranscriptIndex() == TranscriptIndexValidation(sourceCount: 1, checkpointCount: 1, physicalRecordCount: 1, orphanCheckpointCount: 0, orphanRecordCount: 0, invalidTokenRecordCount: 0))
    await #expect(throws: Error.self) { try await store.resetInactiveTranscriptIndex(accountingVersion: 1) }
    try await store.resetInactiveTranscriptIndex(accountingVersion: 2)
    #expect(try await store.validateTranscriptIndex().physicalRecordCount == 0)
}

@Test
func activeV2QueriesUseCanonicalNormalizedRecordsAndRollbackRestoresLegacyRows() async throws {
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [
        TokenSample(
            provider: .codex,
            observedAt: Date(timeIntervalSince1970: 900),
            model: "legacy-codex",
            inputTokens: 10,
            outputTokens: 2,
            cachedInputTokens: 5,
            reasoningOutputTokens: 1,
            totalTokens: 17
        )
    ], quota: [])

    let sourceA = SourceID.hash(path: "v2-a")
    let sourceB = SourceID.hash(path: "v2-b")
    let first = record(
        provider: .codex,
        sourceID: sourceA,
        generation: "g1",
        offset: 1,
        key: "event:same"
    )
    let duplicate = record(
        provider: .codex,
        sourceID: sourceB,
        generation: "g1",
        offset: 2,
        key: "event:same",
        input: 99
    )
    try await commit(store, sourceID: sourceA, generation: "g1", records: [first])
    try await commit(store, sourceID: sourceB, generation: "g1", records: [duplicate])

    try await store.setActiveAccountingVersion(2)

    let activeSamples = try await store.tokenSamples(provider: .codex)
    #expect(activeSamples.count == 1)
    #expect(activeSamples.first?.model == "model")
    #expect(activeSamples.first?.totalTokens == 12)
    #expect(activeSamples.first?.reasoningOutputTokens == 1)
    #expect(activeSamples.first?.reportedCostUSD == 0.01)
    #expect(try await store.tokenTotal(provider: .codex) == 12)

    let history = try await store.usageHistorySeries(
        range: .fiveHours,
        endingAt: Date(timeIntervalSince1970: 1_100),
        calendar: Calendar(identifier: .gregorian)
    )
    let costBucket = try #require(
        history.providers.first { $0.provider == .codex }?.buckets.first { $0.tokens.total > 0 }
    )
    #expect(costBucket.estimatedCost == 0.01)
    #expect(costBucket.estimatedCostProvenance == .providerReported)

    let calendar = Calendar(identifier: .gregorian)
    let grid = try await store.dailyActivityGrid(
        from: Date(timeIntervalSince1970: 0),
        through: Date(timeIntervalSince1970: 86_400),
        calendar: calendar
    )
    #expect(grid.days.flatMap(\.providerTotals).first { $0.provider == .codex }?.totalTokens == 12)

    try await store.setActiveAccountingVersion(1)
    let legacySamples = try await store.tokenSamples(provider: .codex)
    #expect(legacySamples.map(\.model) == ["legacy-codex"])
    #expect(legacySamples.first?.totalTokens == 17)
}

@Test
func completedReindexRollsBackAtomicallyToUntouchedLegacyAccounting() async throws {
    let store = try UsageStore.inMemory()
    let started = Date(timeIntervalSince1970: 1_000)
    try await store.saveReindexMetadata(.init(
        id: "rollback-job",
        fromAccountingVersion: 1,
        toAccountingVersion: 2,
        state: .completed,
        startedAt: started,
        completedAt: Date(timeIntervalSince1970: 1_100)
    ))
    try await store.setActiveAccountingVersion(2)
    let coordinator = UsageReindexCoordinator(
        store: store,
        backupDirectory: FileManager.default.temporaryDirectory
    )

    try await coordinator.rollback(id: "rollback-job")

    #expect(try await store.activeAccountingVersion() == 1)
    #expect(try await store.reindexMetadata(id: "rollback-job")?.state == .rolledBack)
}

@Test
func reindexResultRetainsParserAndDuplicateDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-reindex-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("session.jsonl")
    try Data("""
    {not-json}
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"session","requestId":"same-request","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}
    {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"session","requestId":"same-request","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}

    """.utf8).write(to: transcript)
    let store = try UsageStore.inMemory()
    let coordinator = UsageReindexCoordinator(store: store, backupDirectory: root)

    let result = try await coordinator.run(id: "diagnostics") {
        [TranscriptIndexSource(url: transcript, provider: .claude)]
    }

    #expect(result.parserDiagnosticCounts[.malformedJSON] == 1)
    #expect(result.duplicateRecordCount == 1)
    #expect(result.indexedRecordCount == 2)
}
