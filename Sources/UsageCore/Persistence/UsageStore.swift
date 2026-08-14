import CryptoKit
import CSQLite
import Foundation

public enum SourceID {
    public static func hash(path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

public enum ImportCursor {
    public static func nextOffset(storedOffset: Int, currentSize: Int) -> Int {
        storedOffset <= currentSize ? storedOffset : 0
    }
}

public actor UsageStore {
    public nonisolated let accountingBackupDirectory: URL
    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.pointer }

    public static func inMemory() throws -> UsageStore {
        try UsageStore(path: ":memory:")
    }

    public init(path: String) throws {
        accountingBackupDirectory = path == ":memory:"
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageBar-AccountingBackups", isDirectory: true)
            : URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw StoreError.openFailed
        }

        let connection = SQLiteConnection(pointer: database)
        self.connection = connection

        do {
            try Self.migrate(database)
        } catch {
            throw error
        }
    }

    public func save(tokens: [TokenSample], quota: [QuotaSnapshot]) throws {
        try execute("BEGIN TRANSACTION")

        do {
            try save(tokens: tokens)
            try save(quota: quota)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func saveCursor(sourceID: String, byteOffset: Int) throws {
        try withStatement(
            """
            INSERT INTO import_cursors (source_id, byte_offset)
            VALUES (?, ?)
            ON CONFLICT(source_id) DO UPDATE SET byte_offset = excluded.byte_offset
            """
        ) { statement in
            try bind(sourceID, at: 1, in: statement)
            try bind(byteOffset, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    public func advanceCursor(sourceID: String, from expectedOffset: Int, to byteOffset: Int) throws -> Bool {
        guard byteOffset >= expectedOffset else {
            return false
        }

        return try compareAndSetCursor(
            sourceID: sourceID,
            from: expectedOffset,
            to: byteOffset
        )
    }

    func resetCursorAfterTruncation(
        sourceID: String,
        from expectedOffset: Int,
        to byteOffset: Int
    ) throws -> Bool {
        guard byteOffset < expectedOffset else {
            return false
        }

        return try compareAndSetCursor(
            sourceID: sourceID,
            from: expectedOffset,
            to: byteOffset
        )
    }

    public func cursor(for sourceID: String) throws -> Int? {
        return try withStatement(
            "SELECT byte_offset FROM import_cursors WHERE source_id = ?"
        ) { statement in
            try bind(sourceID, at: 1, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return Int(sqlite3_column_int64(statement, 0))
            case SQLITE_DONE:
                return nil
            default:
                throw StoreError.statementFailed
            }
        }
    }

    /// Atomically publishes one parser batch and its checkpoint. When a source's
    /// physical generation changes, `replacingPriorGenerations` removes only the
    /// old shadow rows for that opaque (hashed) source ID.
    public func commitTranscriptBatch(
        source: TranscriptSourceMetadata,
        records: [TranscriptUsageRecord],
        checkpoint: TranscriptCheckpoint,
        replacingPriorGenerations: Bool = true,
        resettingSource: Bool = false
    ) throws {
        guard SourceID.isHash(source.sourceID),
              SourceID.isHash(source.sourceFingerprint),
              checkpoint.sourceID == source.sourceID,
              checkpoint.sourceGeneration == source.generation,
              records.allSatisfy({
                  $0.provider == source.provider
                    && $0.physicalIdentity.sourceID == source.sourceID
                    && $0.physicalIdentity.sourceGeneration == source.generation
                    && TranscriptUsageRecord.isOpaqueLogicalDedupeKey($0.logicalDedupeKey)
              }) else {
            throw StoreError.invalidTranscriptBatch
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            if resettingSource {
                try deleteTranscriptSource(sourceID: source.sourceID)
            } else if replacingPriorGenerations {
                try deleteTranscriptGenerations(sourceID: source.sourceID, except: source.generation)
            }
            try upsert(source: source)
            try insertPhysicalRecords(records, parserVersion: source.parserVersion)
            try upsert(checkpoint: checkpoint)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func checkpoint(sourceID: String, generation: String) throws -> TranscriptCheckpoint? {
        try withStatement(
            """
            SELECT byte_offset, parser_state, parser_state_version
            FROM transcript_checkpoints
            WHERE source_id = ? AND source_generation = ?
            """
        ) { statement in
            try bind(sourceID, at: 1, in: statement)
            try bind(generation, at: 2, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let count = Int(sqlite3_column_bytes(statement, 1))
                let data = sqlite3_column_blob(statement, 1).map { Data(bytes: $0, count: count) } ?? Data()
                return TranscriptCheckpoint(
                    sourceID: sourceID,
                    sourceGeneration: generation,
                    byteOffset: sqlite3_column_int64(statement, 0),
                    parserState: data,
                    parserStateVersion: Int(sqlite3_column_int64(statement, 2))
                )
            case SQLITE_DONE: return nil
            default: throw StoreError.statementFailed
            }
        }
    }

    public func transcriptSource(sourceID: String, generation: String) throws -> TranscriptSourceMetadata? {
        try withStatement(
            "SELECT source_fingerprint, provider, parser_version FROM transcript_sources WHERE source_id = ? AND source_generation = ?"
        ) { statement in
            try bind(sourceID, at: 1, in: statement)
            try bind(generation, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let fingerprint = stringColumn(statement, 0),
                  let providerText = stringColumn(statement, 1),
                  let provider = Provider(rawValue: providerText) else { throw StoreError.statementFailed }
            return TranscriptSourceMetadata(
                sourceID: sourceID,
                sourceFingerprint: fingerprint,
                provider: provider,
                generation: generation,
                parserVersion: Int(sqlite3_column_int64(statement, 2))
            )
        }
    }

    public func reconcileTranscriptSources(
        provider: Provider,
        retainingSourceIDs: Set<String>
    ) throws {
        guard retainingSourceIDs.allSatisfy(SourceID.isHash) else {
            throw StoreError.invalidTranscriptBatch
        }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let storedSourceIDs = try withStatement(
                "SELECT DISTINCT source_id FROM transcript_sources WHERE provider = ?"
            ) { statement -> [String] in
                try bind(provider.rawValue, at: 1, in: statement)
                var values: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let sourceID = stringColumn(statement, 0) else {
                        throw StoreError.statementFailed
                    }
                    values.append(sourceID)
                }
                return values
            }
            for sourceID in storedSourceIDs where !retainingSourceIDs.contains(sourceID) {
                try deleteTranscriptSource(sourceID: sourceID)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func canonicalTranscriptRecords() throws -> [TranscriptUsageRecord] {
        try withStatement(
            """
            SELECT provider, observed_at, model,
                   uncached_input_tokens, cached_input_tokens, cache_creation_input_tokens,
                   output_tokens, reasoning_output_tokens, source_id, source_generation,
                   byte_offset, logical_dedupe_key, provider_reported_total_tokens, reported_cost_usd
            FROM (
              SELECT records.*,
                     ROW_NUMBER() OVER (
                       PARTITION BY provider, logical_dedupe_key
                       ORDER BY observed_at ASC, source_id ASC, source_generation ASC, byte_offset ASC
                     ) AS logical_rank
              FROM physical_usage_records AS records
            )
            WHERE logical_dedupe_key IS NULL OR logical_rank = 1
            ORDER BY observed_at ASC, provider ASC, source_id ASC, byte_offset ASC
            """
        ) { statement in
            var records: [TranscriptUsageRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let providerText = stringColumn(statement, 0),
                      let provider = Provider(rawValue: providerText),
                      let model = stringColumn(statement, 2),
                      let sourceID = stringColumn(statement, 8),
                      let generation = stringColumn(statement, 9),
                      let logicalKey = stringColumn(statement, 11) else { throw StoreError.statementFailed }
                records.append(TranscriptUsageRecord(
                    provider: provider,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    model: model,
                    totals: TranscriptTokenTotals(
                        uncachedInputTokens: Int(sqlite3_column_int64(statement, 3)),
                        cachedInputTokens: Int(sqlite3_column_int64(statement, 4)),
                        cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 5)),
                        outputTokens: Int(sqlite3_column_int64(statement, 6)),
                        reasoningOutputTokens: Int(sqlite3_column_int64(statement, 7))
                    ),
                    physicalIdentity: TranscriptPhysicalIdentity(sourceID: sourceID, sourceGeneration: generation, byteOffset: sqlite3_column_int64(statement, 10)),
                    logicalDedupeKey: logicalKey,
                    providerReportedTotalTokens: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 12)),
                    reportedCostUSD: stringColumn(statement, 13).map { NSDecimalNumber(string: $0).decimalValue }
                ))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else { throw StoreError.statementFailed }
            return records
        }
    }

    public func activeAccountingVersion() throws -> Int {
        try withStatement("SELECT active_version FROM usage_accounting_metadata WHERE singleton = 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.statementFailed }
            let value = Int(sqlite3_column_int64(statement, 0))
            guard UsageIndexVersion(rawValue: value) != nil else { throw StoreError.invalidAccountingVersion }
            return value
        }
    }

    public func backup(to destinationPath: String) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(destinationPath, &destination) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw StoreError.openFailed
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else { throw StoreError.backupFailed }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw StoreError.backupFailed }
    }

    public func saveReindexMetadata(_ metadata: UsageReindexMetadata) throws {
        try withStatement(
            """
            INSERT INTO usage_reindex (id, from_accounting_version, to_accounting_version, state, started_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET state = excluded.state, started_at = excluded.started_at,
              completed_at = excluded.completed_at
            """
        ) { statement in
            try bind(metadata.id, at: 1, in: statement); try bind(metadata.fromAccountingVersion, at: 2, in: statement)
            try bind(metadata.toAccountingVersion, at: 3, in: statement); try bind(metadata.state.rawValue, at: 4, in: statement)
            try bind(metadata.startedAt?.timeIntervalSince1970, at: 5, in: statement)
            try bind(metadata.completedAt?.timeIntervalSince1970, at: 6, in: statement); try stepDone(statement)
        }
    }

    public func reindexMetadata(id: String) throws -> UsageReindexMetadata? {
        try withStatement("SELECT from_accounting_version, to_accounting_version, state, started_at, completed_at FROM usage_reindex WHERE id = ?") { statement in
            try bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let stateText = stringColumn(statement, 2), let state = UsageReindexState(rawValue: stateText) else { throw StoreError.statementFailed }
            return UsageReindexMetadata(id: id, fromAccountingVersion: Int(sqlite3_column_int64(statement, 0)), toAccountingVersion: Int(sqlite3_column_int64(statement, 1)), state: state, startedAt: dateColumn(statement, 3), completedAt: dateColumn(statement, 4))
        }
    }

    public func setActiveAccountingVersion(_ version: Int) throws {
        guard UsageIndexVersion(rawValue: version) != nil else { throw StoreError.invalidAccountingVersion }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try withStatement("UPDATE usage_accounting_metadata SET active_version = ? WHERE singleton = 1") { statement in
                try bind(version, at: 1, in: statement); try stepDone(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func rollbackReindex(id: String, at date: Date = Date()) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            guard let metadata = try reindexMetadata(id: id),
                  metadata.state == .completed,
                  try activeAccountingVersion() == metadata.toAccountingVersion else {
                throw StoreError.rollbackUnavailable
            }
            try withStatement(
                "UPDATE usage_accounting_metadata SET active_version = ? WHERE singleton = 1"
            ) { statement in
                try bind(metadata.fromAccountingVersion, at: 1, in: statement)
                try stepDone(statement)
            }
            try saveReindexMetadata(.init(
                id: metadata.id,
                fromAccountingVersion: metadata.fromAccountingVersion,
                toAccountingVersion: metadata.toAccountingVersion,
                state: .rolledBack,
                startedAt: metadata.startedAt,
                completedAt: date
            ))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func resetInactiveTranscriptIndex(accountingVersion: Int) throws {
        guard UsageIndexVersion(rawValue: accountingVersion) != nil else { throw StoreError.invalidAccountingVersion }
        guard accountingVersion != (try activeAccountingVersion()) else { throw StoreError.activeIndexReset }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM physical_usage_records; DELETE FROM transcript_checkpoints; DELETE FROM transcript_sources;")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func validateTranscriptIndex() throws -> TranscriptIndexValidation {
        let values = try withStatement(
            """
            SELECT
              (SELECT COUNT(*) FROM transcript_sources),
              (SELECT COUNT(*) FROM transcript_checkpoints),
              (SELECT COUNT(*) FROM physical_usage_records),
              (SELECT COUNT(*) FROM transcript_checkpoints c LEFT JOIN transcript_sources s ON s.source_id=c.source_id AND s.source_generation=c.source_generation WHERE s.source_id IS NULL),
              (SELECT COUNT(*) FROM physical_usage_records r LEFT JOIN transcript_sources s ON s.source_id=r.source_id AND s.source_generation=r.source_generation WHERE s.source_id IS NULL),
              (SELECT COUNT(*) FROM physical_usage_records WHERE uncached_input_tokens < 0 OR cached_input_tokens < 0 OR cache_creation_input_tokens < 0 OR output_tokens < 0 OR reasoning_output_tokens < 0 OR reasoning_output_tokens > output_tokens)
            """
        ) { statement -> [Int] in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.statementFailed }
            return (0..<6).map { Int(sqlite3_column_int64(statement, Int32($0))) }
        }
        return TranscriptIndexValidation(sourceCount: values[0], checkpointCount: values[1], physicalRecordCount: values[2], orphanCheckpointCount: values[3], orphanRecordCount: values[4], invalidTokenRecordCount: values[5])
    }

    public func tokenTotal(provider: Provider) throws -> Int {
        if try activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try transcriptTokenTotal(provider: provider)
        }

        return try withStatement(
            """
            SELECT COALESCE(SUM(
                input_tokens
                + output_tokens
                + cached_input_tokens
                + cache_creation_input_tokens
            ), 0)
            FROM token_samples
            WHERE provider = ?
            """
        ) { statement in
            try bind(provider.rawValue, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw StoreError.statementFailed
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func latestTokenObservedAt(provider: Provider) throws -> Date? {
        let sql: String
        if try activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            sql = """
                WITH ranked_records AS (
                  SELECT provider, observed_at, logical_dedupe_key,
                         ROW_NUMBER() OVER (
                           PARTITION BY provider, logical_dedupe_key
                           ORDER BY observed_at ASC, source_id ASC, source_generation ASC, byte_offset ASC
                         ) AS logical_rank
                  FROM physical_usage_records
                )
                SELECT MAX(observed_at)
                FROM ranked_records
                WHERE provider = ? AND (logical_dedupe_key IS NULL OR logical_rank = 1)
                """
        } else {
            sql = "SELECT MAX(observed_at) FROM token_samples WHERE provider = ?"
        }
        return try withStatement(sql) { statement in
            try bind(provider.rawValue, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.statementFailed }
            return dateColumn(statement, 0)
        }
    }

    public func tokenSamples(since startDate: Date? = nil, provider providerFilter: Provider? = nil) throws -> [TokenSample] {
        if try activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try transcriptTokenSamples(
                since: startDate,
                provider: providerFilter,
                ascending: false
            )
        }

        var clauses: [String] = []
        if startDate != nil {
            clauses.append("observed_at >= ?")
        }
        if providerFilter != nil {
            clauses.append("provider = ?")
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT provider, observed_at, COALESCE(model, ''),
                   input_tokens, output_tokens, cached_input_tokens,
                   cache_creation_input_tokens, reasoning_output_tokens,
                   input_tokens + output_tokens + cached_input_tokens
                     + cache_creation_input_tokens
            FROM token_samples
            \(whereClause)
            ORDER BY observed_at DESC
            """

        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let startDate {
                try bind(startDate.timeIntervalSince1970, at: index, in: statement)
                index += 1
            }
            if let providerFilter {
                try bind(providerFilter.rawValue, at: index, in: statement)
            }

            var samples: [TokenSample] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard
                        let providerText = sqlite3_column_text(statement, 0),
                        let provider = Provider(rawValue: String(cString: providerText)),
                        let modelText = sqlite3_column_text(statement, 2)
                    else {
                        throw StoreError.statementFailed
                    }

                    samples.append(
                        TokenSample(
                            provider: provider,
                            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                            model: String(cString: modelText),
                            inputTokens: Int(sqlite3_column_int64(statement, 3)),
                            outputTokens: Int(sqlite3_column_int64(statement, 4)),
                            cachedInputTokens: Int(sqlite3_column_int64(statement, 5)),
                            cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 6)),
                            reasoningOutputTokens: Int(sqlite3_column_int64(statement, 7)),
                            totalTokens: Int(sqlite3_column_int64(statement, 8))
                        )
                    )
                case SQLITE_DONE:
                    return samples
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    public func usageHistorySeries(
        range: UsageHistoryRange,
        endingAt endDate: Date = Date(),
        calendar: Calendar = .current,
        pricingCatalog: PricingCatalog = .bundled
    ) throws -> UsageHistorySeries {
        let startDate = range.startDate(endingAt: endDate, calendar: calendar)
        let bucketStarts = Self.bucketStarts(
            from: startDate,
            to: endDate,
            bucketSize: range.bucketSize,
            calendar: calendar
        )
        let emptyBuckets = Self.emptyBuckets(
            starts: bucketStarts,
            endingAt: endDate,
            bucketSize: range.bucketSize,
            calendar: calendar
        )
        let bucketIndexByStart = Dictionary(
            uniqueKeysWithValues: bucketStarts.enumerated().map { ($0.element, $0.offset) }
        )
        var bucketsByProvider = Dictionary(
            uniqueKeysWithValues: Provider.allCases.map { provider in
                (provider, emptyBuckets)
            }
        )

        for sample in try tokenSamples(from: startDate, to: endDate) {
            let bucketStart = Self.bucketStart(
                for: sample.observedAt,
                bucketSize: range.bucketSize,
                calendar: calendar
            )
            guard let bucketIndex = bucketIndexByStart[bucketStart] else {
                continue
            }

            let bucket = bucketsByProvider[sample.provider]?[bucketIndex]
                ?? emptyBuckets[bucketIndex]
            var estimatedCost = bucket.estimatedCost
            var estimatedCostProvenance = bucket.estimatedCostProvenance
            var unknownPricingSampleCount = bucket.unknownPricingSampleCount
            let estimate = pricingCatalog.costEstimate(for: sample)
            if let amount = estimate.amountUSD {
                if estimatedCostProvenance == .unpriced || estimatedCostProvenance == estimate.provenance {
                    estimatedCost += amount
                    estimatedCostProvenance = estimate.provenance
                } else {
                    // Provider-reported and catalogue-priced values are not
                    // additive. Keep one labelled subtotal and report the
                    // excluded sample through the existing coverage count.
                    unknownPricingSampleCount += 1
                }
            } else {
                unknownPricingSampleCount += 1
            }

            bucketsByProvider[sample.provider]?[bucketIndex] = UsageHistoryBucket(
                start: bucket.start,
                end: bucket.end,
                tokens: bucket.tokens.adding(sample),
                estimatedCost: estimatedCost,
                estimatedCostProvenance: estimatedCostProvenance,
                unknownPricingSampleCount: unknownPricingSampleCount
            )
        }

        let quotaByProvider = Dictionary(grouping: try quotaHistoryPoints(from: startDate, to: endDate)) {
            $0.provider
        }

        let providers = Provider.allCases.map { provider in
            ProviderUsageHistory(
                provider: provider,
                buckets: bucketsByProvider[provider] ?? emptyBuckets,
                quotaPercentSeries: (quotaByProvider[provider] ?? []).map(\.point)
            )
        }

        return UsageHistorySeries(
            range: range,
            bucketSize: range.bucketSize,
            start: startDate,
            end: endDate,
            providers: providers
        )
    }

    public func dailyActivityGrid(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current,
        pricingCatalog: PricingCatalog = .bundled
    ) throws -> DailyActivityGrid {
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard startDay <= endDay else {
            return DailyActivityGrid(days: [], minTotalTokens: 0, maxTotalTokens: 0)
        }
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            throw StoreError.statementFailed
        }

        var totalsByDay: [Date: [Provider: Int]] = [:]
        var costsByDay: [Date: [Provider: Decimal]] = [:]
        for sample in try tokenSamples(from: startDay, to: exclusiveEnd) {
            let dayStart = calendar.startOfDay(for: sample.observedAt)
            totalsByDay[dayStart, default: [:]][sample.provider, default: 0] += sample.totalTokens
            if let amount = pricingCatalog.costEstimate(for: sample).amountUSD {
                costsByDay[dayStart, default: [:]][sample.provider, default: 0] += amount
            }
        }

        var days: [DailyActivityGridDay] = []
        var cursor = startDay
        while cursor <= endDay {
            let providerTotals = Provider.allCases.map { provider in
                DailyProviderTokenTotal(
                    provider: provider,
                    totalTokens: totalsByDay[cursor]?[provider] ?? 0,
                    estimatedCost: costsByDay[cursor]?[provider] ?? 0
                )
            }
            days.append(DailyActivityGridDay(dayStart: cursor, providerTotals: providerTotals))

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                throw StoreError.statementFailed
            }
            cursor = nextDay
        }

        let dayTotals = days.map(\.totalTokens)
        return DailyActivityGrid(
            days: days,
            minTotalTokens: dayTotals.min() ?? 0,
            maxTotalTokens: dayTotals.max() ?? 0
        )
    }

    public func latestQuota(provider: Provider, at date: Date = Date()) throws -> [QuotaSnapshot] {
        try withStatement(
            """
            SELECT quota.window, quota.source, quota.used_percent, quota.resets_at, quota.observed_at
            FROM quota_snapshots AS quota
            WHERE quota.provider = ?
              AND quota.id = (
                SELECT latest.id
                FROM quota_snapshots AS latest
                WHERE latest.provider = quota.provider
                  AND latest.window = quota.window
                ORDER BY CASE
                  WHEN latest.provider = 'claude'
                    AND latest.source = 'local'
                    AND latest.resets_at > ?
                    AND latest.observed_at >= ?
                    AND latest.observed_at <= ? THEN 0
                  WHEN latest.source = 'account' AND latest.resets_at > ? THEN 1
                  WHEN latest.source = 'local' THEN 2
                  ELSE 3
                END, latest.observed_at DESC, latest.rowid DESC
                LIMIT 1
              )
            ORDER BY CASE quota.window
              WHEN 'session' THEN 0
              WHEN 'weekly' THEN 1
              ELSE 2
            END
            """
        ) { statement in
            try bind(provider.rawValue, at: 1, in: statement)
            try bind(date.timeIntervalSince1970, at: 2, in: statement)
            try bind(date.addingTimeInterval(-600).timeIntervalSince1970, at: 3, in: statement)
            try bind(date.timeIntervalSince1970, at: 4, in: statement)
            try bind(date.timeIntervalSince1970, at: 5, in: statement)
            var snapshots: [QuotaSnapshot] = []

            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard
                        let windowText = sqlite3_column_text(statement, 0),
                        let window = QuotaWindow(rawValue: String(cString: windowText)),
                        let sourceText = sqlite3_column_text(statement, 1)
                    else {
                        throw StoreError.statementFailed
                    }
                    snapshots.append(
                        QuotaSnapshot(
                            provider: provider,
                            window: window,
                            source: QuotaSource(rawValue: String(cString: sourceText)) ?? .local,
                            usedPercent: sqlite3_column_double(statement, 2),
                            resetsAt: Date(
                                timeIntervalSince1970: sqlite3_column_double(statement, 3)
                            ),
                            observedAt: Date(
                                timeIntervalSince1970: sqlite3_column_double(statement, 4)
                            )
                        )
                    )
                case SQLITE_DONE:
                    return snapshots
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    public func save(cloudUsage summaries: [CloudUsageSummary]) throws {
        try withStatement(
            """
            INSERT OR REPLACE INTO cloud_usage_summaries (
              id, provider, source, data_kind, observed_at, range_start, range_end,
              input_tokens, output_tokens, cached_input_tokens,
              cache_creation_input_tokens, request_count, session_count,
              cost_amount, cost_currency
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            for summary in summaries {
                try bind(Self.stableID(for: summary), at: 1, in: statement)
                try bind(summary.provider.rawValue, at: 2, in: statement)
                try bind(summary.source.rawValue, at: 3, in: statement)
                try bind(summary.dataKind.rawValue, at: 4, in: statement)
                try bind(summary.observedAt.timeIntervalSince1970, at: 5, in: statement)
                try bind(summary.rangeStart.timeIntervalSince1970, at: 6, in: statement)
                try bind(summary.rangeEnd.timeIntervalSince1970, at: 7, in: statement)
                try bind(summary.inputTokens, at: 8, in: statement)
                try bind(summary.outputTokens, at: 9, in: statement)
                try bind(summary.cachedInputTokens, at: 10, in: statement)
                try bind(summary.cacheCreationInputTokens, at: 11, in: statement)
                try bind(summary.requestCount, at: 12, in: statement)
                try bind(summary.sessionCount, at: 13, in: statement)
                try bind(summary.costAmount, at: 14, in: statement)
                try bind(summary.costCurrency, at: 15, in: statement)
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    public func cloudUsageSummaries(
        since startDate: Date? = nil,
        provider providerFilter: Provider? = nil
    ) throws -> [CloudUsageSummary] {
        var clauses: [String] = []
        if startDate != nil {
            clauses.append("range_end >= ?")
        }
        if providerFilter != nil {
            clauses.append("provider = ?")
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT provider, source, data_kind, observed_at, range_start, range_end,
                   input_tokens, output_tokens, cached_input_tokens,
                   cache_creation_input_tokens, request_count, session_count,
                   cost_amount, cost_currency
            FROM cloud_usage_summaries
            \(whereClause)
            ORDER BY range_start DESC, observed_at DESC
            """

        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let startDate {
                try bind(startDate.timeIntervalSince1970, at: index, in: statement)
                index += 1
            }
            if let providerFilter {
                try bind(providerFilter.rawValue, at: index, in: statement)
            }

            var summaries: [CloudUsageSummary] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard
                        let providerText = sqlite3_column_text(statement, 0),
                        let provider = Provider(rawValue: String(cString: providerText)),
                        let sourceText = sqlite3_column_text(statement, 1),
                        let source = CloudUsageSource(rawValue: String(cString: sourceText)),
                        let dataKindText = sqlite3_column_text(statement, 2),
                        let dataKind = CloudUsageDataKind(rawValue: String(cString: dataKindText))
                    else {
                        throw StoreError.statementFailed
                    }

                    summaries.append(
                        CloudUsageSummary(
                            provider: provider,
                            source: source,
                            dataKind: dataKind,
                            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                            rangeStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                            rangeEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                            inputTokens: Int(sqlite3_column_int64(statement, 6)),
                            outputTokens: Int(sqlite3_column_int64(statement, 7)),
                            cachedInputTokens: Int(sqlite3_column_int64(statement, 8)),
                            cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 9)),
                            requestCount: Int(sqlite3_column_int64(statement, 10)),
                            sessionCount: Int(sqlite3_column_int64(statement, 11)),
                            costAmount: sqlite3_column_type(statement, 12) == SQLITE_NULL
                                ? nil
                                : sqlite3_column_double(statement, 12),
                            costCurrency: stringColumn(statement, 13)
                        )
                    )
                case SQLITE_DONE:
                    return summaries
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try withStatement("PRAGMA user_version") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw StoreError.statementFailed
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    public func tableNames() throws -> [String] {
        try strings(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
            ORDER BY name
            """
        )
    }

    // Returns only schema and persisted text values so privacy tests can inspect storage.
    func databaseText() throws -> Data {
        let lines = try strings(
            """
            SELECT sql FROM sqlite_master WHERE sql IS NOT NULL
            UNION ALL
            SELECT 'token:' || id || ':' || provider || ':' || COALESCE(model, '')
                FROM token_samples
            UNION ALL
            SELECT 'quota:' || provider || ':' || id || ':' || window
                FROM quota_snapshots
            UNION ALL
            SELECT 'quota_history:' || provider || ':' || id || ':' || window
                FROM quota_snapshot_history
            UNION ALL
            SELECT 'cursor:' || source_id FROM import_cursors
            UNION ALL
            SELECT 'cloud:' || id || ':' || provider || ':' || source || ':' || data_kind
                FROM cloud_usage_summaries
            UNION ALL
            SELECT 'transcript_source:' || source_id || ':' || source_fingerprint || ':' || source_generation
                FROM transcript_sources
            UNION ALL
            SELECT 'transcript_checkpoint:' || source_id || ':' || source_generation
                FROM transcript_checkpoints
            UNION ALL
            SELECT 'physical_record:' || source_id || ':' || source_generation || ':' || COALESCE(logical_dedupe_key, '')
                FROM physical_usage_records
            """
        )
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func migrate(_ database: OpaquePointer) throws {
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { throw StoreError.migrationFailed }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else {
            sqlite3_finalize(versionStatement)
            throw StoreError.migrationFailed
        }
        let priorVersion = Int(sqlite3_column_int(versionStatement, 0))
        sqlite3_finalize(versionStatement)

        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.migrationFailed
        }
        var committed = false
        defer {
            if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        }
        guard sqlite3_exec(
            database,
            """
            CREATE TABLE IF NOT EXISTS token_samples (
              id TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              observed_at REAL NOT NULL,
              model TEXT,
              input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              cache_creation_input_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS quota_snapshots (
              id TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              window TEXT NOT NULL,
              source TEXT NOT NULL DEFAULT 'local',
              used_percent REAL NOT NULL,
              resets_at REAL,
              observed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS quota_snapshot_history (
              id TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              window TEXT NOT NULL,
              source TEXT NOT NULL DEFAULT 'local',
              used_percent REAL NOT NULL,
              resets_at REAL,
              observed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS import_cursors (
              source_id TEXT PRIMARY KEY,
              byte_offset INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cloud_usage_summaries (
              id TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              source TEXT NOT NULL,
              data_kind TEXT NOT NULL,
              observed_at REAL NOT NULL,
              range_start REAL NOT NULL,
              range_end REAL NOT NULL,
              input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              cache_creation_input_tokens INTEGER NOT NULL,
              request_count INTEGER NOT NULL,
              session_count INTEGER NOT NULL,
              cost_amount REAL,
              cost_currency TEXT
            );
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw StoreError.migrationFailed
        }

        let alterStatus = sqlite3_exec(
            database,
            "ALTER TABLE quota_snapshots ADD COLUMN source TEXT NOT NULL DEFAULT 'local';",
            nil,
            nil,
            nil
        )
        if alterStatus != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(database))
            guard message.contains("duplicate column name") else {
                throw StoreError.migrationFailed
            }
        }

        guard sqlite3_exec(
            database,
            """
            DELETE FROM quota_snapshots
            WHERE rowid NOT IN (
              SELECT MAX(rowid)
              FROM quota_snapshots
              GROUP BY provider, window, source
            );
            CREATE UNIQUE INDEX IF NOT EXISTS quota_snapshots_current_source_window
              ON quota_snapshots (provider, window, source);
            CREATE INDEX IF NOT EXISTS token_samples_history_lookup
              ON token_samples (observed_at, provider);
            CREATE INDEX IF NOT EXISTS quota_snapshots_history_lookup
              ON quota_snapshots (observed_at, provider);
            CREATE INDEX IF NOT EXISTS quota_snapshot_history_lookup
              ON quota_snapshot_history (provider, window, observed_at);
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw StoreError.migrationFailed
        }

        let v2Status = sqlite3_exec(
            database,
            """
            CREATE TABLE IF NOT EXISTS transcript_sources (
              source_id TEXT NOT NULL,
              source_fingerprint TEXT NOT NULL,
              provider TEXT NOT NULL,
              source_generation TEXT NOT NULL,
              parser_version INTEGER NOT NULL,
              PRIMARY KEY (source_id, source_generation)
            );
            CREATE TABLE IF NOT EXISTS transcript_checkpoints (
              source_id TEXT NOT NULL,
              source_generation TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              parser_state BLOB NOT NULL,
              parser_state_version INTEGER NOT NULL,
              PRIMARY KEY (source_id, source_generation),
              FOREIGN KEY (source_id, source_generation)
                REFERENCES transcript_sources (source_id, source_generation) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS physical_usage_records (
              source_id TEXT NOT NULL,
              source_generation TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              provider TEXT NOT NULL,
              observed_at REAL NOT NULL,
              model TEXT NOT NULL,
              uncached_input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              cache_creation_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              logical_dedupe_key TEXT NOT NULL,
              provider_reported_total_tokens INTEGER,
              reported_cost_usd TEXT,
              parser_version INTEGER NOT NULL,
              PRIMARY KEY (source_id, source_generation, byte_offset),
              FOREIGN KEY (source_id, source_generation)
                REFERENCES transcript_sources (source_id, source_generation) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS physical_usage_records_global_dedupe
              ON physical_usage_records (provider, logical_dedupe_key, observed_at);
            CREATE TABLE IF NOT EXISTS usage_reindex (
              id TEXT PRIMARY KEY,
              from_accounting_version INTEGER NOT NULL,
              to_accounting_version INTEGER NOT NULL,
              state TEXT NOT NULL,
              started_at REAL,
              completed_at REAL
            );
            CREATE TABLE IF NOT EXISTS usage_accounting_metadata (
              singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
              active_version INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO usage_accounting_metadata (singleton, active_version) VALUES (1, 1);
            """,
            nil, nil, nil
        )
        guard v2Status == SQLITE_OK else { throw StoreError.migrationFailed }

        if priorVersion == 6 {
            // v6 could persist raw session and provider event identifiers. The
            // v2 tables are a rebuildable shadow, so discard them and return to
            // legacy until the privacy-safe index is rebuilt and validated.
            guard sqlite3_exec(
                database,
                """
                DELETE FROM transcript_checkpoints;
                DELETE FROM transcript_sources;
                DROP TABLE physical_usage_records;
                CREATE TABLE physical_usage_records (
                  source_id TEXT NOT NULL,
                  source_generation TEXT NOT NULL,
                  byte_offset INTEGER NOT NULL,
                  provider TEXT NOT NULL,
                  observed_at REAL NOT NULL,
                  model TEXT NOT NULL,
                  uncached_input_tokens INTEGER NOT NULL,
                  cached_input_tokens INTEGER NOT NULL,
                  cache_creation_input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  reasoning_output_tokens INTEGER NOT NULL,
                  logical_dedupe_key TEXT NOT NULL,
                  provider_reported_total_tokens INTEGER,
                  reported_cost_usd TEXT,
                  parser_version INTEGER NOT NULL,
                  PRIMARY KEY (source_id, source_generation, byte_offset),
                  FOREIGN KEY (source_id, source_generation)
                    REFERENCES transcript_sources (source_id, source_generation) ON DELETE CASCADE
                );
                CREATE INDEX physical_usage_records_global_dedupe
                  ON physical_usage_records (provider, logical_dedupe_key, observed_at);
                UPDATE usage_accounting_metadata SET active_version = 1 WHERE singleton = 1;
                """,
                nil, nil, nil
            ) == SQLITE_OK else { throw StoreError.migrationFailed }
        }

        guard sqlite3_exec(database, "PRAGMA user_version = 7", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.migrationFailed
        }
        committed = true
    }

    private func deleteTranscriptGenerations(sourceID: String, except generation: String) throws {
        for table in ["physical_usage_records", "transcript_checkpoints", "transcript_sources"] {
            try withStatement("DELETE FROM \(table) WHERE source_id = ? AND source_generation <> ?") { statement in
                try bind(sourceID, at: 1, in: statement); try bind(generation, at: 2, in: statement); try stepDone(statement)
            }
        }
    }

    private func deleteTranscriptSource(sourceID: String) throws {
        for table in ["physical_usage_records", "transcript_checkpoints", "transcript_sources"] {
            try withStatement("DELETE FROM \(table) WHERE source_id = ?") { statement in
                try bind(sourceID, at: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    private func upsert(source: TranscriptSourceMetadata) throws {
        try withStatement(
            """
            INSERT INTO transcript_sources (source_id, source_fingerprint, provider, source_generation, parser_version)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id, source_generation) DO UPDATE SET
              source_fingerprint = excluded.source_fingerprint,
              provider = excluded.provider,
              parser_version = excluded.parser_version
            """
        ) { statement in
            try bind(source.sourceID, at: 1, in: statement); try bind(source.sourceFingerprint, at: 2, in: statement)
            try bind(source.provider.rawValue, at: 3, in: statement); try bind(source.generation, at: 4, in: statement)
            try bind(source.parserVersion, at: 5, in: statement); try stepDone(statement)
        }
    }

    private func insertPhysicalRecords(_ records: [TranscriptUsageRecord], parserVersion: Int) throws {
        try withStatement(
            """
            INSERT OR REPLACE INTO physical_usage_records (
              source_id, source_generation, byte_offset, provider, observed_at, model,
              uncached_input_tokens, cached_input_tokens, cache_creation_input_tokens, output_tokens,
              reasoning_output_tokens, logical_dedupe_key, provider_reported_total_tokens,
              reported_cost_usd, parser_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            for record in records {
                try bind(record.physicalIdentity.sourceID, at: 1, in: statement); try bind(record.physicalIdentity.sourceGeneration, at: 2, in: statement)
                try bind(record.physicalIdentity.byteOffset, at: 3, in: statement); try bind(record.provider.rawValue, at: 4, in: statement)
                try bind(record.timestamp.timeIntervalSince1970, at: 5, in: statement); try bind(record.model, at: 6, in: statement)
                try bind(record.uncachedInputTokens, at: 7, in: statement)
                try bind(record.cachedInputTokens, at: 8, in: statement); try bind(record.cacheCreationInputTokens, at: 9, in: statement)
                try bind(record.outputTokens, at: 10, in: statement); try bind(record.reasoningOutputTokens, at: 11, in: statement)
                try bind(record.logicalDedupeKey, at: 12, in: statement); try bind(record.providerReportedTotalTokens, at: 13, in: statement)
                try bind(record.reportedCostUSD.map(String.init(describing:)), at: 14, in: statement); try bind(parserVersion, at: 15, in: statement)
                try stepDone(statement); sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
        }
    }

    private func upsert(checkpoint: TranscriptCheckpoint) throws {
        try withStatement(
            """
            INSERT INTO transcript_checkpoints (source_id, source_generation, byte_offset, parser_state, parser_state_version)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id, source_generation) DO UPDATE SET
              byte_offset = excluded.byte_offset, parser_state = excluded.parser_state,
              parser_state_version = excluded.parser_state_version
            """
        ) { statement in
            try bind(checkpoint.sourceID, at: 1, in: statement); try bind(checkpoint.sourceGeneration, at: 2, in: statement)
            try bind(checkpoint.byteOffset, at: 3, in: statement); try bind(checkpoint.parserState, at: 4, in: statement)
            try bind(checkpoint.parserStateVersion, at: 5, in: statement); try stepDone(statement)
        }
    }

    private func save(tokens: [TokenSample]) throws {
        try withStatement(
            """
            INSERT OR IGNORE INTO token_samples (
              id, provider, observed_at, model, input_tokens, output_tokens,
              cached_input_tokens, cache_creation_input_tokens, reasoning_output_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            for sample in tokens {
                try bind(Self.stableID(for: sample), at: 1, in: statement)
                try bind(sample.provider.rawValue, at: 2, in: statement)
                try bind(sample.observedAt.timeIntervalSince1970, at: 3, in: statement)
                try bind(sample.model, at: 4, in: statement)
                try bind(sample.inputTokens, at: 5, in: statement)
                try bind(sample.outputTokens, at: 6, in: statement)
                try bind(sample.cachedInputTokens, at: 7, in: statement)
                try bind(sample.cacheCreationInputTokens, at: 8, in: statement)
                try bind(sample.reasoningOutputTokens, at: 9, in: statement)
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    private func save(quota: [QuotaSnapshot]) throws {
        guard !quota.isEmpty else {
            return
        }

        try appendQuotaHistory(quota)
        try pruneQuotaHistory(relativeTo: quota.map(\.observedAt).max() ?? Date())

        try withStatement(
            """
            INSERT INTO quota_snapshots (
              id, provider, window, source, used_percent, resets_at, observed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, window, source) DO UPDATE SET
              id = excluded.id,
              used_percent = excluded.used_percent,
              resets_at = excluded.resets_at,
              observed_at = excluded.observed_at
            """
        ) { statement in
            for snapshot in quota {
                try bind(Self.stableID(for: snapshot), at: 1, in: statement)
                try bind(snapshot.provider.rawValue, at: 2, in: statement)
                try bind(snapshot.window.rawValue, at: 3, in: statement)
                try bind(snapshot.source.rawValue, at: 4, in: statement)
                try bind(snapshot.usedPercent, at: 5, in: statement)
                try bind(snapshot.resetsAt.timeIntervalSince1970, at: 6, in: statement)
                try bind(snapshot.observedAt.timeIntervalSince1970, at: 7, in: statement)
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    private func appendQuotaHistory(_ quota: [QuotaSnapshot]) throws {
        try withStatement(
            """
            INSERT OR IGNORE INTO quota_snapshot_history (
              id, provider, window, source, used_percent, resets_at, observed_at
            )
            SELECT ?, ?, ?, ?, ?, ?, ?
            WHERE COALESCE((
              SELECT latest.used_percent = ? AND latest.resets_at = ?
              FROM quota_snapshot_history AS latest
              WHERE latest.provider = ?
                AND latest.window = ?
                AND latest.source = ?
              ORDER BY latest.observed_at DESC, latest.rowid DESC
              LIMIT 1
            ), 0) = 0
            """
        ) { statement in
            for snapshot in quota {
                try bind(Self.stableID(for: snapshot), at: 1, in: statement)
                try bind(snapshot.provider.rawValue, at: 2, in: statement)
                try bind(snapshot.window.rawValue, at: 3, in: statement)
                try bind(snapshot.source.rawValue, at: 4, in: statement)
                try bind(snapshot.usedPercent, at: 5, in: statement)
                try bind(snapshot.resetsAt.timeIntervalSince1970, at: 6, in: statement)
                try bind(snapshot.observedAt.timeIntervalSince1970, at: 7, in: statement)
                try bind(snapshot.usedPercent, at: 8, in: statement)
                try bind(snapshot.resetsAt.timeIntervalSince1970, at: 9, in: statement)
                try bind(snapshot.provider.rawValue, at: 10, in: statement)
                try bind(snapshot.window.rawValue, at: 11, in: statement)
                try bind(snapshot.source.rawValue, at: 12, in: statement)
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    private func pruneQuotaHistory(relativeTo observedAt: Date) throws {
        try withStatement(
            """
            DELETE FROM quota_snapshot_history
            WHERE observed_at < ?
            """
        ) { statement in
            try bind(observedAt.addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    private func tokenSamples(from startDate: Date, to endDate: Date) throws -> [TokenSample] {
        if try activeAccountingVersion() == UsageIndexVersion.transcriptAccountingV2.rawValue {
            return try transcriptTokenSamples(
                since: startDate,
                until: endDate,
                ascending: true
            )
        }

        return try withStatement(
            """
            SELECT provider, observed_at, COALESCE(model, ''),
                   input_tokens, output_tokens, cached_input_tokens,
                   cache_creation_input_tokens, reasoning_output_tokens,
                   input_tokens + output_tokens + cached_input_tokens
                     + cache_creation_input_tokens
            FROM token_samples
            WHERE observed_at >= ? AND observed_at < ?
            ORDER BY observed_at ASC, provider ASC
            """
        ) { statement in
            try bind(startDate.timeIntervalSince1970, at: 1, in: statement)
            try bind(endDate.timeIntervalSince1970, at: 2, in: statement)

            var samples: [TokenSample] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard
                        let providerText = sqlite3_column_text(statement, 0),
                        let provider = Provider(rawValue: String(cString: providerText)),
                        let modelText = sqlite3_column_text(statement, 2)
                    else {
                        throw StoreError.statementFailed
                    }

                    samples.append(
                        TokenSample(
                            provider: provider,
                            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                            model: String(cString: modelText),
                            inputTokens: Int(sqlite3_column_int64(statement, 3)),
                            outputTokens: Int(sqlite3_column_int64(statement, 4)),
                            cachedInputTokens: Int(sqlite3_column_int64(statement, 5)),
                            cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 6)),
                            reasoningOutputTokens: Int(sqlite3_column_int64(statement, 7)),
                            totalTokens: Int(sqlite3_column_int64(statement, 8))
                        )
                    )
                case SQLITE_DONE:
                    return samples
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    private func transcriptTokenTotal(provider: Provider) throws -> Int {
        try withStatement(
            """
            WITH ranked_records AS (
              SELECT provider, logical_dedupe_key, uncached_input_tokens,
                     cached_input_tokens, cache_creation_input_tokens, output_tokens,
                     ROW_NUMBER() OVER (
                       PARTITION BY provider, logical_dedupe_key
                       ORDER BY observed_at ASC, source_id ASC, source_generation ASC, byte_offset ASC
                     ) AS logical_rank
              FROM physical_usage_records
            )
            SELECT COALESCE(SUM(
              uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens + output_tokens
            ), 0)
            FROM ranked_records
            WHERE provider = ? AND (logical_dedupe_key IS NULL OR logical_rank = 1)
            """
        ) { statement in
            try bind(provider.rawValue, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.statementFailed }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func transcriptTokenSamples(
        since startDate: Date? = nil,
        until endDate: Date? = nil,
        provider providerFilter: Provider? = nil,
        ascending: Bool
    ) throws -> [TokenSample] {
        var clauses = ["(logical_dedupe_key IS NULL OR logical_rank = 1)"]
        if startDate != nil { clauses.append("observed_at >= ?") }
        if endDate != nil { clauses.append("observed_at < ?") }
        if providerFilter != nil { clauses.append("provider = ?") }
        let direction = ascending ? "ASC" : "DESC"
        let sql = """
            WITH ranked_records AS (
              SELECT provider, observed_at, model,
                     uncached_input_tokens, output_tokens, cached_input_tokens,
                     cache_creation_input_tokens, reasoning_output_tokens, reported_cost_usd, logical_dedupe_key,
                     ROW_NUMBER() OVER (
                       PARTITION BY provider, logical_dedupe_key
                       ORDER BY observed_at ASC, source_id ASC, source_generation ASC, byte_offset ASC
                     ) AS logical_rank
              FROM physical_usage_records
            )
            SELECT provider, observed_at, model,
                   uncached_input_tokens, output_tokens, cached_input_tokens,
                   cache_creation_input_tokens, reasoning_output_tokens,
                   uncached_input_tokens + output_tokens + cached_input_tokens
                     + cache_creation_input_tokens,
                   reported_cost_usd
            FROM ranked_records
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY observed_at \(direction), provider ASC
            """

        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let startDate {
                try bind(startDate.timeIntervalSince1970, at: index, in: statement)
                index += 1
            }
            if let endDate {
                try bind(endDate.timeIntervalSince1970, at: index, in: statement)
                index += 1
            }
            if let providerFilter {
                try bind(providerFilter.rawValue, at: index, in: statement)
            }

            var samples: [TokenSample] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let providerText = stringColumn(statement, 0),
                          let provider = Provider(rawValue: providerText),
                          let model = stringColumn(statement, 2) else {
                        throw StoreError.statementFailed
                    }
                    samples.append(TokenSample(
                        provider: provider,
                        observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        model: model,
                        inputTokens: Int(sqlite3_column_int64(statement, 3)),
                        outputTokens: Int(sqlite3_column_int64(statement, 4)),
                        cachedInputTokens: Int(sqlite3_column_int64(statement, 5)),
                        cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 6)),
                        reasoningOutputTokens: Int(sqlite3_column_int64(statement, 7)),
                        totalTokens: Int(sqlite3_column_int64(statement, 8)),
                        reportedCostUSD: stringColumn(statement, 9).map {
                            NSDecimalNumber(string: $0).decimalValue
                        }
                    ))
                case SQLITE_DONE:
                    return samples
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    public func quotaHistory(
        provider: Provider,
        window: QuotaWindow,
        from startDate: Date,
        to endDate: Date
    ) throws -> [QuotaSnapshot] {
        try withStatement(
            """
            SELECT source, used_percent, resets_at, observed_at
            FROM quota_snapshot_history
            WHERE provider = ?
              AND window = ?
              AND observed_at >= ?
              AND observed_at < ?
            ORDER BY observed_at ASC, source ASC, rowid ASC
            """
        ) { statement in
            try bind(provider.rawValue, at: 1, in: statement)
            try bind(window.rawValue, at: 2, in: statement)
            try bind(startDate.timeIntervalSince1970, at: 3, in: statement)
            try bind(endDate.timeIntervalSince1970, at: 4, in: statement)

            var snapshots: [QuotaSnapshot] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let sourceText = sqlite3_column_text(statement, 0) else {
                        throw StoreError.statementFailed
                    }
                    snapshots.append(
                        QuotaSnapshot(
                            provider: provider,
                            window: window,
                            source: QuotaSource(rawValue: String(cString: sourceText)) ?? .local,
                            usedPercent: sqlite3_column_double(statement, 1),
                            resetsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                        )
                    )
                case SQLITE_DONE:
                    return snapshots
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    private func quotaHistoryPoints(
        from startDate: Date,
        to endDate: Date
    ) throws -> [(provider: Provider, point: QuotaHistoryPoint)] {
        try withStatement(
            """
            SELECT provider, window, source, used_percent, resets_at, observed_at
            FROM quota_snapshot_history
            WHERE observed_at >= ? AND observed_at < ?
            ORDER BY provider ASC, window ASC, source ASC, observed_at ASC
            """
        ) { statement in
            try bind(startDate.timeIntervalSince1970, at: 1, in: statement)
            try bind(endDate.timeIntervalSince1970, at: 2, in: statement)

            var points: [(provider: Provider, point: QuotaHistoryPoint)] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard
                        let providerText = sqlite3_column_text(statement, 0),
                        let provider = Provider(rawValue: String(cString: providerText)),
                        let windowText = sqlite3_column_text(statement, 1),
                        let window = QuotaWindow(rawValue: String(cString: windowText)),
                        let sourceText = sqlite3_column_text(statement, 2)
                    else {
                        throw StoreError.statementFailed
                    }
                    points.append(
                        (
                            provider,
                            QuotaHistoryPoint(
                                window: window,
                                source: QuotaSource(rawValue: String(cString: sourceText)) ?? .local,
                                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                                usedPercent: sqlite3_column_double(statement, 3),
                                resetsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                            )
                        )
                    )
                case SQLITE_DONE:
                    return points
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    private static func bucketStarts(
        from startDate: Date,
        to endDate: Date,
        bucketSize: UsageHistoryBucketSize,
        calendar: Calendar
    ) -> [Date] {
        var starts: [Date] = []
        var current = bucketStart(for: startDate, bucketSize: bucketSize, calendar: calendar)
        while current < endDate {
            starts.append(current)
            guard let next = bucketEnd(after: current, bucketSize: bucketSize, calendar: calendar),
                  next > current else {
                break
            }
            current = next
        }
        return starts
    }

    private static func emptyBuckets(
        starts: [Date],
        endingAt endDate: Date,
        bucketSize: UsageHistoryBucketSize,
        calendar: Calendar
    ) -> [UsageHistoryBucket] {
        starts.map { start in
            UsageHistoryBucket(
                start: start,
                end: min(bucketEnd(after: start, bucketSize: bucketSize, calendar: calendar) ?? endDate, endDate)
            )
        }
    }

    private static func bucketStart(
        for date: Date,
        bucketSize: UsageHistoryBucketSize,
        calendar: Calendar
    ) -> Date {
        switch bucketSize {
        case .fifteenMinutes:
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let minute = ((components.minute ?? 0) / 15) * 15
            var floored = DateComponents()
            floored.calendar = calendar
            floored.timeZone = calendar.timeZone
            floored.year = components.year
            floored.month = components.month
            floored.day = components.day
            floored.hour = components.hour
            floored.minute = minute
            floored.second = 0
            return floored.date ?? date
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }

    private static func bucketEnd(
        after startDate: Date,
        bucketSize: UsageHistoryBucketSize,
        calendar: Calendar
    ) -> Date? {
        switch bucketSize {
        case .fifteenMinutes:
            calendar.date(byAdding: .minute, value: 15, to: startDate)
        case .hour:
            calendar.date(byAdding: .hour, value: 1, to: startDate)
        case .day:
            calendar.date(byAdding: .day, value: 1, to: startDate)
        }
    }

    private func compareAndSetCursor(
        sourceID: String,
        from expectedOffset: Int,
        to byteOffset: Int
    ) throws -> Bool {
        let updated = try withStatement(
            """
            UPDATE import_cursors
            SET byte_offset = ?
            WHERE source_id = ? AND byte_offset = ?
            """
        ) { statement in
            try bind(byteOffset, at: 1, in: statement)
            try bind(sourceID, at: 2, in: statement)
            try bind(expectedOffset, at: 3, in: statement)
            try stepDone(statement)
            return sqlite3_changes(database) == 1
        }

        guard !updated, expectedOffset == 0 else {
            return updated
        }

        return try withStatement(
            """
            INSERT OR IGNORE INTO import_cursors (source_id, byte_offset)
            VALUES (?, ?)
            """
        ) { statement in
            try bind(sourceID, at: 1, in: statement)
            try bind(byteOffset, at: 2, in: statement)
            try stepDone(statement)
            return sqlite3_changes(database) == 1
        }
    }

    private static func stableID(for sample: TokenSample) -> String {
        stableID(
            fields: [
                sample.provider.rawValue,
                String(sample.observedAt.timeIntervalSince1970.bitPattern),
                sample.model,
                String(sample.inputTokens),
                String(sample.outputTokens),
                String(sample.cachedInputTokens),
                String(sample.cacheCreationInputTokens),
                String(sample.reasoningOutputTokens)
            ]
        )
    }

    private static func stableID(for snapshot: QuotaSnapshot) -> String {
        stableID(
            fields: [
                snapshot.provider.rawValue,
                snapshot.window.rawValue,
                snapshot.source.rawValue,
                String(snapshot.usedPercent.bitPattern),
                String(snapshot.resetsAt.timeIntervalSince1970.bitPattern),
                String(snapshot.observedAt.timeIntervalSince1970.bitPattern)
            ]
        )
    }

    private static func stableID(for summary: CloudUsageSummary) -> String {
        stableID(
            fields: [
                summary.provider.rawValue,
                summary.source.rawValue,
                summary.dataKind.rawValue,
                String(summary.rangeStart.timeIntervalSince1970.bitPattern),
                String(summary.rangeEnd.timeIntervalSince1970.bitPattern)
            ]
        )
    }

    private static func stableID(fields: [String]) -> String {
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.statementFailed
        }
    }

    private func strings(_ sql: String) throws -> [String] {
        try withStatement(sql) { statement in
            var values: [String] = []

            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let value = sqlite3_column_text(statement, 0) else {
                        continue
                    }
                    values.append(String(cString: value))
                case SQLITE_DONE:
                    return values
                default:
                    throw StoreError.statementFailed
                }
            }
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.statementFailed
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed
        }
    }

    private func bind(_ value: Int, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw StoreError.statementFailed
        }
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw StoreError.statementFailed }
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else { try bindNull(at: index, in: statement); return }
        try bind(value, at: index, in: statement)
    }

    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw StoreError.statementFailed }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw StoreError.statementFailed
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            try bindNull(at: index, in: statement)
            return
        }
        try bind(value, at: index, in: statement)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            try bindNull(at: index, in: statement)
            return
        }
        try bind(value, at: index, in: statement)
    }

    private func bindNull(at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw StoreError.statementFailed
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.statementFailed
        }
    }

    private func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func dateColumn(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}

private enum StoreError: Error {
    case openFailed
    case migrationFailed
    case statementFailed
    case invalidTranscriptBatch
    case backupFailed
    case invalidAccountingVersion
    case activeIndexReset
    case rollbackUnavailable
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
