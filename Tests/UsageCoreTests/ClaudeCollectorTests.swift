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

private actor ClaudeQuotaProviderSpy: ClaudeQuotaProvider {
    private let result: Result<[QuotaSnapshot], Error>
    private(set) var callCount = 0

    init(result: Result<[QuotaSnapshot], Error>) {
        self.result = result
    }

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        callCount += 1
        return try result.get()
    }
}

private struct ClaudeQuotaProviderFailure: Error {}

private func quotaSnapshotData(observedAt: Date, usedPercent: Double) -> Data {
    let formatter = ISO8601DateFormatter()
    return Data(
        """
        {
          "observedAt": "\(formatter.string(from: observedAt))",
          "fiveHour": {
            "usedPercent": \(usedPercent),
            "resetsAt": \(observedAt.addingTimeInterval(3_600).timeIntervalSince1970)
          },
          "sevenDay": {
            "usedPercent": \(usedPercent + 1),
            "resetsAt": \(observedAt.addingTimeInterval(86_400).timeIntervalSince1970)
          }
        }
        """.utf8
    )
}

@Test
func claudeTranscriptExtractsUsageMetadataAndNormalizedTotal() throws {
    let samples = try ClaudeCollector.parseTranscript(
        fixtureData(named: "claude-transcript", extension: "jsonl")
    )

    let sample = try #require(samples.first)
    #expect(samples.count == 1)
    #expect(sample.provider == .claude)
    #expect(sample.observedAt == Date(timeIntervalSince1970: 1_780_308_000))
    #expect(sample.model == "claude-sonnet-4-6")
    #expect(sample.inputTokens == 3)
    #expect(sample.outputTokens == 20)
    #expect(sample.cachedInputTokens == 100)
    #expect(sample.cacheCreationInputTokens == 50)
    #expect(sample.reasoningOutputTokens == 0)
    #expect(sample.totalTokens == 173)
}

@Test
func claudeTranscriptSkipsNonAssistantAndMissingUsageRecords() throws {
    let samples = try ClaudeCollector.parseTranscript(
        fixtureData(named: "claude-transcript", extension: "jsonl")
    )

    #expect(samples.count == 1)
    #expect(samples.map(\.totalTokens) == [173])
}

@Test
func claudeQuotaSnapshotMapsSessionAndWeeklyWindows() throws {
    let snapshots = try ClaudeCollector.parseQuotaSnapshot(
        fixtureData(named: "claude-quota-snapshot", extension: "json")
    )

    #expect(snapshots.count == 2)
    #expect(snapshots[0].provider == .claude)
    #expect(snapshots[0].window == .session)
    #expect(snapshots[0].usedPercent == 42)
    #expect(snapshots[0].resetsAt == Date(timeIntervalSince1970: 1_780_300_000))
    #expect(snapshots[0].observedAt == Date(timeIntervalSince1970: 1_780_308_300))
    #expect(snapshots[1].provider == .claude)
    #expect(snapshots[1].window == .weekly)
    #expect(snapshots[1].usedPercent == 61)
    #expect(snapshots[1].resetsAt == Date(timeIntervalSince1970: 1_780_800_000))
    #expect(snapshots[1].observedAt == Date(timeIntervalSince1970: 1_780_308_300))
}

@Test
func claudeCollectorCollectsConfiguredFilesWithoutPersistence() async throws {
    let transcriptURL = try #require(
        Bundle.module.url(
            forResource: "claude-transcript",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
    )
    let quotaURL = try #require(
        Bundle.module.url(
            forResource: "claude-quota-snapshot",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    let collector = ClaudeCollector(
        transcriptURLs: [transcriptURL],
        quotaSnapshotURL: quotaURL,
        now: { Date(timeIntervalSince1970: 1_780_308_300) }
    )

    let batch = try await collector.collect()

    #expect(collector.provider == .claude)
    #expect(batch.tokens.count == 1)
    #expect(batch.tokens[0].totalTokens == 173)
    #expect(batch.quota.map(\.window) == [.session, .weekly])
    #expect(batch.planType == nil)
}

@Test
func claudeCollectorTreatsMissingOptionalQuotaSnapshotAsUnavailable() async throws {
    let collector = ClaudeCollector(
        quotaSnapshotURL: URL(fileURLWithPath: "/private/synthetic/missing-quota.json")
    )

    let batch = try await collector.collect()

    #expect(batch.tokens.isEmpty)
    #expect(batch.quota.isEmpty)
}

@Test
func claudeCollectorPrefersFreshLocalStatusSnapshotWithoutOAuth() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let snapshotURL = temporaryFileURL()
    try quotaSnapshotData(observedAt: now, usedPercent: 21).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let oauthQuota = [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 90,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
    ]
    let provider = ClaudeQuotaProviderSpy(result: .success(oauthQuota))
    let collector = ClaudeCollector(
        quotaSnapshotURL: snapshotURL,
        quotaProvider: provider,
        now: { now }
    )

    let batch = try await collector.collect()

    #expect(batch.quota.map(\.source) == [.local, .local])
    #expect(batch.quota.map(\.usedPercent) == [21, 22])
    #expect(await provider.callCount == 0)
}

@Test
func claudeCollectorDoesNotTouchFailingOAuthWhenLocalStatusIsFresh() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let snapshotURL = temporaryFileURL()
    try quotaSnapshotData(observedAt: now, usedPercent: 21).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let provider = ClaudeQuotaProviderSpy(
        result: .failure(ClaudeQuotaProviderFailure())
    )
    let collector = ClaudeCollector(
        quotaSnapshotURL: snapshotURL,
        quotaProvider: provider,
        now: { now }
    )

    let batch = try await collector.collect()

    #expect(batch.quota.map(\.source) == [.local, .local])
    #expect(batch.quota.map(\.usedPercent) == [21, 22])
    #expect(await provider.callCount == 0)
}

@Test
func claudeCollectorFallsBackToOAuthWhenStatusSnapshotIsStale() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let snapshotURL = temporaryFileURL()
    try quotaSnapshotData(
        observedAt: now.addingTimeInterval(-601),
        usedPercent: 21
    ).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let oauthQuota = [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 45,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
    ]
    let provider = ClaudeQuotaProviderSpy(result: .success(oauthQuota))
    let collector = ClaudeCollector(
        quotaSnapshotURL: snapshotURL,
        quotaProvider: provider,
        now: { now }
    )

    let batch = try await collector.collect()

    #expect(batch.quota == oauthQuota)
    #expect(await provider.callCount == 1)
}

@Test
func claudeCollectorCompleteLiveQuotaFailurePreservesLastKnownQuota() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let snapshotURL = temporaryFileURL()
    try quotaSnapshotData(
        observedAt: now.addingTimeInterval(-601),
        usedPercent: 21
    ).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let lastKnownQuota = [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            usedPercent: 38,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now.addingTimeInterval(-300)
        )
    ]
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: lastKnownQuota)
    let provider = ClaudeQuotaProviderSpy(
        result: .failure(ClaudeQuotaProviderFailure())
    )
    let collector = ClaudeCollector(
        quotaSnapshotURL: snapshotURL,
        quotaProvider: provider,
        roots: [URL(fileURLWithPath: "/private/synthetic/missing-claude-projects")],
        now: { now }
    )

    let batch = try await collector.collect(into: store)

    #expect(batch.quota.isEmpty)
    #expect(batch.isPersisted)
    #expect(try await store.latestQuota(provider: .claude, at: now) == lastKnownQuota)
    #expect(await provider.callCount == 1)
}

@Test
func claudeStatusSnapshotDirectoryIsNotWatchedForTranscriptRefreshes() {
    let transcriptRoot = URL(fileURLWithPath: "/private/synthetic/claude-projects")
    let snapshotURL = URL(fileURLWithPath: "/private/synthetic/usagebar/claude-quota-snapshot.json")
    let collector = ClaudeCollector(
        quotaSnapshotURL: snapshotURL,
        roots: [transcriptRoot]
    )

    #expect(collector.sourceDirectories == [transcriptRoot])
}

@Test
func claudeCollectorReadFailureUsesHashedSourceIdentifier() async {
    let privatePath = "/private/synthetic/claude-transcript.jsonl"
    let transcriptURL = URL(fileURLWithPath: privatePath)
    let collector = ClaudeCollector(transcriptURLs: [transcriptURL])

    do {
        _ = try await collector.collect()
        Issue.record("Expected collect to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .claude)
        #expect(error.reason == .readFailed)
        #expect(error.sourceID == sha256(privatePath))
        #expect(description.contains(sha256(privatePath)))
        #expect(!description.contains(privatePath))
        #expect(!description.contains(transcriptURL.absoluteString))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func claudeTranscriptParseFailureIsSanitized() {
    let malformedContent = #"{"path":"/private/synthetic/transcript.jsonl""#

    do {
        _ = try ClaudeCollector.parseTranscript(Data(malformedContent.utf8))
        Issue.record("Expected transcript parsing to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .claude)
        #expect(error.reason == .parseFailed)
        #expect(error.sourceID == nil)
        #expect(!description.contains(malformedContent))
        #expect(!description.contains("/private/synthetic/transcript.jsonl"))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func claudeQuotaParseFailureIsSanitized() {
    let malformedContent = #"{"path":"/private/synthetic/quota.json""#

    do {
        _ = try ClaudeCollector.parseQuotaSnapshot(Data(malformedContent.utf8))
        Issue.record("Expected quota parsing to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .claude)
        #expect(error.reason == .parseFailed)
        #expect(error.sourceID == nil)
        #expect(!description.contains(malformedContent))
        #expect(!description.contains("/private/synthetic/quota.json"))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func claudeCollectorTranscriptParseFailureUsesHashedSourceIdentifier() async throws {
    let malformedContent = #"{"private":"synthetic malformed transcript""#
    let transcriptURL = temporaryFileURL()
    try Data(malformedContent.utf8).write(to: transcriptURL)
    defer { try? FileManager.default.removeItem(at: transcriptURL) }

    do {
        _ = try await ClaudeCollector(transcriptURLs: [transcriptURL]).collect()
        Issue.record("Expected transcript collection to throw")
    } catch let error as CollectorError {
        let description = error.description

        #expect(error.provider == .claude)
        #expect(error.reason == .parseFailed)
        #expect(error.sourceID == sha256(transcriptURL.path))
        #expect(!description.contains(transcriptURL.path))
        #expect(!description.contains(transcriptURL.absoluteString))
        #expect(!description.contains(malformedContent))
    } catch {
        Issue.record("Expected CollectorError")
    }
}

@Test
func claudeCollectorFallsBackToOAuthWhenStatusSnapshotIsMalformed() async throws {
    let malformedContent = #"{"private":"synthetic malformed quota""#
    let quotaURL = temporaryFileURL()
    try Data(malformedContent.utf8).write(to: quotaURL)
    defer { try? FileManager.default.removeItem(at: quotaURL) }
    let now = Date(timeIntervalSince1970: 2_000)
    let oauthQuota = [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 45,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
    ]
    let provider = ClaudeQuotaProviderSpy(result: .success(oauthQuota))

    let batch = try await ClaudeCollector(
        quotaSnapshotURL: quotaURL,
        quotaProvider: provider,
        now: { now }
    ).collect()

    #expect(batch.quota == oauthQuota)
    #expect(await provider.callCount == 1)
}
