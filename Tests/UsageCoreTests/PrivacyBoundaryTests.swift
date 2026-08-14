import Foundation
import Testing
@testable import UsageCore

@Suite("PrivacyBoundaryTests")
struct PrivacyBoundaryTests {
    @Test
    func storeInspectionAndErrorsDoNotExposeTranscriptContentOrSourcePath() async throws {
        let transcriptMarker = "synthetic-transcript-secret-marker"
        let sourcePath = "/Users/synthetic/.claude/projects/private-session/transcript-\(transcriptMarker).jsonl"
        let sourceID = SourceID.hash(path: sourcePath)
        let store = try UsageStore.inMemory()

        try await store.save(
            tokens: [
                TokenSample(
                    provider: .claude,
                    observedAt: Date(timeIntervalSince1970: 1_780_308_000),
                    model: "claude-sonnet-4-6",
                    inputTokens: 10,
                    outputTokens: 20,
                    cachedInputTokens: 5,
                    cacheCreationInputTokens: 3,
                    totalTokens: 38
                )
            ],
            quota: [
                QuotaSnapshot(
                    provider: .claude,
                    window: .session,
                    usedPercent: 41,
                    resetsAt: Date(timeIntervalSince1970: 1_780_400_000),
                    observedAt: Date(timeIntervalSince1970: 1_780_308_100)
                )
            ]
        )
        #expect(try await store.advanceCursor(sourceID: sourceID, from: 0, to: 256))
        #expect(try await store.cursor(for: sourceID) == 256)

        let inspection = String(decoding: try await store.databaseText(), as: UTF8.self)
        let errorDescriptions = [
            CollectorError.parseFailure(provider: .claude, path: sourcePath).description,
            CollectorError.readFailure(provider: .codex, path: sourcePath).description
        ].joined(separator: "\n")
        let logFacingText = inspection + "\n" + errorDescriptions

        #expect(sourceID.count == 64)
        #expect(sourceID != sourcePath)
        #expect(!sourceID.contains(sourcePath))
        #expect(!sourceID.contains(transcriptMarker))
        #expect(inspection.contains(sourceID))
        #expect(!logFacingText.contains(sourcePath))
        #expect(!logFacingText.contains(transcriptMarker))
    }
}
