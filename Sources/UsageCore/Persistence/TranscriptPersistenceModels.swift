import Foundation

public struct TranscriptSourceMetadata: Equatable, Sendable {
    public let sourceID: String
    public let sourceFingerprint: String
    public let provider: Provider
    public let generation: String
    public let parserVersion: Int

    public init(sourceID: String, sourceFingerprint: String, provider: Provider, generation: String, parserVersion: Int) {
        precondition(!sourceID.isEmpty && !sourceFingerprint.isEmpty && !generation.isEmpty)
        precondition(parserVersion > 0)
        self.sourceID = sourceID
        self.sourceFingerprint = sourceFingerprint
        self.provider = provider
        self.generation = generation
        self.parserVersion = parserVersion
    }
}

public struct TranscriptCheckpoint: Equatable, Sendable {
    public let sourceID: String
    public let sourceGeneration: String
    public let byteOffset: Int64
    public let parserState: Data
    public let parserStateVersion: Int

    public init(sourceID: String, sourceGeneration: String, byteOffset: Int64, parserState: Data, parserStateVersion: Int) {
        precondition(!sourceID.isEmpty && !sourceGeneration.isEmpty)
        precondition(byteOffset >= 0 && parserStateVersion > 0)
        self.sourceID = sourceID
        self.sourceGeneration = sourceGeneration
        self.byteOffset = byteOffset
        self.parserState = parserState
        self.parserStateVersion = parserStateVersion
    }
}

public enum UsageReindexState: String, Sendable {
    case pending, running, completed, failed, rolledBack = "rolled_back"
}

public struct UsageReindexMetadata: Equatable, Sendable {
    public let id: String
    public let fromAccountingVersion: Int
    public let toAccountingVersion: Int
    public let state: UsageReindexState
    public let startedAt: Date?
    public let completedAt: Date?

    public init(id: String, fromAccountingVersion: Int, toAccountingVersion: Int, state: UsageReindexState, startedAt: Date? = nil, completedAt: Date? = nil) {
        precondition(!id.isEmpty && fromAccountingVersion > 0 && toAccountingVersion > 0)
        self.id = id
        self.fromAccountingVersion = fromAccountingVersion
        self.toAccountingVersion = toAccountingVersion
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct TranscriptIndexValidation: Equatable, Sendable {
    public let sourceCount: Int
    public let checkpointCount: Int
    public let physicalRecordCount: Int
    public let orphanCheckpointCount: Int
    public let orphanRecordCount: Int
    public let invalidTokenRecordCount: Int

    public var isValid: Bool { orphanCheckpointCount == 0 && orphanRecordCount == 0 && invalidTokenRecordCount == 0 }
}
