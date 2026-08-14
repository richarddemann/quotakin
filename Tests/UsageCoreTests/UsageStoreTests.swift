import Foundation
import Testing
@testable import UsageCore

private let privateMarker = "synthetic-private-marker"

private func sample(
    provider: Provider = .claude,
    observedAt: Date = Date(timeIntervalSince1970: 1_780_308_000),
    inputTokens: Int = 3,
    outputTokens: Int = 20
) -> TokenSample {
    TokenSample(
        provider: provider,
        observedAt: observedAt,
        model: "claude-sonnet-4-6",
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedInputTokens: 100,
        cacheCreationInputTokens: 50,
        totalTokens: inputTokens + outputTokens + 150
    )
}

private func sample(
    provider: Provider,
    observedAt: Date,
    model: String,
    inputTokens: Int,
    outputTokens: Int,
    cachedInputTokens: Int = 0,
    cacheCreationInputTokens: Int = 0,
    reasoningOutputTokens: Int = 0
) -> TokenSample {
    TokenSample(
        provider: provider,
        observedAt: observedAt,
        model: model,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedInputTokens: cachedInputTokens,
        cacheCreationInputTokens: cacheCreationInputTokens,
        reasoningOutputTokens: reasoningOutputTokens,
        totalTokens: inputTokens + outputTokens + cachedInputTokens + cacheCreationInputTokens
    )
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date!
}

private func quota() -> QuotaSnapshot {
    QuotaSnapshot(
        provider: .claude,
        window: .session,
        usedPercent: 42,
        resetsAt: Date(timeIntervalSince1970: 1_780_300_000),
        observedAt: Date(timeIntervalSince1970: 1_780_308_300)
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func claudeLine(
    timestamp: String,
    inputTokens: Int,
    outputTokens: Int
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}
    """
}

private func codexLine(timestamp: String = "2026-06-01T10:00:00Z") -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":12,"reasoning_output_tokens":3,"total_tokens":135}}}}
    """
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private func discoveredSourceID(in root: URL) throws -> String {
    let url = try #require(IncrementalJSONL.files(in: [root]).first)
    return SourceID.hash(path: url.path)
}

@Test
func importCursorStoresHashWithoutSourcePath() async throws {
    let store = try UsageStore.inMemory()
    let privatePath = "/Users/private/\(privateMarker)/transcript.jsonl"
    let sourceID = SourceID.hash(path: privatePath)

    try await store.saveCursor(sourceID: sourceID, byteOffset: 120)

    #expect(try await store.cursor(for: sourceID) == 120)
    #expect(!SourceID.hash(path: privatePath).contains(privatePath))
    #expect(!String(decoding: try await store.databaseText(), as: UTF8.self).contains(privatePath))
}

@Test
func cursorAdvanceRejectsStaleOffset() async throws {
    let store = try UsageStore.inMemory()
    let sourceID = "synthetic-source"

    #expect(try await store.advanceCursor(sourceID: sourceID, from: 0, to: 120))
    #expect(try await store.advanceCursor(sourceID: sourceID, from: 120, to: 240))
    #expect(!(try await store.advanceCursor(sourceID: sourceID, from: 120, to: 180)))
    #expect(try await store.cursor(for: sourceID) == 240)
}

@Test
func cursorAdvanceInsertsNewSourceOnlyFromZero() async throws {
    let store = try UsageStore.inMemory()
    let sourceID = "synthetic-source"

    #expect(!(try await store.advanceCursor(sourceID: sourceID, from: 120, to: 240)))
    #expect(try await store.cursor(for: sourceID) == nil)
    #expect(try await store.advanceCursor(sourceID: sourceID, from: 0, to: 120))
    #expect(try await store.cursor(for: sourceID) == 120)
}

@Test
func cursorResetAfterTruncationReplacesHigherOffset() async throws {
    let store = try UsageStore.inMemory()
    let sourceID = "synthetic-source"

    #expect(try await store.advanceCursor(sourceID: sourceID, from: 0, to: 240))
    #expect(!(try await store.advanceCursor(sourceID: sourceID, from: 240, to: 80)))
    #expect(
        try await store.resetCursorAfterTruncation(
            sourceID: sourceID,
            from: 240,
            to: 80
        )
    )
    #expect(try await store.cursor(for: sourceID) == 80)
}

@Test
func savingSameSampleTwiceDoesNotDoubleCount() async throws {
    let store = try UsageStore.inMemory()
    let token = sample()

    try await store.save(tokens: [token, token], quota: [])

    #expect(try await store.tokenTotal(provider: .claude) == token.totalTokens)
}

@Test
func savingSameQuotaTwiceDeduplicatesStoredSnapshot() async throws {
    let store = try UsageStore.inMemory()
    let snapshot = quota()

    try await store.save(tokens: [], quota: [snapshot, snapshot])

    let databaseText = String(decoding: try await store.databaseText(), as: UTF8.self)
    #expect(databaseText.components(separatedBy: "quota:\(snapshot.provider.rawValue)").count - 1 == 1)
}

@Test
func savingNewQuotaReplacesOlderSnapshotForTheSameSourceAndWindow() async throws {
    let store = try UsageStore.inMemory()
    let reset = Date(timeIntervalSince1970: 10_000)

    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 42,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ),
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 55,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_100)
        )
    ])

    let quota = try await store.latestQuota(
        provider: .claude,
        at: Date(timeIntervalSince1970: 2_000)
    )
    let databaseText = String(decoding: try await store.databaseText(), as: UTF8.self)

    #expect(quota.count == 1)
    #expect(quota[0].usedPercent == 55)
    #expect(databaseText.components(separatedBy: "quota:claude").count - 1 == 1)
}

@Test
func quotaHistoryDeduplicatesUnchangedSnapshotsAgainstLastRetainedPoint() async throws {
    let store = try UsageStore.inMemory()
    let reset = Date(timeIntervalSince1970: 10_000)

    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 42,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ),
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 42,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_100)
        ),
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 55,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_200)
        )
    ])

    let history = try await store.quotaHistory(
        provider: .claude,
        window: .session,
        from: Date(timeIntervalSince1970: 900),
        to: Date(timeIntervalSince1970: 1_300)
    )

    #expect(history.map(\.usedPercent) == [42, 55])
    #expect(history.map(\.observedAt) == [
        Date(timeIntervalSince1970: 1_000),
        Date(timeIntervalSince1970: 1_200)
    ])
}

@Test
func quotaHistoryPrunesRowsOlderThanNinetyDaysOnWrite() async throws {
    let store = try UsageStore.inMemory()
    let reset = Date(timeIntervalSince1970: 20_000_000)
    let now = Date(timeIntervalSince1970: 10_000_000)
    let old = now.addingTimeInterval(-(91 * 24 * 60 * 60))
    let retained = now.addingTimeInterval(-(89 * 24 * 60 * 60))

    try await store.save(tokens: [], quota: [
        QuotaSnapshot(provider: .codex, window: .session, usedPercent: 10, resetsAt: reset, observedAt: old),
        QuotaSnapshot(provider: .codex, window: .session, usedPercent: 20, resetsAt: reset, observedAt: retained),
        QuotaSnapshot(provider: .codex, window: .session, usedPercent: 30, resetsAt: reset, observedAt: now)
    ])

    let history = try await store.quotaHistory(
        provider: .codex,
        window: .session,
        from: old.addingTimeInterval(-1),
        to: now.addingTimeInterval(1)
    )

    #expect(history.map(\.usedPercent) == [20, 30])
}

@Test
func quotaHistoryRangeRetrievalPreservesResetBoundary() async throws {
    let store = try UsageStore.inMemory()
    let oldReset = Date(timeIntervalSince1970: 5 * 60 * 60)
    let newReset = Date(timeIntervalSince1970: 10 * 60 * 60)

    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            source: .account,
            usedPercent: 95,
            resetsAt: oldReset,
            observedAt: Date(timeIntervalSince1970: 4.5 * 60 * 60)
        ),
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            source: .account,
            usedPercent: 8,
            resetsAt: newReset,
            observedAt: Date(timeIntervalSince1970: 5.1 * 60 * 60)
        ),
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            source: .account,
            usedPercent: 13,
            resetsAt: newReset,
            observedAt: Date(timeIntervalSince1970: 5.6 * 60 * 60)
        )
    ])

    let history = try await store.quotaHistory(
        provider: .codex,
        window: .session,
        from: Date(timeIntervalSince1970: 4 * 60 * 60),
        to: Date(timeIntervalSince1970: 6 * 60 * 60)
    )

    #expect(history.map(\.usedPercent) == [95, 8, 13])
    #expect(history.map(\.resetsAt) == [oldReset, newReset, newReset])
}

@Test
func latestQuotaPrefersAccountSourceOverNewerLocalObservation() async throws {
    let store = try UsageStore.inMemory()
    let reset = Date(timeIntervalSince1970: 10_000)
    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            source: .account,
            usedPercent: 40,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ),
        QuotaSnapshot(
            provider: .codex,
            window: .session,
            source: .local,
            usedPercent: 60,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_100)
        )
    ])

    let quota = try await store.latestQuota(
        provider: .codex,
        at: Date(timeIntervalSince1970: 2_000)
    )

    #expect(quota.count == 1)
    #expect(quota[0].source == .account)
    #expect(quota[0].usedPercent == 40)
}

@Test
func latestClaudeQuotaPrefersFreshLocalStatusOverCurrentAccount() async throws {
    let store = try UsageStore.inMemory()
    let now = Date(timeIntervalSince1970: 2_000)
    let reset = Date(timeIntervalSince1970: 10_000)
    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 40,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ),
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 60,
            resetsAt: reset,
            observedAt: now.addingTimeInterval(-60)
        )
    ])

    let quota = try await store.latestQuota(provider: .claude, at: now)

    #expect(quota.map(\.source) == [.local])
    #expect(quota.map(\.usedPercent) == [60])
}

@Test
func latestClaudeQuotaFallsBackToCurrentAccountWhenLocalStatusIsStale() async throws {
    let store = try UsageStore.inMemory()
    let now = Date(timeIntervalSince1970: 2_000)
    let reset = Date(timeIntervalSince1970: 10_000)
    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 40,
            resetsAt: reset,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ),
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .local,
            usedPercent: 60,
            resetsAt: reset,
            observedAt: now.addingTimeInterval(-601)
        )
    ])

    let quota = try await store.latestQuota(provider: .claude, at: now)

    #expect(quota.map(\.source) == [.account])
    #expect(quota.map(\.usedPercent) == [40])
}

@Test
func migrationCreatesLatestSchema() async throws {
    let store = try UsageStore.inMemory()

    #expect(try await store.schemaVersion() == 7)
    #expect(
        try await store.tableNames()
            == [
                "cloud_usage_summaries", "import_cursors", "physical_usage_records",
                "quota_snapshot_history", "quota_snapshots", "token_samples",
                "transcript_checkpoints", "transcript_sources", "usage_accounting_metadata",
                "usage_reindex"
            ]
    )
}

@Test
func cloudUsageSummariesPersistSeparatelyFromLocalSamples() async throws {
    let store = try UsageStore.inMemory()
    let rangeStart = Date(timeIntervalSince1970: 1_730_419_200)
    let rangeEnd = Date(timeIntervalSince1970: 1_730_505_600)

    try await store.save(cloudUsage: [
        CloudUsageSummary(
            provider: .codex,
            source: .openAIOrganizationUsage,
            dataKind: .apiPlatformUsage,
            observedAt: Date(timeIntervalSince1970: 1_730_506_000),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            inputTokens: 100,
            outputTokens: 40,
            cachedInputTokens: 25,
            requestCount: 3,
            costAmount: 0.06,
            costCurrency: "usd"
        )
    ])

    let summaries = try await store.cloudUsageSummaries(provider: .codex)

    #expect(summaries.count == 1)
    #expect(summaries[0].provider == .codex)
    #expect(summaries[0].source == .openAIOrganizationUsage)
    #expect(summaries[0].dataKind == .apiPlatformUsage)
    #expect(summaries[0].inputTokens == 100)
    #expect(summaries[0].cachedInputTokens == 25)
    #expect(summaries[0].outputTokens == 40)
    #expect(summaries[0].requestCount == 3)
    #expect(summaries[0].sessionCount == 0)
    #expect(summaries[0].costAmount == 0.06)
    #expect(summaries[0].costCurrency == "usd")
    #expect(try await store.tokenTotal(provider: .codex) == 0)
}

@Test
func usageHistoryReturnsEmptyBucketsForEmptyRange() async throws {
    let store = try UsageStore.inMemory()
    let calendar = Calendar(identifier: .gregorian)
    let endDate = date(2026, 6, 1, 10)

    let history = try await store.usageHistorySeries(
        range: .fiveHours,
        endingAt: endDate,
        calendar: calendar
    )

    #expect(history.range == .fiveHours)
    #expect(history.bucketSize == .fifteenMinutes)
    #expect(history.start == date(2026, 6, 1, 5))
    #expect(history.providers.count == Provider.allCases.count)
    #expect(history.providers.allSatisfy { $0.buckets.count == 20 })
    #expect(history.providers.allSatisfy { provider in
        provider.buckets.allSatisfy {
            $0.tokens.total == 0 && $0.estimatedCost == 0 && $0.unknownPricingSampleCount == 0
        }
    })
    #expect(history.providers.allSatisfy { $0.quotaPercentSeries.isEmpty })
}

@Test
func usageHistoryAggregatesTokensCostAndQuotaByProvider() async throws {
    let store = try UsageStore.inMemory()
    let calendar = Calendar(identifier: .gregorian)
    let endDate = date(2026, 6, 1, 11)
    try await store.save(tokens: [
        sample(
            provider: .claude,
            observedAt: date(2026, 6, 1, 10, 7),
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cachedInputTokens: 1_000_000,
            cacheCreationInputTokens: 1_000_000,
            reasoningOutputTokens: 1_000_000
        ),
        sample(
            provider: .codex,
            observedAt: date(2026, 6, 1, 10, 7),
            model: "codex",
            inputTokens: 100,
            outputTokens: 50
        ),
        sample(
            provider: .claude,
            observedAt: date(2026, 6, 1, 4, 59),
            model: "claude-sonnet-4-6",
            inputTokens: 99,
            outputTokens: 99
        )
    ], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 61,
            resetsAt: date(2026, 6, 1, 15),
            observedAt: date(2026, 6, 1, 10, 15)
        ),
        QuotaSnapshot(
            provider: .codex,
            window: .weekly,
            source: .local,
            usedPercent: 12,
            resetsAt: date(2026, 6, 2),
            observedAt: date(2026, 6, 1, 10, 20)
        )
    ])

    let history = try await store.usageHistorySeries(
        range: .fiveHours,
        endingAt: endDate,
        calendar: calendar
    )
    let claude = try #require(history.providers.first { $0.provider == .claude })
    let codex = try #require(history.providers.first { $0.provider == .codex })
    let claudeBucket = try #require(claude.buckets.first { $0.start == date(2026, 6, 1, 10) })
    let codexBucket = try #require(codex.buckets.first { $0.start == date(2026, 6, 1, 10) })

    #expect(claudeBucket.tokens.input == 1_000_000)
    #expect(claudeBucket.tokens.output == 1_000_000)
    #expect(claudeBucket.tokens.cachedInput == 1_000_000)
    #expect(claudeBucket.tokens.cacheCreationInput == 1_000_000)
    #expect(claudeBucket.tokens.reasoningOutput == 1_000_000)
    #expect(claudeBucket.estimatedCost == 22.05)
    #expect(codexBucket.tokens.total == 150)
    #expect(codexBucket.estimatedCost > 0)
    #expect(claude.quotaPercentSeries.map(\.usedPercent) == [61])
    #expect(codex.quotaPercentSeries.map(\.usedPercent) == [12])
}

@Test
func usageHistoryUsesLocalDayBucketsAcrossDSTTransition() async throws {
    let store = try UsageStore.inMemory()
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    let endDate = date(2026, 3, 31, 12, timeZone: berlin)
    try await store.save(tokens: [
        sample(
            provider: .claude,
            observedAt: date(2026, 3, 29, 1, 30, timeZone: berlin),
            model: "claude-sonnet-4-6",
            inputTokens: 10,
            outputTokens: 5
        ),
        sample(
            provider: .claude,
            observedAt: date(2026, 3, 29, 3, 30, timeZone: berlin),
            model: "claude-sonnet-4-6",
            inputTokens: 20,
            outputTokens: 5
        )
    ], quota: [])

    let history = try await store.usageHistorySeries(
        range: .sevenDays,
        endingAt: endDate,
        calendar: calendar
    )
    let claude = try #require(history.providers.first { $0.provider == .claude })
    let dstBucket = try #require(
        claude.buckets.first { $0.start == date(2026, 3, 29, timeZone: berlin) }
    )

    #expect(dstBucket.end == date(2026, 3, 30, timeZone: berlin))
    #expect(dstBucket.end.timeIntervalSince(dstBucket.start) == 23 * 60 * 60)
    #expect(dstBucket.tokens.input == 30)
    #expect(dstBucket.tokens.output == 10)
}

@Test
func calendarDayRangesContainTheNamedNumberOfDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let endDate = date(2026, 8, 14, 12, timeZone: calendar.timeZone)

    #expect(UsageHistoryRange.sevenDays.startDate(endingAt: endDate, calendar: calendar)
        == date(2026, 8, 8, timeZone: calendar.timeZone))
    #expect(UsageHistoryRange.thirtyDays.startDate(endingAt: endDate, calendar: calendar)
        == date(2026, 7, 16, timeZone: calendar.timeZone))
    #expect(UsageHistoryRange.ninetyDays.startDate(endingAt: endDate, calendar: calendar)
        == date(2026, 5, 17, timeZone: calendar.timeZone))
}

@Test
func usageHistoryKeepsProvidersIsolatedInSameBucket() async throws {
    let store = try UsageStore.inMemory()
    let calendar = Calendar(identifier: .gregorian)
    let observedAt = date(2026, 6, 1, 9, 30)
    try await store.save(tokens: [
        sample(
            provider: .claude,
            observedAt: observedAt,
            model: "claude-sonnet-4-6",
            inputTokens: 10,
            outputTokens: 1
        ),
        sample(
            provider: .codex,
            observedAt: observedAt,
            model: "codex",
            inputTokens: 20,
            outputTokens: 2
        )
    ], quota: [])

    let history = try await store.usageHistorySeries(
        range: .twentyFourHours,
        endingAt: date(2026, 6, 1, 12),
        calendar: calendar
    )
    let claude = try #require(history.providers.first { $0.provider == .claude })
    let codex = try #require(history.providers.first { $0.provider == .codex })
    let claudeBucket = try #require(claude.buckets.first { $0.start == date(2026, 6, 1, 9) })
    let codexBucket = try #require(codex.buckets.first { $0.start == date(2026, 6, 1, 9) })

    #expect(claudeBucket.tokens.total == 11)
    #expect(codexBucket.tokens.total == 22)
}

@Test
func savingCloudSummaryForSameSourceAndRangeReplacesPriorValue() async throws {
    let store = try UsageStore.inMemory()
    let rangeStart = Date(timeIntervalSince1970: 1_730_419_200)
    let rangeEnd = Date(timeIntervalSince1970: 1_730_505_600)

    try await store.save(cloudUsage: [
        CloudUsageSummary(
            provider: .claude,
            source: .anthropicClaudeCodeAnalytics,
            dataKind: .dailyCloudAnalytics,
            observedAt: Date(timeIntervalSince1970: 1_730_506_000),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            inputTokens: 100,
            outputTokens: 40,
            cachedInputTokens: 25,
            cacheCreationInputTokens: 5,
            sessionCount: 3,
            costAmount: 0.06,
            costCurrency: "USD"
        ),
        CloudUsageSummary(
            provider: .claude,
            source: .anthropicClaudeCodeAnalytics,
            dataKind: .dailyCloudAnalytics,
            observedAt: Date(timeIntervalSince1970: 1_730_506_300),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            inputTokens: 130,
            outputTokens: 50,
            cachedInputTokens: 30,
            cacheCreationInputTokens: 7,
            sessionCount: 4,
            costAmount: 0.09,
            costCurrency: "USD"
        )
    ])

    let summaries = try await store.cloudUsageSummaries(provider: .claude)

    #expect(summaries.count == 1)
    #expect(summaries[0].observedAt == Date(timeIntervalSince1970: 1_730_506_300))
    #expect(summaries[0].inputTokens == 130)
    #expect(summaries[0].sessionCount == 4)
    #expect(summaries[0].costAmount == 0.09)
}

@Test
func truncatedSourceRestartsAtBeginning() {
    #expect(ImportCursor.nextOffset(storedOffset: 120, currentSize: 40) == 0)
    #expect(ImportCursor.nextOffset(storedOffset: 40, currentSize: 120) == 40)
}

@Test
func databaseContainsNoRawPathOrPrivateMarker() async throws {
    let store = try UsageStore.inMemory()
    let privatePath = "/Users/private/\(privateMarker)/transcript.jsonl"

    try await store.save(tokens: [sample()], quota: [quota()])
    try await store.saveCursor(sourceID: SourceID.hash(path: privatePath), byteOffset: 120)

    let databaseText = String(decoding: try await store.databaseText(), as: UTF8.self)
    #expect(!databaseText.contains(privatePath))
    #expect(!databaseText.contains(privateMarker))
}

@Test
func claudeIncrementalImportReadsOnlyNewCompleteLines() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent(privateMarker, isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let transcript = nested.appendingPathComponent("transcript.jsonl")
    try Data((claudeLine(timestamp: "2026-06-01T10:00:00Z", inputTokens: 3, outputTokens: 20) + "\n").utf8)
        .write(to: transcript)
    let store = try UsageStore.inMemory()
    let collector = ClaudeCollector(roots: [root])

    _ = try await collector.collectIncrementally(into: store)
    _ = try await collector.collectIncrementally(into: store)
    #expect(try await store.tokenTotal(provider: .claude) == 23)

    try append(
        claudeLine(timestamp: "2026-06-01T10:01:00Z", inputTokens: 4, outputTokens: 21) + "\n",
        to: transcript
    )
    _ = try await collector.collectIncrementally(into: store)

    #expect(try await store.tokenTotal(provider: .claude) == 48)
}

@Test
func claudeIncrementalImportRestartsAfterTruncation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    try Data((claudeLine(timestamp: "2026-06-01T10:00:00Z", inputTokens: 300, outputTokens: 200) + "\n").utf8)
        .write(to: transcript)
    let store = try UsageStore.inMemory()
    let collector = ClaudeCollector(roots: [root])
    _ = try await collector.collectIncrementally(into: store)

    try Data((claudeLine(timestamp: "2026-06-01T10:01:00Z", inputTokens: 4, outputTokens: 21) + "\n").utf8)
        .write(to: transcript)
    _ = try await collector.collectIncrementally(into: store)

    #expect(try await store.tokenTotal(provider: .claude) == 525)
}

@Test
func claudeIncrementalImportWaitsForTrailingLineCompletion() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    let completeLine = claudeLine(timestamp: "2026-06-01T10:00:00Z", inputTokens: 3, outputTokens: 20)
    let pendingLine = claudeLine(timestamp: "2026-06-01T10:01:00Z", inputTokens: 4, outputTokens: 21)
    let splitIndex = pendingLine.index(pendingLine.startIndex, offsetBy: pendingLine.count / 2)
    let pendingPrefix = String(pendingLine[..<splitIndex])
    let pendingSuffix = String(pendingLine[splitIndex...])
    try Data((completeLine + "\n" + pendingPrefix).utf8).write(to: transcript)
    let store = try UsageStore.inMemory()
    let collector = ClaudeCollector(roots: [root])

    _ = try await collector.collectIncrementally(into: store)
    #expect(try await store.tokenTotal(provider: .claude) == 23)
    #expect(
        try await store.cursor(for: discoveredSourceID(in: root))
            == completeLine.utf8.count + 1
    )

    try append(pendingSuffix, to: transcript)
    _ = try await collector.collectIncrementally(into: store)

    #expect(try await store.tokenTotal(provider: .claude) == 48)
}

@Test
func claudeIncrementalImportReadsCompleteEOFOnlyRecord() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    let line = claudeLine(timestamp: "2026-06-01T10:00:00Z", inputTokens: 3, outputTokens: 20)
    try Data(line.utf8).write(to: transcript)
    let store = try UsageStore.inMemory()

    _ = try await ClaudeCollector(roots: [root]).collectIncrementally(into: store)

    #expect(try await store.tokenTotal(provider: .claude) == 23)
    #expect(try await store.cursor(for: discoveredSourceID(in: root)) == line.utf8.count)
}

@Test
func claudeIncrementalParseFailureUsesHashedSourceOnly() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent(privateMarker + ".jsonl")
    let malformedContent = #"{"private":"synthetic malformed transcript""# + "\n"
    try Data(malformedContent.utf8).write(to: transcript)
    let store = try UsageStore.inMemory()

    do {
        _ = try await ClaudeCollector(roots: [root]).collectIncrementally(into: store)
        Issue.record("Expected incremental collection to throw")
    } catch let error as CollectorError {
        #expect(error.provider == .claude)
        #expect(error.reason == .parseFailed)
        let sourceID = try discoveredSourceID(in: root)
        #expect(error.sourceID == sourceID)
        #expect(!error.description.contains(transcript.path))
        #expect(!error.description.contains(malformedContent))
        #expect(try await store.cursor(for: sourceID) == nil)
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func codexIncrementalImportDiscoversNestedJSONLAndDeduplicates() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent(privateMarker, isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let session = nested.appendingPathComponent("session.jsonl")
    try Data((codexLine() + "\n").utf8).write(to: session)
    let store = try UsageStore.inMemory()
    let collector = CodexCollector(roots: [root])

    _ = try await collector.collectIncrementally(into: store)
    _ = try await collector.collectIncrementally(into: store)

    #expect(try await store.tokenTotal(provider: .codex) == 132)
}

private func calendar(identifier: Calendar.Identifier = .gregorian, timeZoneID: String) throws -> Calendar {
    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = try #require(TimeZone(identifier: timeZoneID))
    return calendar
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    calendar: Calendar
) throws -> Date {
    try #require(
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )
    )
}

private func total(
    for provider: Provider,
    in day: DailyActivityGridDay
) throws -> Int {
    try #require(day.providerTotals.first { $0.provider == provider }).totalTokens
}

@Test
func dailyActivityGridReturnsExplicitZeroDaysForEmptyHistory() async throws {
    let store = try UsageStore.inMemory()
    let berlin = try calendar(timeZoneID: "Europe/Berlin")

    let grid = try await store.dailyActivityGrid(
        from: date(2026, 1, 1, 9, calendar: berlin),
        through: date(2026, 1, 3, 18, calendar: berlin),
        calendar: berlin
    )

    #expect(grid.days.map(\.dayStart) == [
        try date(2026, 1, 1, calendar: berlin),
        try date(2026, 1, 2, calendar: berlin),
        try date(2026, 1, 3, calendar: berlin)
    ])
    #expect(grid.minTotalTokens == 0)
    #expect(grid.maxTotalTokens == 0)
    for day in grid.days {
        #expect(try total(for: .claude, in: day) == 0)
        #expect(try total(for: .codex, in: day) == 0)
    }
}

@Test
func dailyActivityGridAggregatesAcrossYearBoundary() async throws {
    let store = try UsageStore.inMemory()
    let berlin = try calendar(timeZoneID: "Europe/Berlin")

    try await store.save(tokens: [
        sample(
            provider: .claude,
            observedAt: date(2025, 12, 31, 23, 30, calendar: berlin),
            inputTokens: 10,
            outputTokens: 5
        ),
        sample(
            provider: .codex,
            observedAt: date(2026, 1, 1, 0, 30, calendar: berlin),
            inputTokens: 20,
            outputTokens: 5
        )
    ], quota: [])

    let grid = try await store.dailyActivityGrid(
        from: date(2025, 12, 31, 12, calendar: berlin),
        through: date(2026, 1, 1, 12, calendar: berlin),
        calendar: berlin
    )
    let december31 = try date(2025, 12, 31, calendar: berlin)
    let january1 = try date(2026, 1, 1, calendar: berlin)

    #expect(grid.days.count == 2)
    #expect(grid.days[0].dayStart == december31)
    #expect(try total(for: .claude, in: grid.days[0]) == 165)
    #expect(try total(for: .codex, in: grid.days[0]) == 0)
    #expect(grid.days[1].dayStart == january1)
    #expect(try total(for: .claude, in: grid.days[1]) == 0)
    #expect(try total(for: .codex, in: grid.days[1]) == 175)
    #expect(grid.minTotalTokens == 165)
    #expect(grid.maxTotalTokens == 175)
}

@Test
func dailyActivityGridUsesLocalMidnightAcrossDSTBoundary() async throws {
    let store = try UsageStore.inMemory()
    let newYork = try calendar(timeZoneID: "America/New_York")

    try await store.save(tokens: [
        sample(
            observedAt: date(2026, 3, 8, 0, 30, calendar: newYork),
            inputTokens: 5,
            outputTokens: 5
        ),
        sample(
            observedAt: date(2026, 3, 8, 23, 30, calendar: newYork),
            inputTokens: 7,
            outputTokens: 8
        ),
        sample(
            observedAt: date(2026, 3, 9, 0, 15, calendar: newYork),
            inputTokens: 11,
            outputTokens: 4
        )
    ], quota: [])

    let grid = try await store.dailyActivityGrid(
        from: date(2026, 3, 7, 10, calendar: newYork),
        through: date(2026, 3, 9, 10, calendar: newYork),
        calendar: newYork
    )

    #expect(grid.days.map(\.dayStart) == [
        try date(2026, 3, 7, calendar: newYork),
        try date(2026, 3, 8, calendar: newYork),
        try date(2026, 3, 9, calendar: newYork)
    ])
    #expect(grid.days[1].dayStart.timeIntervalSince(grid.days[0].dayStart) == 86_400)
    #expect(grid.days[2].dayStart.timeIntervalSince(grid.days[1].dayStart) == 82_800)
    #expect(try total(for: .claude, in: grid.days[0]) == 0)
    #expect(try total(for: .claude, in: grid.days[1]) == 325)
    #expect(try total(for: .claude, in: grid.days[2]) == 165)
    #expect(grid.minTotalTokens == 0)
    #expect(grid.maxTotalTokens == 325)
}

@Test
func dailyActivityGridSingleDayIncludesBothProvidersAndMinMax() async throws {
    let store = try UsageStore.inMemory()
    let berlin = try calendar(timeZoneID: "Europe/Berlin")

    try await store.save(tokens: [
        sample(
            provider: .claude,
            observedAt: date(2026, 6, 1, 1, calendar: berlin),
            inputTokens: 1,
            outputTokens: 2
        ),
        sample(
            provider: .claude,
            observedAt: date(2026, 6, 1, 23, 59, calendar: berlin),
            inputTokens: 3,
            outputTokens: 4
        ),
        sample(
            provider: .codex,
            observedAt: date(2026, 6, 1, 12, calendar: berlin),
            inputTokens: 5,
            outputTokens: 6
        ),
        sample(
            provider: .codex,
            observedAt: date(2026, 6, 2, 0, calendar: berlin),
            inputTokens: 100,
            outputTokens: 100
        )
    ], quota: [])

    let grid = try await store.dailyActivityGrid(
        from: date(2026, 6, 1, 12, calendar: berlin),
        through: date(2026, 6, 1, 12, calendar: berlin),
        calendar: berlin
    )
    let june1 = try date(2026, 6, 1, calendar: berlin)

    #expect(grid.days.count == 1)
    #expect(grid.days[0].dayStart == june1)
    #expect(try total(for: .claude, in: grid.days[0]) == 310)
    #expect(try total(for: .codex, in: grid.days[0]) == 161)
    #expect(grid.minTotalTokens == 471)
    #expect(grid.maxTotalTokens == 471)
}

@Test
func dailyActivityGridPreservesUnpricedCoverage() async throws {
    let store = try UsageStore.inMemory()
    let calendar = Calendar(identifier: .gregorian)
    let day = date(2026, 6, 1)
    try await store.save(tokens: [
        TokenSample(
            provider: .codex,
            observedAt: day.addingTimeInterval(60),
            model: "unknown-model",
            inputTokens: 10,
            outputTokens: 0,
            totalTokens: 10
        )
    ], quota: [])

    let grid = try await store.dailyActivityGrid(from: day, through: day, calendar: calendar)
    let codex = try #require(grid.days.first?.providerTotals.first { $0.provider == .codex })

    #expect(codex.totalTokens == 10)
    #expect(codex.estimatedCost == 0)
    #expect(codex.unknownPricingSampleCount == 1)
    #expect(grid.days.first?.unknownPricingSampleCount == 1)
}
