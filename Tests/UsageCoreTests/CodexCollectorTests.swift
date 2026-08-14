import CryptoKit
import Foundation
import Testing
@testable import UsageCore

private func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        )
    )
    return try Data(contentsOf: url)
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
}

private func temporaryDirectoryURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func codexQuotaLine(
    timestamp: String,
    sessionUsedPercent: Int = 35,
    weeklyUsedPercent: Int = 54
) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":12,"reasoning_output_tokens":3,"total_tokens":135}},"rate_limits":{"primary":{"used_percent":\(sessionUsedPercent),"window_minutes":300,"resets_at":1780300000},"secondary":{"used_percent":\(weeklyUsedPercent),"window_minutes":10080,"resets_at":1780800000}},"plan_type":"plus"}}
    """
}

@Test
func codexSessionNormalizesInclusiveInputAndReasoningSubset() throws {
    let batch = try CodexCollector.parseSession(
        fixtureData(named: "codex-session", extension: "jsonl")
    )

    let sample = try #require(batch.tokens.first)
    #expect(batch.tokens.count == 1)
    #expect(sample.provider == .codex)
    #expect(sample.observedAt == Date(timeIntervalSince1970: 1_780_308_000))
    #expect(sample.model == "codex")
    #expect(sample.inputTokens == 80)
    #expect(sample.cachedInputTokens == 40)
    #expect(sample.outputTokens == 12)
    #expect(sample.reasoningOutputTokens == 3)
    #expect(sample.totalTokens == 132)
}

@Test
func codexSessionMapsRollingLimitsAndPlanType() throws {
    let batch = try CodexCollector.parseSession(
        fixtureData(named: "codex-session", extension: "jsonl")
    )

    #expect(batch.quota.count == 2)
    #expect(batch.quota[0].provider == .codex)
    #expect(batch.quota[0].window == .session)
    #expect(batch.quota[0].usedPercent == 35)
    #expect(batch.quota[0].resetsAt == Date(timeIntervalSince1970: 1_780_300_000))
    #expect(batch.quota[0].observedAt == Date(timeIntervalSince1970: 1_780_308_000))
    #expect(batch.quota[1].provider == .codex)
    #expect(batch.quota[1].window == .weekly)
    #expect(batch.quota[1].usedPercent == 54)
    #expect(batch.quota[1].resetsAt == Date(timeIntervalSince1970: 1_780_800_000))
    #expect(batch.quota[1].observedAt == Date(timeIntervalSince1970: 1_780_308_000))
    #expect(batch.planType == "plus")
}

@Test
func codexSessionSkipsUnrelatedValidRecords() throws {
    let batch = try CodexCollector.parseSession(
        fixtureData(named: "codex-session", extension: "jsonl")
    )

    #expect(batch.tokens.map(\.totalTokens) == [132])
    #expect(batch.quota.map(\.window) == [.session, .weekly])
}

@Test
func codexCollectorCollectsConfiguredFilesWithoutPersistence() async throws {
    let sessionURL = try #require(
        Bundle.module.url(
            forResource: "codex-session",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
    )
    let collector = CodexCollector(sessionURLs: [sessionURL])

    let batch = try await collector.collect()

    #expect(collector.provider == .codex)
    #expect(batch.tokens.map(\.totalTokens) == [132])
    #expect(batch.quota.map(\.window) == [.session, .weekly])
    #expect(batch.planType == "plus")
}

@Test
func codexSessionParseFailureIsSanitized() {
    let malformedContent = #"{"path":"/private/synthetic/codex-session.jsonl""#

    do {
        _ = try CodexCollector.parseSession(Data(malformedContent.utf8))
        Issue.record("Expected session parsing to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .codex)
        #expect(error.reason == .parseFailed)
        #expect(error.sourceID == nil)
        #expect(!description.contains(malformedContent))
        #expect(!description.contains("/private/synthetic/codex-session.jsonl"))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func codexCollectorReadFailureUsesHashedSourceIdentifier() async {
    let privatePath = "/private/synthetic/codex-session.jsonl"
    let sessionURL = URL(fileURLWithPath: privatePath)

    do {
        _ = try await CodexCollector(sessionURLs: [sessionURL]).collect()
        Issue.record("Expected collect to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .codex)
        #expect(error.reason == .readFailed)
        #expect(error.sourceID == sha256(privatePath))
        #expect(description.contains(sha256(privatePath)))
        #expect(!description.contains(privatePath))
        #expect(!description.contains(sessionURL.absoluteString))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func codexCollectorSessionParseFailureUsesHashedSourceIdentifier() async throws {
    let malformedContent = #"{"private":"synthetic malformed codex session""#
    let sessionURL = temporaryFileURL()
    try Data(malformedContent.utf8).write(to: sessionURL)
    defer { try? FileManager.default.removeItem(at: sessionURL) }

    do {
        _ = try await CodexCollector(sessionURLs: [sessionURL]).collect()
        Issue.record("Expected collection to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .codex)
        #expect(error.reason == .parseFailed)
        #expect(error.sourceID == sha256(sessionURL.path))
        #expect(!description.contains(sessionURL.path))
        #expect(!description.contains(sessionURL.absoluteString))
        #expect(!description.contains(malformedContent))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func codexQuotaHistoryBackfillStreamsRecentQuotaIntoStore() async throws {
    let root = try temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionURL = root.appending(path: "session.jsonl")
    try Data(
        """
        \(codexQuotaLine(timestamp: "2026-03-31T09:00:00Z", sessionUsedPercent: 10, weeklyUsedPercent: 20))
        \(codexQuotaLine(timestamp: "2026-06-01T10:00:00Z", sessionUsedPercent: 35, weeklyUsedPercent: 54))
        \(codexQuotaLine(timestamp: "2026-06-01T10:05:00Z", sessionUsedPercent: 35, weeklyUsedPercent: 54))
        \(codexQuotaLine(timestamp: "2026-06-01T10:10:00Z", sessionUsedPercent: 42, weeklyUsedPercent: 60))

        """.utf8
    ).write(to: sessionURL)

    let store = try UsageStore.inMemory()
    let backfill = CodexQuotaHistoryBackfill(
        roots: [root],
        cutoff: Date(timeIntervalSince1970: 1_780_000_000),
        saveBatchSize: 2
    )

    let result = try await backfill.run(into: store)
    let sessionHistory = try await store.quotaHistory(
        provider: .codex,
        window: .session,
        from: Date(timeIntervalSince1970: 0),
        to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let weeklyHistory = try await store.quotaHistory(
        provider: .codex,
        window: .weekly,
        from: Date(timeIntervalSince1970: 0),
        to: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(result.filesScanned == 1)
    #expect(result.snapshotsSaved == 6)
    #expect(sessionHistory.map(\.usedPercent) == [35, 42])
    #expect(weeklyHistory.map(\.usedPercent) == [54, 60])
    #expect(sessionHistory.allSatisfy { $0.observedAt >= Date(timeIntervalSince1970: 1_780_000_000) })
}

@Test
func codexQuotaLineParserSkipsOldAndUnknownWindows() throws {
    let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
    let old = try CodexCollector.parseQuotaSnapshots(
        line: Data(codexQuotaLine(timestamp: "2026-03-31T09:00:00Z").utf8),
        notBefore: cutoff
    )
    let unknownWindow = """
    {"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":35,"window_minutes":1440,"resets_at":1780300000}}}}
    """

    let unknown = try CodexCollector.parseQuotaSnapshots(
        line: Data(unknownWindow.utf8),
        notBefore: cutoff
    )

    #expect(old.isEmpty)
    #expect(unknown.isEmpty)
}
