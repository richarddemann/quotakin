import Darwin
import Foundation

public protocol ClaudeUsageControlTransport: Sendable {
    func usage(timeout: TimeInterval) async throws -> Data
}

/// Uses Claude Code's own authentication and token renewal. No user message or
/// model request is sent, and Quotakin never receives or stores credentials.
public struct ClaudeCLIQuotaProvider: AccountQuotaProvider {
    public let provider = Provider.claude
    public let connectionSource = ProviderConnectionSource.claudeCLI
    public let minimumRefreshInterval: TimeInterval = 5 * 60
    private let transport: any ClaudeUsageControlTransport
    private let observedAt: @Sendable () -> Date

    public init(
        transport: any ClaudeUsageControlTransport = ProcessClaudeUsageControlTransport(),
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.observedAt = observedAt
    }

    public func quotaSnapshots() async throws -> [QuotaSnapshot] {
        let data = try await transport.usage(timeout: 30)
        let response: UsageResponse
        do { response = try JSONDecoder().decode(UsageResponse.self, from: data) }
        catch { throw CloudUsageClientError.invalidResponse }
        guard response.rateLimitsAvailable, let limits = response.rateLimits else {
            throw CloudUsageClientError.noUsableQuota
        }
        // Share the OAuth window decoder, but obtain the payload through the
        // CLI rather than reading Claude's protected credential ourselves.
        return try ClaudeOAuthUsageClient.snapshots(from: limits, observedAt: observedAt())
    }

    private struct UsageResponse: Decodable {
        let rateLimitsAvailable: Bool
        let rateLimits: Data?
        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rateLimitsAvailable = try container.decode(Bool.self, forKey: .rateLimitsAvailable)
            let windows = try container.decodeIfPresent(Windows.self, forKey: .rateLimits)
            rateLimits = try windows.map { try JSONEncoder().encode($0) }
        }
    }
    private struct Windows: Codable {
        let five_hour: Window?
        let seven_day: Window?
    }
    private struct Window: Codable {
        let utilization: Double?
        let resets_at: String?
    }

}

public struct ProcessClaudeUsageControlTransport: ClaudeUsageControlTransport {
    private let executableURL: URL?
    public init(executableURL: URL? = nil) { self.executableURL = executableURL }

    public func usage(timeout: TimeInterval) async throws -> Data {
        guard let executable = executableURL ?? ProviderCLIExecutableLocator.locate(provider: .claude) else {
            throw CloudUsageClientError.clientUnavailable
        }
        let session = try ClaudeUsageControlSession(executableURL: executable)
        defer { session.terminate() }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try session.usage() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(timeout, 0)))
                session.terminate(timedOut: true)
                throw CloudUsageClientError.timedOut
            }
            do {
                guard let result = try await group.next() else {
                    throw CloudUsageClientError.clientUnavailable
                }
                group.cancelAll()
                return result
            } catch {
                session.terminate()
                group.cancelAll()
                if session.didTimeOut { throw CloudUsageClientError.timedOut }
                throw error
            }
        }
    }
}

private final class ClaudeUsageControlSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let directory: URL
    private var buffer = Data()
    private let terminationLock = NSLock()
    private var timedOut = false
    var didTimeOut: Bool { terminationLock.withLock { timedOut } }

    init(executableURL: URL) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "Quotakin-quota-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--no-session-persistence", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw CloudUsageClientError.clientUnavailable
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func terminate(timedOut: Bool = false) {
        terminationLock.withLock {
            self.timedOut = self.timedOut || timedOut
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Ensure a blocked reader gets EOF even if Claude ignores SIGTERM.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func usage() throws -> Data {
        _ = try request(id: "initialize", payload: ["subtype": "initialize", "hooks": [:]])
        return try request(id: "usage", payload: ["subtype": "get_usage"])
    }

    private func request(id: String, payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "control_request", "request_id": id, "request": payload
        ])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      root["type"] as? String == "control_response",
                      let response = root["response"] as? [String: Any],
                      response["request_id"] as? String == id else { continue }
                guard response["subtype"] as? String == "success",
                      let payload = response["response"] as? [String: Any] else {
                    // Never expose raw provider errors (which can contain secrets).
                    throw CloudUsageClientError.invalidResponse
                }
                return try JSONSerialization.data(withJSONObject: payload)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw CloudUsageClientError.clientUnavailable
            }
            buffer.append(chunk)
            guard buffer.count <= 4 * 1024 * 1024 else {
                throw CloudUsageClientError.invalidResponse
            }
        }
    }
}
