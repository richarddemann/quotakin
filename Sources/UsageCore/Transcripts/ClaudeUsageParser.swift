import Foundation

public enum ClaudeUsageParser {
    public static func parse(
        _ data: Data,
        sourceID: String,
        sourceGeneration: String = "current",
        state initialState: ClaudeUsageParserState = .init()
    ) -> TranscriptParseResult<ClaudeUsageParserState> {
        var state = initialState
        var records: [TranscriptUsageRecord] = []
        var diagnostics: [TranscriptParserDiagnostic] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in TranscriptJSONL.lines(in: data) {
            let physicalOffset = state.byteOffset
            state.lineNumber += 1
            state.byteOffset += Int64(line.consumedByteCount)
            let lineNumber = state.lineNumber
            guard !line.data.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }) else {
                continue
            }
            guard let event = try? decoder.decode(Event.self, from: line.data) else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .malformedJSON))
                continue
            }
            if state.sessionID == nil, let sessionID = event.sessionID {
                state.sessionID = TranscriptUsageIdentity(
                    provider: .claude,
                    kind: .derived,
                    value: "session|\(sessionID)"
                ).logicalDedupeKey
            }
            guard event.type == "assistant", let message = event.message, let usage = message.usage else {
                continue
            }
            guard let timestamp = event.timestamp else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .missingTimestamp))
                continue
            }
            guard let model = message.model, !model.isEmpty else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .missingModel))
                continue
            }
            let buckets = [usage.input, usage.cachedInput, usage.cacheCreationInput, usage.output]
            guard buckets.allSatisfy({ $0 >= 0 }) else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .invalidUsage))
                continue
            }

            let identity: TranscriptUsageIdentity
            if let requestID = event.requestID, !requestID.isEmpty {
                identity = .init(provider: .claude, kind: .request, value: requestID)
            } else if let messageID = message.id, !messageID.isEmpty {
                identity = .init(provider: .claude, kind: .message, value: messageID)
            } else if let eventID = event.uuid, !eventID.isEmpty {
                identity = .init(provider: .claude, kind: .event, value: eventID)
            } else {
                let session = state.sessionID ?? "unknown-session"
                identity = .init(
                    provider: .claude,
                    kind: .derived,
                    value: "\(session)|\(timestamp.timeIntervalSince1970)|\(model)|\(usage.input)|\(usage.cachedInput)|\(usage.cacheCreationInput)|\(usage.output)"
                )
            }

            let costAmount = event.costUSD ?? message.costUSD
            records.append(
                TranscriptUsageRecord(
                    provider: .claude,
                    timestamp: timestamp,
                    model: model,
                    totals: .init(
                        uncachedInputTokens: usage.input,
                        cachedInputTokens: usage.cachedInput,
                        cacheCreationInputTokens: usage.cacheCreationInput,
                        outputTokens: usage.output
                    ),
                    physicalIdentity: .init(
                        sourceID: sourceID,
                        sourceGeneration: sourceGeneration,
                        byteOffset: physicalOffset
                    ),
                    logicalDedupeKey: identity.logicalDedupeKey,
                    reportedCostUSD: costAmount
                )
            )
        }
        return .init(records: records, diagnostics: diagnostics, state: state)
    }
}

private extension ClaudeUsageParser {
    struct Event: Decodable {
        let type: String
        let timestamp: Date?
        let sessionID: String?
        let requestID: String?
        let uuid: String?
        let costUSD: Decimal?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, uuid, message
            case sessionID = "sessionId"
            case requestID = "requestId"
            case costUSD = "costUSD"
        }
    }

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
        let costUSD: Decimal?

        enum CodingKeys: String, CodingKey {
            case id, model, usage
            case costUSD = "cost_usd"
        }
    }

    struct Usage: Decodable {
        let input: Int
        let cachedInput: Int
        let cacheCreationInput: Int
        let output: Int

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case cachedInput = "cache_read_input_tokens"
            case cacheCreationInput = "cache_creation_input_tokens"
            case output = "output_tokens"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            input = try values.decodeIfPresent(Int.self, forKey: .input) ?? 0
            cachedInput = try values.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0
            cacheCreationInput = try values.decodeIfPresent(Int.self, forKey: .cacheCreationInput) ?? 0
            output = try values.decodeIfPresent(Int.self, forKey: .output) ?? 0
        }
    }
}
