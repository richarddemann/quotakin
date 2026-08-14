import Foundation

public enum CodexUsageParser {
    public static func parse(
        _ data: Data,
        sourceID: String,
        sourceGeneration: String = "current",
        state initialState: CodexUsageParserState = .init()
    ) -> TranscriptParseResult<CodexUsageParserState> {
        var state = initialState
        var records: [TranscriptUsageRecord] = []
        var diagnostics: [TranscriptParserDiagnostic] = []
        let decoder = makeDecoder()

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

            if event.type == "session_meta" {
                guard !state.sawSessionMeta else { continue }
                state.sawSessionMeta = true
                state.sessionID = (event.payload?.id ?? event.payload?.sessionID).map {
                    TranscriptUsageIdentity(
                        provider: .codex,
                        kind: .derived,
                        value: "session|\($0)"
                    ).logicalDedupeKey
                }
                state.suppressCopiedUsage = event.payload?.forkedFromID != nil
                    || event.payload?.source?.isCopiedSession == true
                    || event.payload?.originator?.localizedCaseInsensitiveContains("subagent") == true
                state.forkCopyAnchorAt = state.suppressCopiedUsage
                    ? (event.timestamp ?? event.payload?.timestamp)
                    : nil
                continue
            }
            if event.type == "turn_context" {
                if let model = event.payload?.model, !model.isEmpty { state.model = model }
                continue
            }
            guard
                event.type == "event_msg",
                event.payload?.type == "token_count",
                let usage = event.payload?.info?.lastTokenUsage
            else { continue }

            guard let sessionID = state.sessionID else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .missingSession))
                continue
            }
            guard let model = state.model, !model.isEmpty else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .missingModel))
                continue
            }
            guard let timestamp = event.timestamp else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .missingTimestamp))
                continue
            }
            guard usage.isValid else {
                diagnostics.append(.init(lineNumber: lineNumber, reason: .invalidUsage))
                continue
            }

            let snapshot = usage.snapshot
            if snapshot == state.previousUsage { continue }
            state.previousUsage = snapshot
            if state.suppressCopiedUsage {
                if let anchor = state.forkCopyAnchorAt,
                   timestamp.timeIntervalSince(anchor) < 1 {
                    state.forkCopyAnchorAt = timestamp
                    continue
                }
                state.suppressCopiedUsage = false
                state.forkCopyAnchorAt = nil
            }

            let identity: TranscriptUsageIdentity
            if let eventID = event.payload?.id, !eventID.isEmpty {
                identity = .init(provider: .codex, kind: .event, value: eventID)
            } else {
                identity = .init(
                    provider: .codex,
                    kind: .derived,
                    value: "\(sessionID)|\(timestamp.timeIntervalSince1970)|\(model)|\(snapshot.inputTokens)|\(snapshot.cachedInputTokens)|\(snapshot.outputTokens)|\(snapshot.reasoningOutputTokens)|\(snapshot.totalTokens)"
                )
            }
            records.append(
                TranscriptUsageRecord(
                    provider: .codex,
                    timestamp: timestamp,
                    model: model,
                    totals: .init(
                        uncachedInputTokens: max(
                            0,
                            usage.inputTokens
                                - usage.cachedInputTokens
                                - usage.cacheCreationInputTokens
                        ),
                        cachedInputTokens: usage.cachedInputTokens,
                        cacheCreationInputTokens: usage.cacheCreationInputTokens,
                        outputTokens: usage.outputTokens,
                        reasoningOutputTokens: min(usage.outputTokens, usage.reasoningOutputTokens)
                    ),
                    physicalIdentity: .init(
                        sourceID: sourceID,
                        sourceGeneration: sourceGeneration,
                        byteOffset: physicalOffset
                    ),
                    logicalDedupeKey: identity.logicalDedupeKey,
                    providerReportedTotalTokens: usage.totalTokens
                )
            )
        }
        return .init(records: records, diagnostics: diagnostics, state: state)
    }
}

private extension CodexUsageParser {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(value, strategy: .iso8601) { return date }
            if let date = try? Date(
                value,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            ) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 timestamp"
            )
        }
        return decoder
    }

    struct Event: Decodable {
        let timestamp: Date?
        let type: String
        let payload: Payload?
    }

    struct Payload: Decodable {
        let id: String?
        let sessionID: String?
        let timestamp: Date?
        let type: String?
        let model: String?
        let originator: String?
        let forkedFromID: String?
        let source: CopiedSessionSource?
        let info: TokenInfo?

        enum CodingKeys: String, CodingKey {
            case id, timestamp, type, model, originator, source, info
            case sessionID = "session_id"
            case forkedFromID = "forked_from_id"
        }
    }

    struct CopiedSessionSource: Decodable {
        let isCopiedSession: Bool

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                isCopiedSession = string.localizedCaseInsensitiveContains("fork")
                    || string.localizedCaseInsensitiveContains("subagent")
                return
            }
            let value = try JSONValue(from: decoder)
            isCopiedSession = value.containsKeyOrString("fork")
                || value.containsKeyOrString("subagent")
                || value.containsKeyOrString("parent_thread_id")
        }
    }

    indirect enum JSONValue: Decodable {
        case string(String)
        case object([String: JSONValue])
        case array([JSONValue])
        case other

        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
                var values: [String: JSONValue] = [:]
                for key in keyed.allKeys { values[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key) }
                self = .object(values)
            } else if var unkeyed = try? decoder.unkeyedContainer() {
                var values: [JSONValue] = []
                while !unkeyed.isAtEnd { values.append(try unkeyed.decode(JSONValue.self)) }
                self = .array(values)
            } else if let string = try? decoder.singleValueContainer().decode(String.self) {
                self = .string(string)
            } else {
                self = .other
            }
        }

        func containsKeyOrString(_ needle: String) -> Bool {
            switch self {
            case let .string(value): value.localizedCaseInsensitiveContains(needle)
            case let .object(values):
                values.contains { key, value in
                    key.localizedCaseInsensitiveContains(needle) || value.containsKeyOrString(needle)
                }
            case let .array(values): values.contains { $0.containsKeyOrString(needle) }
            case .other: false
            }
        }
    }

    struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    struct TokenInfo: Decodable {
        let lastTokenUsage: Usage?
        enum CodingKeys: String, CodingKey { case lastTokenUsage = "last_token_usage" }
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let cacheCreationInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheCreationInputTokens = "cache_write_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }

        var snapshot: CodexUsageParserState.UsageSnapshot {
            .init(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens
            )
        }

        var isValid: Bool {
            inputTokens >= 0 && cachedInputTokens >= 0 && cacheCreationInputTokens >= 0
                && cachedInputTokens + cacheCreationInputTokens <= inputTokens
                && outputTokens >= 0 && reasoningOutputTokens >= 0
                && totalTokens >= 0
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try values.decode(Int.self, forKey: .inputTokens)
            cachedInputTokens = try values.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
            cacheCreationInputTokens = try values.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
            outputTokens = try values.decode(Int.self, forKey: .outputTokens)
            reasoningOutputTokens = try values.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
            totalTokens = try values.decodeIfPresent(Int.self, forKey: .totalTokens) ?? inputTokens + outputTokens
        }
    }
}
