import Foundation
import Security

public enum CloudUsageSource: String, Codable, Sendable {
    case openAIOrganizationUsage
    case anthropicClaudeCodeAnalytics
}

public enum CloudUsageDataKind: String, Codable, Sendable {
    case apiPlatformUsage
    case dailyCloudAnalytics
}

public struct CloudUsageSummary: Codable, Equatable, Sendable {
    public let provider: Provider
    public let source: CloudUsageSource
    public let dataKind: CloudUsageDataKind
    public let observedAt: Date
    public let rangeStart: Date
    public let rangeEnd: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let requestCount: Int
    public let sessionCount: Int
    public let costAmount: Double?
    public let costCurrency: String?

    public init(
        provider: Provider,
        source: CloudUsageSource,
        dataKind: CloudUsageDataKind,
        observedAt: Date,
        rangeStart: Date,
        rangeEnd: Date,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        requestCount: Int = 0,
        sessionCount: Int = 0,
        costAmount: Double? = nil,
        costCurrency: String? = nil
    ) {
        self.provider = provider
        self.source = source
        self.dataKind = dataKind
        self.observedAt = observedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.requestCount = requestCount
        self.sessionCount = sessionCount
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }
}

public struct CloudUsageHTTPRequest: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct CloudUsageHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    public func headerValue(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol CloudUsageTransport: Sendable {
    func data(for request: CloudUsageHTTPRequest) async throws -> CloudUsageHTTPResponse
}

public struct URLSessionCloudUsageTransport: CloudUsageTransport {
    public let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 30) {
        self.requestTimeout = max(requestTimeout, 0)
    }

    public func data(for request: CloudUsageHTTPRequest) async throws -> CloudUsageHTTPResponse {
        let urlRequest = urlRequest(for: request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            return CloudUsageHTTPResponse(statusCode: 0, data: data)
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return CloudUsageHTTPResponse(
            statusCode: httpResponse.statusCode,
            data: data,
            headers: headers
        )
    }

    func urlRequest(for request: CloudUsageHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = requestTimeout
        for (header, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }
        return urlRequest
    }
}

public enum CloudUsageClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case credentialUnavailable
    case credentialAccessDenied
    case credentialExpired
    case mcpOnlyCredential
    case insufficientScope
    case clientUnavailable
    case timedOut
    case rateLimited(retryAfter: Date?)
    case requestFailed(statusCode: Int)
    case invalidResponse
    case noUsableQuota
}

public struct ClaudeOAuthCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        subscriptionType: String?,
        rateLimitTier: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scopes
        case subscriptionType
        case rateLimitTier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
        rateLimitTier = try container.decodeIfPresent(String.self, forKey: .rateLimitTier)
    }
}

public struct ClaudeOAuthCredentialLoadResult: Sendable {
    public let credentials: [ClaudeOAuthCredential]
    public let keychainAccessDenied: Bool
    public let mcpOnlyCredentialDetected: Bool

    public init(
        credentials: [ClaudeOAuthCredential],
        keychainAccessDenied: Bool = false,
        mcpOnlyCredentialDetected: Bool = false
    ) {
        self.credentials = credentials
        self.keychainAccessDenied = keychainAccessDenied
        self.mcpOnlyCredentialDetected = mcpOnlyCredentialDetected
    }
}

public protocol ClaudeOAuthCredentialStore: Sendable {
    func loadCredentials() async throws -> ClaudeOAuthCredentialLoadResult
}

public extension ClaudeOAuthCredentialStore {
    func loadCredential() async throws -> ClaudeOAuthCredential? {
        try await loadCredentials().credentials.first
    }
}

public protocol ClaudeQuotaProvider: Sendable {
    func quotaSnapshots() async throws -> [QuotaSnapshot]
}

public protocol AccountQuotaProvider: Sendable {
    var provider: Provider { get }
    var connectionSource: ProviderConnectionSource { get }
    var minimumRefreshInterval: TimeInterval { get }
    func quotaSnapshots() async throws -> [QuotaSnapshot]
}

public extension AccountQuotaProvider {
    var connectionSource: ProviderConnectionSource { .accountProbe }
    var minimumRefreshInterval: TimeInterval { 0 }
}

public protocol CodexAccountCredentialStore: Sendable {
    func loadAccessToken() throws -> String?
}

public protocol CodexAppServerTransport: Sendable {
    func requests(methods: [String], timeout: TimeInterval) async throws -> [Data]
}

public struct CodexAccountCredentialFileStore: CodexAccountCredentialStore {
    private let fileURL: URL

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/auth.json")
    ) {
        self.fileURL = fileURL
    }

    public func loadAccessToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let credential = try JSONDecoder().decode(
            CodexAccountCredential.self,
            from: Data(contentsOf: fileURL)
        )
        return credential.tokens?.accessToken
    }
}

public struct ClaudeCodeCredentialStore: ClaudeOAuthCredentialStore {
    private struct KeychainServiceCandidate {
        let service: String
        let modifiedAt: Date
    }

    private enum CredentialLocation {
        case file(URL)
        case keychain(String)
    }

    private struct CredentialCandidate {
        let location: CredentialLocation
        let modifiedAt: Date
    }

    private static let servicePrefix = "Claude Code-credentials"
    private let keychainServices: [String]
    private let fallbackFileURL: URL

    public init(
        keychainServices: [String] = ["Claude Code-credentials"],
        fallbackFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
    ) {
        self.keychainServices = keychainServices
        self.fallbackFileURL = fallbackFileURL
    }

    public func loadCredentials() async throws -> ClaudeOAuthCredentialLoadResult {
        var candidates = resolvedKeychainServices().map {
            CredentialCandidate(location: .keychain($0.service), modifiedAt: $0.modifiedAt)
        }
        if FileManager.default.fileExists(atPath: fallbackFileURL.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fallbackFileURL.path)
            candidates.append(CredentialCandidate(
                location: .file(fallbackFileURL),
                modifiedAt: attributes?[.modificationDate] as? Date ?? .distantPast
            ))
        }
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var credentials: [ClaudeOAuthCredential] = []
        var seenAccessTokens: Set<String> = []
        var mcpOnlyCredentialDetected = false
        for candidate in candidates {
            let data: Data?
            switch candidate.location {
            case let .file(url):
                data = try? Data(contentsOf: url)
            case let .keychain(service):
                guard !Self.keychainAccessDenied.value else {
                    continue
                }
                data = Self.keychainPasswordData(service: service)
            }
            if let data {
                if Self.isMCPOnlyCredentialPayload(data) {
                    mcpOnlyCredentialDetected = true
                } else if let credential = Self.decodeCredential(from: data),
                          seenAccessTokens.insert(credential.accessToken).inserted {
                    credentials.append(credential)
                }
            }
        }

        return ClaudeOAuthCredentialLoadResult(
            credentials: credentials,
            keychainAccessDenied: Self.keychainAccessDenied.value,
            mcpOnlyCredentialDetected: mcpOnlyCredentialDetected
        )
    }

    static func isMCPOnlyCredentialPayload(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return root["claudeAiOauth"] == nil && root["mcpOAuth"] != nil
    }

    private static func decodeCredential(from data: Data) -> ClaudeOAuthCredential? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let envelope = try? decoder.decode(ClaudeOAuthCredentialEnvelope.self, from: data) {
            return envelope.claudeAiOauth
        }
        return try? decoder.decode(ClaudeOAuthCredential.self, from: data)
    }

    /// Claude Code's keychain item carries a legacy ACL, which prompts the
    /// user at data access no matter what `kSecUseAuthenticationUI` says.
    /// Every refresh re-evaluates the ACL, so a single denial must silence
    /// keychain reads for the rest of the process or the prompt nags on
    /// every cycle.
    private static let keychainAccessDenied = LockedFlag()
    private static let keychainInteractionLock = NSLock()

    private static func keychainPasswordData(service: String, allowUserInteraction: Bool = false) -> Data? {
        // Claude Code's item carries a legacy keychain ACL; reading its data
        // from a process outside the ACL blocks on a password prompt — and
        // blocks *forever* when the screen is locked and the prompt cannot
        // render. Background reads must therefore never allow interaction;
        // the one-time grant happens through an explicit Settings action.
        // The process-wide SecKeychain interaction gate is deprecated, but
        // there is no supported replacement that also suppresses a legacy ACL
        // prompt: `kSecUseAuthenticationUI` alone is not honored by that item.
        // Keep this synchronous critical section small and always restore the
        // prior process setting so background reads remain fail-closed.
        keychainInteractionLock.lock()
        defer { keychainInteractionLock.unlock() }
        var previousInteraction: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowUserInteraction) == errSecSuccess else {
            return nil
        }
        defer {
            _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUserInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if Self.isCredentialAccessDeniedStatus(status) {
                keychainAccessDenied.set()
            }
            return nil
        }
        return result as? Data
    }

    static func isCredentialAccessDeniedStatus(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
    }

    /// User-initiated grant: allows the keychain ACL prompt exactly once,
    /// from a Settings action, never from the refresh loop. Returns whether
    /// a credential became readable.
    public func authorizeKeychainAccessInteractively() -> Bool {
        for candidate in resolvedKeychainServices() {
            if Self.keychainPasswordData(service: candidate.service, allowUserInteraction: true) != nil {
                Self.keychainAccessDenied.clear()
                return true
            }
        }
        return false
    }

    private func resolvedKeychainServices() -> [KeychainServiceCandidate] {
        var candidates = Self.discoveredKeychainServices()
        let discoveredServices = Set(candidates.map(\.service))
        candidates += keychainServices.compactMap { service in
            discoveredServices.contains(service)
                ? nil
                : KeychainServiceCandidate(service: service, modifiedAt: .distantPast)
        }
        return Self.prioritizedCredentialCandidates(candidates)
    }

    /// Claude Code 2.1.52+ may suffix credential services with an account hash.
    /// Query attributes only, never secret data, so discovery cannot display
    /// an ACL prompt. Secret reads remain separately gated and non-interactive.
    private static func discoveredKeychainServices() -> [KeychainServiceCandidate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }

        let attributes: [[String: Any]]
        if let many = result as? [[String: Any]] {
            attributes = many
        } else if let one = result as? [String: Any] {
            attributes = [one]
        } else {
            return []
        }

        return attributes.compactMap { item -> KeychainServiceCandidate? in
            guard let service = item[kSecAttrService as String] as? String else {
                return nil
            }
            return KeychainServiceCandidate(
                service: service,
                modifiedAt: item[kSecAttrModificationDate as String] as? Date ?? .distantPast
            )
        }
    }

    static func prioritizedCredentialServices(_ modifiedAtByService: [String: Date]) -> [String] {
        prioritizedCredentialCandidates(modifiedAtByService.map {
            KeychainServiceCandidate(service: $0.key, modifiedAt: $0.value)
        }).map(\.service)
    }

    private static func prioritizedCredentialCandidates(
        _ candidates: [KeychainServiceCandidate]
    ) -> [KeychainServiceCandidate] {
        var newestByService: [String: KeychainServiceCandidate] = [:]
        for candidate in candidates {
            let service = candidate.service
            guard service == servicePrefix || service.hasPrefix("\(servicePrefix)-") else {
                continue
            }
            if let existing = newestByService[service],
               existing.modifiedAt >= candidate.modifiedAt {
                continue
            }
            newestByService[service] = candidate
        }
        return newestByService.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.service < rhs.service
        }
    }

}

public struct ClaudeOAuthUsageClient: Sendable {
    private let accessToken: String
    private let transport: any CloudUsageTransport
    private let baseURL: URL
    private let observedAt: @Sendable () -> Date
    private let userAgent: String

    public init(
        accessToken: String,
        transport: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        observedAt: @escaping @Sendable () -> Date = Date.init,
        userAgent: String = ClaudeCodeUserAgent.current
    ) {
        self.accessToken = accessToken
        self.transport = transport
        self.baseURL = baseURL
        self.observedAt = observedAt
        self.userAgent = userAgent
    }

    public func quotaSnapshots() async throws -> [QuotaSnapshot] {
        let data = try await send()
        let decoded = try decode(ClaudeOAuthUsageResponse.self, from: data)
        let observedAt = observedAt()
        var snapshots: [QuotaSnapshot] = []

        if let fiveHour = decoded.fiveHour,
           let snapshot = snapshot(from: fiveHour, window: .session, observedAt: observedAt) {
            snapshots.append(snapshot)
        }
        // `seven_day` is the account-wide weekly cap. Flat `seven_day_*`
        // fields and the newer `limits` array describe scoped limits; this
        // model cannot label those safely, so it deliberately ignores them.
        if let weekly = decoded.sevenDay,
           let snapshot = snapshot(from: weekly, window: .weekly, observedAt: observedAt) {
            snapshots.append(snapshot)
        }

        guard !snapshots.isEmpty else {
            throw CloudUsageClientError.noUsableQuota
        }

        return snapshots
    }

    private func send() async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudUsageClientError.invalidBaseURL
        }
        components.path = "/api/oauth/usage"
        guard let url = components.url else {
            throw CloudUsageClientError.invalidBaseURL
        }

        let response = try await transport.data(
            for: CloudUsageHTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": userAgent
                ]
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 {
                throw CloudUsageClientError.rateLimited(
                    retryAfter: Self.retryAfterDate(from: response, now: observedAt())
                )
            }
            throw CloudUsageClientError.requestFailed(statusCode: response.statusCode)
        }
        return response.data
    }

    private func snapshot(
        from window: ClaudeOAuthUsageWindow,
        window quotaWindow: QuotaWindow,
        observedAt: Date
    ) -> QuotaSnapshot? {
        guard
            let utilization = window.utilization,
            utilization.isFinite,
            let resetsAt = Self.parseISO8601Date(window.resetsAt),
            resetsAt > observedAt
        else {
            return nil
        }
        return QuotaSnapshot(
            provider: .claude,
            window: quotaWindow,
            source: .account,
            usedPercent: utilization,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func retryAfterDate(
        from response: CloudUsageHTTPResponse,
        now: Date = Date()
    ) -> Date? {
        guard let rawValue = response.headerValue(named: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: rawValue)
    }
}

public enum ClaudeCodeUserAgent {
    public static let fallback = "claude-code/2.1.0"
    public static let current = detected()

    public static func resolving(versionOutput: String?) -> String {
        guard let versionOutput else {
            return fallback
        }
        let version = versionOutput
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .first { candidate in
                candidate.contains(".")
                    && candidate.allSatisfy { $0.isNumber || $0 == "." }
            }
        guard let version else {
            return fallback
        }
        return "claude-code/\(version)"
    }

    static func discoverExecutable(
        candidates: [URL],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        candidates.first { isExecutable($0.path) }
    }

    private static var executableCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
    }

    private static func detected() -> String {
        let process = Process()
        let output = Pipe()
        if let executable = discoverExecutable(candidates: executableCandidates) {
            process.executableURL = executable
            process.arguments = ["--version"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "--version"]
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return fallback
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return resolving(versionOutput: String(data: data, encoding: .utf8))
        } catch {
            return fallback
        }
    }
}

public struct CodexAccountQuotaProvider: AccountQuotaProvider {
    public let provider = Provider.codex
    public let connectionSource = ProviderConnectionSource.codexAppServer

    private let transport: any CodexAppServerTransport
    private let timeout: TimeInterval
    private let observedAt: @Sendable () -> Date

    public init(
        transport: any CodexAppServerTransport = ProcessCodexAppServerTransport(),
        timeout: TimeInterval = 5,
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.timeout = timeout
        self.observedAt = observedAt
    }

    public init(
        accessToken _: String,
        transport _: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        baseURL _: URL = URL(string: "https://chatgpt.com")!,
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(observedAt: observedAt)
    }

    public func quotaSnapshots() async throws -> [QuotaSnapshot] {
        let responses = try await transport.requests(
            methods: ["account/rateLimits/read"],
            timeout: timeout
        )
        guard let response = responses.first, responses.count == 1 else {
            throw CloudUsageClientError.invalidResponse
        }
        let decoded = try decode(CodexAppServerRateLimitsResponse.self, from: response)
        let observedAt = observedAt()
        let rateLimits = decoded.rateLimitsByLimitId?["codex"] ?? decoded.rateLimits
        let snapshots = [rateLimits.primary, rateLimits.secondary]
            .compactMap { snapshot(from: $0, observedAt: observedAt) }
        guard !snapshots.isEmpty else {
            throw CloudUsageClientError.noUsableQuota
        }
        return snapshots
    }

    private func snapshot(
        from window: CodexAppServerRateLimitWindow?,
        observedAt: Date
    ) -> QuotaSnapshot? {
        guard
            let window,
            let resetsAt = window.resetsAt,
            let quotaWindow = codexQuotaWindow(windowMinutes: window.windowDurationMins),
            Date(timeIntervalSince1970: TimeInterval(resetsAt)) > observedAt
        else {
            return nil
        }
        return QuotaSnapshot(
            provider: provider,
            window: quotaWindow,
            source: .account,
            usedPercent: window.usedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt)),
            observedAt: observedAt
        )
    }
}

public struct ProcessCodexAppServerTransport: CodexAppServerTransport {
    private let executableURL: URL?
    private let arguments: [String]

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server", "--stdio"]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// GUI apps launch with the bare launchd PATH, so `/usr/bin/env codex`
    /// misses user installs. Probe the common install locations before
    /// falling back to PATH resolution.
    static func discoverCodexBinary() -> URL? {
        ProviderCLIExecutableLocator.locate(provider: .codex)
    }

    public func requests(methods: [String], timeout: TimeInterval) async throws -> [Data] {
        let session = try ProcessCodexAppServerSession(
            executableURL: executableURL ?? Self.discoverCodexBinary(),
            arguments: arguments
        )
        defer {
            session.terminate()
        }

        return try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask {
                try methods.map { try session.request(method: $0) }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                session.terminate()
                throw CloudUsageClientError.timedOut
            }

            guard let result = try await group.next() else {
                throw CloudUsageClientError.clientUnavailable
            }
            group.cancelAll()
            return result
        }
    }
}

private final class ProcessCodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var nextID = 1
    private var readBuffer = Data()
    private var didInitialize = false

    init(executableURL: URL?, arguments: [String]) throws {
        process = Process()
        input = Pipe()
        output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // codex logs verbosely to stderr; an undrained Pipe fills its 64 KB
        // buffer and blocks the child mid-write, wedging the RPC exchange.
        process.standardError = FileHandle.nullDevice
        process.arguments = arguments
        if let executableURL {
            process.executableURL = executableURL
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + arguments
        }

        do {
            try process.run()
        } catch {
            throw CloudUsageClientError.clientUnavailable
        }
    }

    func request(method: String) throws -> Data {
        lock.lock()
        defer {
            lock.unlock()
        }

        try initializeIfNeeded()
        let id = nextID
        nextID += 1
        try write(CodexJSONRPCRequest(id: id, method: method))
        while true {
            let response = try readMessage()
            if response.id == id {
                if response.error != nil {
                    throw CloudUsageClientError.requestFailed(statusCode: 0)
                }
                guard let result = response.result else {
                    throw CloudUsageClientError.invalidResponse
                }
                return result
            }
        }
    }

    private func initializeIfNeeded() throws {
        guard !didInitialize else {
            return
        }
        let id = nextID
        nextID += 1
        try write(
            CodexJSONRPCRequest(
                id: id,
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("Quotakin"),
                        "title": .string("Quotakin"),
                        "version": .string("1.0")
                    ])
                ])
            )
        )
        while true {
            let response = try readMessage()
            if response.id == id {
                if response.error != nil {
                    throw CloudUsageClientError.requestFailed(statusCode: 0)
                }
                didInitialize = true
                return
            }
        }
    }

    func terminate() {
        guard process.isRunning else {
            return
        }
        try? input.fileHandleForWriting.close()
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // codex app-server survives SIGTERM/SIGINT; escalate to SIGKILL so
        // blocked pipe reads see EOF — otherwise the timeout path can never
        // unwind the task group and the refresh actor hangs forever.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func write(_ request: CodexJSONRPCRequest) throws {
        let payload = try encoder.encode(request)
        var line = payload
        line.append(UInt8(ascii: "\n"))
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func readMessage() throws -> CodexJSONRPCResponse {
        while true {
            if let parsed = try parseBufferedMessage() {
                return parsed
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                throw CloudUsageClientError.clientUnavailable
            }
            readBuffer.append(chunk)
        }
    }

    private func parseBufferedMessage() throws -> CodexJSONRPCResponse? {
        guard let lineEnd = readBuffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let line = readBuffer[..<lineEnd]
        readBuffer.removeSubrange(...lineEnd)
        if line.isEmpty || line.elementsEqual(Data("\r".utf8)) {
            return nil
        }
        return try decode(CodexJSONRPCResponse.self, from: Data(line))
    }
}

public struct ClaudeCodeOAuthQuotaProvider: ClaudeQuotaProvider, AccountQuotaProvider {
    public let provider = Provider.claude
    public let connectionSource = ProviderConnectionSource.claudeOAuth
    public let minimumRefreshInterval: TimeInterval

    private let credentialStore: any ClaudeOAuthCredentialStore
    private let transport: any CloudUsageTransport
    private let usageBaseURL: URL
    private let observedAt: @Sendable () -> Date

    public init(
        credentialStore: any ClaudeOAuthCredentialStore = ClaudeCodeCredentialStore(),
        transport: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        usageBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        tokenBaseURL: URL = URL(string: "https://platform.claude.com")!,
        minimumRefreshInterval: TimeInterval = 15 * 60,
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.usageBaseURL = usageBaseURL
        self.minimumRefreshInterval = minimumRefreshInterval
        self.observedAt = observedAt
        _ = tokenBaseURL
    }

    public func quotaSnapshots() async throws -> [QuotaSnapshot] {
        let loadResult = try await credentialStore.loadCredentials()
        let credentials = loadResult.credentials
        guard !credentials.isEmpty else {
            if loadResult.keychainAccessDenied {
                throw CloudUsageClientError.credentialAccessDenied
            }
            if loadResult.mcpOnlyCredentialDetected {
                throw CloudUsageClientError.mcpOnlyCredential
            }
            throw CloudUsageClientError.credentialUnavailable
        }

        var lastCredentialError = CloudUsageClientError.credentialUnavailable
        for credential in credentials {
            // Recent Claude Code credentials may serialize access-token expiry
            // as 0. Treat that as unknown and let the read-only API decide.
            if let expiresAt = credential.expiresAt,
               expiresAt.timeIntervalSince1970 > 0,
               expiresAt <= observedAt() {
                lastCredentialError = .credentialExpired
                continue
            }
            if !credential.scopes.isEmpty,
               !credential.scopes.contains("user:profile") {
                lastCredentialError = .insufficientScope
                continue
            }
            do {
                return try await usageClient(for: credential).quotaSnapshots()
            } catch let error as CloudUsageClientError {
                switch error {
                case .requestFailed(statusCode: 401), .requestFailed(statusCode: 403):
                    lastCredentialError = error
                    continue
                default:
                    throw error
                }
            }
        }
        if loadResult.keychainAccessDenied {
            throw CloudUsageClientError.credentialAccessDenied
        }
        throw lastCredentialError
    }

    private func usageClient(for credential: ClaudeOAuthCredential) -> ClaudeOAuthUsageClient {
        ClaudeOAuthUsageClient(
            accessToken: credential.accessToken,
            transport: transport,
            baseURL: usageBaseURL,
            observedAt: observedAt
        )
    }

}

public struct OpenAIOrganizationUsageClient: Sendable {
    private let adminKey: String
    private let transport: any CloudUsageTransport
    private let baseURL: URL
    private let observedAt: @Sendable () -> Date

    public init(
        adminKey: String,
        transport: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        baseURL: URL = URL(string: "https://api.openai.com")!,
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adminKey = adminKey
        self.transport = transport
        self.baseURL = baseURL
        self.observedAt = observedAt
    }

    public func summary(start: Date, end: Date) async throws -> CloudUsageSummary {
        async let usage = completionUsage(start: start, end: end)
        async let costs = costs(start: start, end: end)
        let (usageTotals, costTotals) = try await (usage, costs)

        return CloudUsageSummary(
            provider: .codex,
            source: .openAIOrganizationUsage,
            dataKind: .apiPlatformUsage,
            observedAt: observedAt(),
            rangeStart: start,
            rangeEnd: end,
            inputTokens: usageTotals.inputTokens,
            outputTokens: usageTotals.outputTokens,
            cachedInputTokens: usageTotals.cachedInputTokens,
            requestCount: usageTotals.requestCount,
            costAmount: roundedCurrency(costTotals.amount),
            costCurrency: costTotals.currency
        )
    }

    private func completionUsage(start: Date, end: Date) async throws -> UsageTotals {
        var page: String?
        var totals = UsageTotals()

        repeat {
            let response = try await send(
                path: "/v1/organization/usage/completions",
                queryItems: paginationQueryItems(start: start, end: end, page: page)
                    + [URLQueryItem(name: "bucket_width", value: "1d")]
            )
            let decoded = try decode(OpenAIUsagePage.self, from: response)
            for bucket in decoded.data {
                for result in bucket.results {
                    totals.inputTokens += result.inputTokens ?? 0
                    totals.outputTokens += result.outputTokens ?? 0
                    totals.cachedInputTokens += result.inputCachedTokens ?? 0
                    totals.requestCount += result.numModelRequests ?? 0
                }
            }
            page = decoded.hasMore ? decoded.nextPage : nil
        } while page != nil

        return totals
    }

    private func costs(start: Date, end: Date) async throws -> CostTotals {
        var page: String?
        var totals = CostTotals()

        repeat {
            let response = try await send(
                path: "/v1/organization/costs",
                queryItems: paginationQueryItems(start: start, end: end, page: page)
                    + [URLQueryItem(name: "bucket_width", value: "1d")]
            )
            let decoded = try decode(OpenAICostPage.self, from: response)
            for bucket in decoded.data {
                for result in bucket.results {
                    if let value = result.amount?.value {
                        totals.amount += value
                    }
                    totals.currency = result.amount?.currency ?? totals.currency
                }
            }
            page = decoded.hasMore ? decoded.nextPage : nil
        } while page != nil

        return totals
    }

    private func send(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudUsageClientError.invalidBaseURL
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CloudUsageClientError.invalidBaseURL
        }

        let response = try await transport.data(
            for: CloudUsageHTTPRequest(
                url: url,
                headers: [
                    "Authorization": "Bearer \(adminKey)",
                    "Content-Type": "application/json"
                ]
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw CloudUsageClientError.requestFailed(statusCode: response.statusCode)
        }
        return response.data
    }

    private func paginationQueryItems(start: Date, end: Date, page: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "start_time", value: unixSeconds(start)),
            URLQueryItem(name: "end_time", value: unixSeconds(end)),
            URLQueryItem(name: "limit", value: "180")
        ]
        if let page {
            items.append(URLQueryItem(name: "page", value: page))
        }
        return items
    }
}

public struct AnthropicClaudeCodeAnalyticsClient: Sendable {
    private let adminKey: String
    private let transport: any CloudUsageTransport
    private let baseURL: URL
    private let observedAt: @Sendable () -> Date

    public init(
        adminKey: String,
        transport: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        observedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adminKey = adminKey
        self.transport = transport
        self.baseURL = baseURL
        self.observedAt = observedAt
    }

    public func summary(startingAt day: Date) async throws -> CloudUsageSummary {
        var page: String?
        var totals = UsageTotals()
        var sessionCount = 0
        var cost = CostTotals()

        repeat {
            let response = try await send(startingAt: day, page: page)
            let decoded = try decode(AnthropicClaudeCodeAnalyticsPage.self, from: response)
            for record in decoded.data {
                sessionCount += record.coreMetrics?.numSessions ?? 0
                for model in record.modelBreakdown {
                    totals.inputTokens += model.tokens.input
                    totals.outputTokens += model.tokens.output
                    totals.cachedInputTokens += model.tokens.cacheRead
                    totals.cacheCreationInputTokens += model.tokens.cacheCreation
                    cost.amount += Double(model.estimatedCost.amount) / 100
                    cost.currency = model.estimatedCost.currency
                }
            }
            page = decoded.hasMore ? decoded.nextPage : nil
        } while page != nil

        return CloudUsageSummary(
            provider: .claude,
            source: .anthropicClaudeCodeAnalytics,
            dataKind: .dailyCloudAnalytics,
            observedAt: observedAt(),
            rangeStart: startOfDay(day),
            rangeEnd: Calendar.utc.date(byAdding: .day, value: 1, to: startOfDay(day)) ?? day,
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cachedInputTokens: totals.cachedInputTokens,
            cacheCreationInputTokens: totals.cacheCreationInputTokens,
            sessionCount: sessionCount,
            costAmount: roundedCurrency(cost.amount),
            costCurrency: cost.currency
        )
    }

    private func send(startingAt day: Date, page: String?) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudUsageClientError.invalidBaseURL
        }
        components.path = "/v1/organizations/usage_report/claude_code"
        var queryItems = [
            URLQueryItem(name: "starting_at", value: dayString(day)),
            URLQueryItem(name: "limit", value: "1000")
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CloudUsageClientError.invalidBaseURL
        }

        let response = try await transport.data(
            for: CloudUsageHTTPRequest(
                url: url,
                headers: [
                    "anthropic-version": "2023-06-01",
                    "x-api-key": adminKey,
                    "User-Agent": "Quotakin/1.0"
                ]
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw CloudUsageClientError.requestFailed(statusCode: response.statusCode)
        }
        return response.data
    }
}

private struct UsageTotals {
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var cacheCreationInputTokens = 0
    var requestCount = 0
}

private struct CostTotals {
    var amount = 0.0
    var currency: String?
}

private struct OpenAIUsagePage: Decodable {
    let data: [OpenAIUsageBucket]
    let hasMore: Bool
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAIUsageBucket: Decodable {
    let results: [OpenAIUsageResult]
}

private struct OpenAIUsageResult: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let inputCachedTokens: Int?
    let numModelRequests: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case numModelRequests = "num_model_requests"
    }
}

private struct OpenAICostPage: Decodable {
    let data: [OpenAICostBucket]
    let hasMore: Bool
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAICostBucket: Decodable {
    let results: [OpenAICostResult]
}

private struct OpenAICostResult: Decodable {
    let amount: OpenAICostAmount?
}

private struct OpenAICostAmount: Decodable {
    let value: Double?
    let currency: String?
}

private struct AnthropicClaudeCodeAnalyticsPage: Decodable {
    let data: [AnthropicClaudeCodeAnalyticsRecord]
    let hasMore: Bool
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct AnthropicClaudeCodeAnalyticsRecord: Decodable {
    let coreMetrics: AnthropicCoreMetrics?
    let modelBreakdown: [AnthropicModelBreakdown]

    private enum CodingKeys: String, CodingKey {
        case coreMetrics = "core_metrics"
        case modelBreakdown = "model_breakdown"
    }
}

private struct AnthropicCoreMetrics: Decodable {
    let numSessions: Int

    private enum CodingKeys: String, CodingKey {
        case numSessions = "num_sessions"
    }
}

private struct AnthropicModelBreakdown: Decodable {
    let tokens: AnthropicModelTokens
    let estimatedCost: AnthropicEstimatedCost

    private enum CodingKeys: String, CodingKey {
        case tokens
        case estimatedCost = "estimated_cost"
    }
}

private struct AnthropicModelTokens: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheCreation = "cache_creation"
    }
}

private struct AnthropicEstimatedCost: Decodable {
    let currency: String
    let amount: Int
}

private struct ClaudeOAuthCredentialEnvelope: Codable {
    let claudeAiOauth: ClaudeOAuthCredential
}

private struct CodexAccountCredential: Decodable {
    let tokens: Tokens?

    struct Tokens: Decodable {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

private struct StaticCodexAccountCredentialStore: CodexAccountCredentialStore {
    let accessToken: String

    func loadAccessToken() throws -> String? {
        accessToken
    }
}

private struct CodexJSONRPCRequest: Encodable {
    let id: Int
    let method: String
    var params: JSONValue = .object([:])
}

private struct CodexJSONRPCResponse: Decodable {
    let id: Int?
    let result: Data?
    let error: CodexJSONRPCError?

    private enum CodingKeys: CodingKey {
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(CodexJSONRPCError.self, forKey: .error)
        if container.contains(.result) {
            let value = try container.decode(JSONValue.self, forKey: .result)
            result = try JSONEncoder().encode(value)
        } else {
            result = nil
        }
    }
}

private struct CodexJSONRPCError: Decodable {
    let code: Int
    let message: String
}

private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

private struct CodexAppServerRateLimitsResponse: Decodable {
    let rateLimits: CodexAppServerRateLimitSnapshot
    let rateLimitsByLimitId: [String: CodexAppServerRateLimitSnapshot]?
}

private struct CodexAppServerRateLimitSnapshot: Decodable {
    let primary: CodexAppServerRateLimitWindow?
    let secondary: CodexAppServerRateLimitWindow?
}

private struct CodexAppServerRateLimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: Int?
    let windowDurationMins: Int
}

private struct CodexAccountUsageResponse: Decodable {
    let rateLimit: CodexAccountRateLimit?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct CodexAccountRateLimit: Decodable {
    let primaryWindow: CodexAccountUsageWindow?
    let secondaryWindow: CodexAccountUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexAccountUsageWindow: Decodable {
    let usedPercent: Double
    let resetAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }
}

private struct ClaudeOAuthUsageResponse: Decodable {
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeOAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct ClaudeOAuthTokenRefreshRequest: Encodable {
    let grantType = "refresh_token"
    let refreshToken: String
    let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let scope: String

    private enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case scope
    }
}

private struct ClaudeOAuthTokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    } catch {
        throw CloudUsageClientError.invalidResponse
    }
}

private func unixSeconds(_ date: Date) -> String {
    String(Int(date.timeIntervalSince1970.rounded(.down)))
}

private func roundedCurrency(_ amount: Double) -> Double {
    (amount * 100).rounded() / 100
}

private func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = .utc
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func startOfDay(_ date: Date) -> Date {
    Calendar.utc.startOfDay(for: date)
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

/// Minimal thread-safe latch used for process-lifetime backoff decisions.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        flag = false
    }
}
