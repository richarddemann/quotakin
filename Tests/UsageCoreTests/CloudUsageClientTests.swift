import Foundation
import Security
import Testing
@testable import UsageCore

private actor StubCloudUsageTransport: CloudUsageTransport {
    private var responsesByPath: [String: [CloudUsageHTTPResponse]]
    private var capturedRequests: [CloudUsageHTTPRequest] = []

    init(responses: [CloudUsageHTTPResponse]) {
        self.responsesByPath = ["*": responses]
    }

    init(responsesByPath: [String: [CloudUsageHTTPResponse]]) {
        self.responsesByPath = responsesByPath
    }

    func data(for request: CloudUsageHTTPRequest) async throws -> CloudUsageHTTPResponse {
        capturedRequests.append(request)
        let key = responsesByPath[request.url.path] == nil ? "*" : request.url.path
        return responsesByPath[key]!.removeFirst()
    }

    func requests() -> [CloudUsageHTTPRequest] {
        capturedRequests
    }
}

private actor StubCodexAppServerTransport: CodexAppServerTransport {
    enum StubResult: Sendable {
        case success(Data)
        case failure(Error)
    }

    private var resultsByMethod: [String: [StubResult]]
    private var capturedMethods: [String] = []

    init(resultsByMethod: [String: [StubResult]]) {
        self.resultsByMethod = resultsByMethod
    }

    func requests(methods: [String], timeout _: TimeInterval) async throws -> [Data] {
        capturedMethods.append(contentsOf: methods)
        var data: [Data] = []
        for method in methods {
            guard var results = resultsByMethod[method], !results.isEmpty else {
                throw CloudUsageClientError.credentialUnavailable
            }
            let result = results.removeFirst()
            resultsByMethod[method] = results
            switch result {
            case let .success(responseData):
                data.append(responseData)
            case let .failure(error):
                throw error
            }
        }
        return data
    }

    func methods() -> [String] {
        capturedMethods
    }
}

@Test
func openAIOrganizationUsageClientAggregatesTokensAndCosts() async throws {
    let transport = StubCloudUsageTransport(responsesByPath: [
        "/v1/organization/usage/completions": [
            CloudUsageHTTPResponse(
                statusCode: 200,
                data: Data("""
                {
                  "object": "page",
                  "data": [
                    {
                      "object": "bucket",
                      "start_time": 1730419200,
                      "end_time": 1730505600,
                      "results": [
                        {
                          "object": "organization.usage.completions.result",
                          "input_tokens": 100,
                          "input_cached_tokens": 25,
                          "output_tokens": 40,
                          "num_model_requests": 3
                        }
                      ]
                    }
                  ],
                  "has_more": false,
                  "next_page": null
                }
                """.utf8)
            )
        ],
        "/v1/organization/costs": [
            CloudUsageHTTPResponse(
                statusCode: 200,
                data: Data("""
                {
                  "object": "page",
                  "data": [
                    {
                      "object": "bucket",
                      "start_time": 1730419200,
                      "end_time": 1730505600,
                      "results": [
                        {
                          "object": "organization.costs.result",
                          "amount": {"value": 0.06, "currency": "usd"}
                        }
                      ]
                    }
                  ],
                  "has_more": false,
                  "next_page": null
                }
                """.utf8)
            )
        ]
    ])
    let client = OpenAIOrganizationUsageClient(
        adminKey: "sk-admin-redacted",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_730_506_000) }
    )

    let summary = try await client.summary(
        start: Date(timeIntervalSince1970: 1_730_419_200),
        end: Date(timeIntervalSince1970: 1_730_506_000)
    )

    #expect(summary.provider == .codex)
    #expect(summary.source == .openAIOrganizationUsage)
    #expect(summary.inputTokens == 100)
    #expect(summary.cachedInputTokens == 25)
    #expect(summary.outputTokens == 40)
    #expect(summary.requestCount == 3)
    #expect(summary.costAmount == 0.06)
    #expect(summary.costCurrency == "usd")
    #expect(summary.dataKind == .apiPlatformUsage)

    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(Set(requests.map(\.url.path)) == [
        "/v1/organization/usage/completions",
        "/v1/organization/costs"
    ])
    #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk-admin-redacted" })
}

@Test
func anthropicClaudeCodeAnalyticsClientAggregatesDailyModelBreakdown() async throws {
    let transport = StubCloudUsageTransport(responsesByPath: [
        "/v1/organizations/usage_report/claude_code": [
            CloudUsageHTTPResponse(
                statusCode: 200,
                data: Data("""
                {
                  "data": [
                    {
                      "date": "2025-09-08T00:00:00Z",
                      "customer_type": "subscription",
                      "core_metrics": {"num_sessions": 5},
                      "model_breakdown": [
                        {
                          "model": "claude-opus-4-8",
                          "tokens": {
                            "input": 100000,
                            "output": 35000,
                            "cache_read": 10000,
                            "cache_creation": 5000
                          },
                          "estimated_cost": {"currency": "USD", "amount": 1025}
                        }
                      ]
                    }
                  ],
                  "has_more": true,
                  "next_page": "page_2"
                }
                """.utf8)
            ),
            CloudUsageHTTPResponse(
                statusCode: 200,
                data: Data("""
                {
                  "data": [
                    {
                      "date": "2025-09-08T00:00:00Z",
                      "customer_type": "api",
                      "core_metrics": {"num_sessions": 2},
                      "model_breakdown": [
                        {
                          "model": "claude-sonnet-4-6",
                          "tokens": {
                            "input": 200,
                            "output": 100,
                            "cache_read": 50,
                            "cache_creation": 25
                          },
                          "estimated_cost": {"currency": "USD", "amount": 13}
                        }
                      ]
                    }
                  ],
                  "has_more": false,
                  "next_page": null
                }
                """.utf8)
            )
        ]
    ])
    let client = AnthropicClaudeCodeAnalyticsClient(
        adminKey: "sk-ant-admin-redacted",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_730_506_000) }
    )

    let summary = try await client.summary(startingAt: date(year: 2025, month: 9, day: 8))

    #expect(summary.provider == .claude)
    #expect(summary.source == .anthropicClaudeCodeAnalytics)
    #expect(summary.inputTokens == 100_200)
    #expect(summary.outputTokens == 35_100)
    #expect(summary.cachedInputTokens == 10_050)
    #expect(summary.cacheCreationInputTokens == 5_025)
    #expect(summary.sessionCount == 7)
    #expect(summary.costAmount == 10.38)
    #expect(summary.costCurrency == "USD")
    #expect(summary.dataKind == .dailyCloudAnalytics)

    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests[0].url.path == "/v1/organizations/usage_report/claude_code")
    #expect(requests[0].url.queryItems["starting_at"] == "2025-09-08")
    #expect(requests[1].url.queryItems["page"] == "page_2")
    #expect(requests.allSatisfy { $0.headers["x-api-key"] == "sk-ant-admin-redacted" })
    #expect(requests.allSatisfy { $0.headers["anthropic-version"] == "2023-06-01" })
}

@Test
func claudeOAuthUsageClientMapsCurrentLimitWindows() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 200,
            data: Data("""
            {
              "five_hour": {
                "utilization": 31.5,
                "resets_at": "2026-06-22T19:49:00.125Z"
              },
              "seven_day": {
                "utilization": 40.25,
                "resets_at": "2026-06-23T01:00:00.500Z"
              },
              "seven_day_opus": {
                "utilization": 72,
                "resets_at": "2026-06-23T01:00:00Z"
              },
              "seven_day_omelette": {
                "utilization": 58,
                "resets_at": "2026-06-25T01:00:00Z"
              }
            }
            """.utf8)
        )
    ])
    let client = ClaudeOAuthUsageClient(
        accessToken: "claude-access-redacted",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) },
        userAgent: "claude-code/2.1.210"
    )

    let snapshots = try await client.quotaSnapshots()

    #expect(snapshots.count == 2)
    #expect(snapshots[0].provider == .claude)
    #expect(snapshots[0].window == .session)
    #expect(snapshots[0].usedPercent == 31.5)
    #expect(snapshots[0].resetsAt == isoDate("2026-06-22T19:49:00.125Z"))
    #expect(snapshots[0].observedAt == Date(timeIntervalSince1970: 1_782_150_000))
    #expect(snapshots[1].provider == .claude)
    #expect(snapshots[1].window == .weekly)
    #expect(snapshots[1].usedPercent == 40.25)
    #expect(snapshots[1].resetsAt == isoDate("2026-06-23T01:00:00.500Z"))

    let requests = await transport.requests()
    #expect(requests.count == 1)
    #expect(requests[0].url.path == "/api/oauth/usage")
    #expect(requests[0].headers["Authorization"] == "Bearer claude-access-redacted")
    #expect(requests[0].headers["anthropic-beta"] == "oauth-2025-04-20")
    #expect(requests[0].headers["User-Agent"] == "claude-code/2.1.210")
}

@Test
func claudeOAuthUsageClientDoesNotPromoteScopedLimitsToAccountWeeklyQuota() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 200,
            data: Data("""
            {
              "five_hour": {
                "utilization": 12.5,
                "resets_at": "2026-06-22T19:49:00Z"
              },
              "seven_day": null,
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "group": "weekly",
                  "percent": 91.75,
                  "resets_at": "2026-06-23T01:00:00.250Z",
                  "scope": {
                    "model": {"id": "claude-opus", "display_name": "Opus"}
                  },
                  "is_active": false
                }
              ]
            }
            """.utf8)
        )
    ])
    let client = ClaudeOAuthUsageClient(
        accessToken: "claude-access-redacted",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    let snapshots = try await client.quotaSnapshots()

    #expect(snapshots.map(\.window) == [.session])
    #expect(snapshots.map(\.usedPercent) == [12.5])
}

@Test
func claudeOAuthUsageClientSkipsNullableWindowsIndependently() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 200,
            data: Data("""
            {
              "five_hour": {"utilization": null, "resets_at": null},
              "seven_day": {
                "utilization": 8.25,
                "resets_at": "2026-06-23T01:00:00.125Z"
              },
              "limits": null
            }
            """.utf8)
        )
    ])
    let client = ClaudeOAuthUsageClient(
        accessToken: "claude-access-redacted",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    let snapshots = try await client.quotaSnapshots()

    #expect(snapshots.map(\.window) == [.weekly])
    #expect(snapshots.map(\.usedPercent) == [8.25])
    #expect(snapshots[0].resetsAt == isoDate("2026-06-23T01:00:00.125Z"))
}

@Test
func claudeOAuthUsageClientRejectsResponseWithoutUsableCurrentQuota() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 200,
            data: Data("""
            {
              "five_hour": {"utilization": null, "resets_at": null},
              "seven_day": null,
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "group": "weekly",
                  "percent": 94,
                  "scope": {"model": {"id": "claude-opus"}}
                }
              ]
            }
            """.utf8)
        )
    ])
    let client = ClaudeOAuthUsageClient(
        accessToken: "private-access-marker",
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    await #expect(throws: CloudUsageClientError.noUsableQuota) {
        _ = try await client.quotaSnapshots()
    }
}

@Test
func claudeCredentialShapeDetectsMCPOnlyPayloadWithoutReadingSecrets() {
    let payload = Data(#"{"mcpOAuth":{"accessToken":"private-marker"}}"#.utf8)
    let regular = Data(#"{"claudeAiOauth":{"accessToken":"private-marker"}}"#.utf8)

    #expect(ClaudeCodeCredentialStore.isMCPOnlyCredentialPayload(payload))
    #expect(!ClaudeCodeCredentialStore.isMCPOnlyCredentialPayload(regular))
    #expect(!ClaudeCodeCredentialStore.isMCPOnlyCredentialPayload(Data("private-marker".utf8)))
}

@Test
func claudeOAuthQuotaProviderReportsMCPOnlyCredentialState() async throws {
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: InMemoryClaudeOAuthCredentialStore(
            credentials: [],
            mcpOnlyCredentialDetected: true
        ),
        transport: StubCloudUsageTransport(responses: [])
    )

    await #expect(throws: CloudUsageClientError.mcpOnlyCredential) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func claudeOAuthUsageClientReportsRetryAfterWithoutExposingResponseBody() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 429,
            data: Data(#"{"secret":"private-marker"}"#.utf8),
            headers: ["retry-after": "300"]
        )
    ])
    let client = ClaudeOAuthUsageClient(
        accessToken: "private-access-marker",
        transport: transport,
        observedAt: { now }
    )

    do {
        _ = try await client.quotaSnapshots()
        Issue.record("Expected a rate-limit response")
    } catch let error as CloudUsageClientError {
        #expect(error == .rateLimited(retryAfter: now.addingTimeInterval(300)))
        #expect(!String(describing: error).contains("private-marker"))
        #expect(!String(describing: error).contains("private-access-marker"))
    }
}

@Test
func claudeOAuthCredentialDecodingAcceptsMissingOptionalMetadata() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    let credential = try decoder.decode(
        ClaudeOAuthCredential.self,
        from: Data(#"{"accessToken":"access-redacted","scopes":null}"#.utf8)
    )

    #expect(credential.accessToken == "access-redacted")
    #expect(credential.refreshToken == nil)
    #expect(credential.expiresAt == nil)
    #expect(credential.scopes.isEmpty)
    #expect(credential.subscriptionType == nil)
    #expect(credential.rateLimitTier == nil)
}

@Test
func claudeCodeUserAgentDetectsVersionAndFallsBackSafely() {
    #expect(
        ClaudeCodeUserAgent.resolving(versionOutput: "2.1.210 (Claude Code)\n")
            == "claude-code/2.1.210"
    )
    #expect(ClaudeCodeUserAgent.resolving(versionOutput: nil) == "claude-code/2.1.0")
    #expect(ClaudeCodeUserAgent.resolving(versionOutput: "unexpected") == "claude-code/2.1.0")

    let candidates = [
        URL(fileURLWithPath: "/missing/claude"),
        URL(fileURLWithPath: "/found/claude")
    ]
    #expect(
        ClaudeCodeUserAgent.discoverExecutable(
            candidates: candidates,
            isExecutable: { $0 == "/found/claude" }
        )?.path == "/found/claude"
    )
}

@Test
func codexAccountQuotaProviderMapsLiveAccountWindows() async throws {
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [
            .success(Data("""
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 62, "resetsAt": 1784529454, "windowDurationMins": 10080},
                "secondary": null
              }
            }
            """.utf8))
        ]
    ])
    let provider = CodexAccountQuotaProvider(
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_783_700_000) }
    )

    let snapshots = try await provider.quotaSnapshots()

    #expect(snapshots.map(\.window) == [.weekly])
    #expect(snapshots.map(\.usedPercent) == [62])
    #expect(snapshots.allSatisfy { $0.source == .account })
    #expect(snapshots[0].resetsAt == Date(timeIntervalSince1970: 1_784_529_454))

    #expect(await transport.methods() == ["account/rateLimits/read"])
}

@Test
func codexAppServerTransportUsesNDJSONInitializeAndSkipsNotifications() async throws {
    let executable = try fakeCodexAppServerExecutable()
    let transport = ProcessCodexAppServerTransport(executableURL: executable, arguments: [])
    let provider = CodexAccountQuotaProvider(
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_783_700_000) }
    )

    let snapshots = try await provider.quotaSnapshots()

    #expect(snapshots.map(\.window) == [.weekly])
    #expect(snapshots.map(\.usedPercent) == [62])
    #expect(snapshots[0].resetsAt == Date(timeIntervalSince1970: 1_784_529_454))
}

@Test
func codexAccountQuotaProviderReportsUnavailableWhenBinaryMissing() async throws {
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [.failure(CloudUsageClientError.clientUnavailable)]
    ])
    let provider = CodexAccountQuotaProvider(transport: transport)

    await #expect(throws: CloudUsageClientError.clientUnavailable) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func codexAccountQuotaProviderReportsUnavailableOnTimeout() async throws {
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [.failure(CloudUsageClientError.timedOut)]
    ])
    let provider = CodexAccountQuotaProvider(transport: transport, timeout: 0.01)

    await #expect(throws: CloudUsageClientError.timedOut) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func codexAccountQuotaProviderRejectsMalformedRateLimitsResponse() async throws {
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [.success(Data(#"{"rateLimits":{"primary":{"usedPercent":"bad"}}}"#.utf8))]
    ])
    let provider = CodexAccountQuotaProvider(transport: transport)

    await #expect(throws: CloudUsageClientError.invalidResponse) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func codexAccountQuotaProviderRejectsResponseWithoutUsableWindows() async throws {
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [
            .success(Data(#"{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}"#.utf8))
        ]
    ])
    let provider = CodexAccountQuotaProvider(transport: transport)

    await #expect(throws: CloudUsageClientError.noUsableQuota) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func codexAccountQuotaProviderRejectsExpiredOnlyWindows() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_783_700_000)
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [
            .success(Data("""
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 20, "resetsAt": 1783700000, "windowDurationMins": 300},
                "secondary": {"usedPercent": 30, "resetsAt": 1783699999, "windowDurationMins": 10080}
              }
            }
            """.utf8))
        ]
    ])
    let provider = CodexAccountQuotaProvider(
        transport: transport,
        observedAt: { observedAt }
    )

    await #expect(throws: CloudUsageClientError.noUsableQuota) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func codexAccountQuotaProviderKeepsFutureWindowWhenAnotherIsExpired() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_783_700_000)
    let transport = StubCodexAppServerTransport(resultsByMethod: [
        "account/rateLimits/read": [
            .success(Data("""
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 20, "resetsAt": 1783700000, "windowDurationMins": 300},
                "secondary": {"usedPercent": 30, "resetsAt": 1783703600, "windowDurationMins": 10080}
              }
            }
            """.utf8))
        ]
    ])
    let provider = CodexAccountQuotaProvider(
        transport: transport,
        observedAt: { observedAt }
    )

    let snapshots = try await provider.quotaSnapshots()

    #expect(snapshots.map(\.window) == [.weekly])
    #expect(snapshots.map(\.usedPercent) == [30])
}

@Test
func urlSessionCloudUsageTransportDefaultsToThirtySecondRequests() {
    let request = CloudUsageHTTPRequest(
        url: URL(string: "https://example.invalid/usage")!,
        headers: [:]
    )
    let transport = URLSessionCloudUsageTransport()

    #expect(transport.urlRequest(for: request).timeoutInterval == 30)
}

@Test
func claudeOAuthQuotaProviderDoesNotRefreshExpiredCredential() async throws {
    let store = InMemoryClaudeOAuthCredentialStore(
        credential: ClaudeOAuthCredential(
            accessToken: "old-access-redacted",
            refreshToken: "old-refresh-redacted",
            expiresAt: Date(timeIntervalSince1970: 1_782_149_000),
            scopes: [
                "user:profile",
                "user:inference",
                "user:sessions:claude_code",
                "user:mcp_servers",
                "user:file_upload"
            ],
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    )
    let transport = StubCloudUsageTransport(responsesByPath: [
        "/v1/oauth/token": [
            CloudUsageHTTPResponse(
                statusCode: 401,
                data: Data("unexpected refresh".utf8)
            )
        ],
        "/api/oauth/usage": [
            CloudUsageHTTPResponse(
                statusCode: 200,
                data: Data("""
                {
                  "five_hour": {
                    "utilization": 12,
                    "resets_at": "2026-06-22T19:49:00Z"
                  },
                  "seven_day": {
                    "utilization": 42,
                    "resets_at": "2026-06-23T01:00:00Z"
                  }
                }
                """.utf8)
            )
        ]
    ])
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: store,
        transport: transport,
        usageBaseURL: URL(string: "https://api.anthropic.com")!,
        tokenBaseURL: URL(string: "https://platform.claude.com")!,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    do {
        _ = try await provider.quotaSnapshots()
        Issue.record("Expected expired credential to require a later read-only retry.")
    } catch let error as CloudUsageClientError {
        #expect(error == .credentialExpired)
    }
    let requests = await transport.requests()
    #expect(requests.isEmpty)
}

@Test
func claudeOAuthQuotaProviderRejectsCredentialsWithoutProfileScopeBeforeNetworkAccess() async throws {
    let store = InMemoryClaudeOAuthCredentialStore(
        credential: ClaudeOAuthCredential(
            accessToken: "access-redacted",
            refreshToken: "refresh-redacted",
            expiresAt: Date(timeIntervalSince1970: 1_782_151_000),
            scopes: ["user:inference"],
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    )
    let transport = StubCloudUsageTransport(responses: [])
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: store,
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    await #expect(throws: CloudUsageClientError.insufficientScope) {
        _ = try await provider.quotaSnapshots()
    }
    #expect(await transport.requests().isEmpty)
}

@Test
func claudeCredentialServiceDiscoveryPrefersNewestMatchingService() {
    let old = Date(timeIntervalSince1970: 100)
    let current = Date(timeIntervalSince1970: 200)

    #expect(ClaudeCodeCredentialStore.prioritizedCredentialServices([
        "Unrelated-credentials": Date(timeIntervalSince1970: 300),
        "Claude Code-credentials": old,
        "Claude Code-credentials-account-hash": current
    ]) == [
        "Claude Code-credentials-account-hash",
        "Claude Code-credentials"
    ])
}

@Test
func claudeOAuthQuotaProviderTriesAnotherCredentialAfterAnExpiredCandidate() async throws {
    let expired = ClaudeOAuthCredential(
        accessToken: "expired-redacted",
        refreshToken: "refresh-redacted",
        expiresAt: Date(timeIntervalSince1970: 1_782_149_000),
        scopes: ["user:profile"],
        subscriptionType: "pro",
        rateLimitTier: nil
    )
    let current = ClaudeOAuthCredential(
        accessToken: "current-redacted",
        refreshToken: "refresh-redacted",
        expiresAt: Date(timeIntervalSince1970: 1_782_151_000),
        scopes: ["user:profile"],
        subscriptionType: "pro",
        rateLimitTier: nil
    )
    let store = InMemoryClaudeOAuthCredentialStore(credentials: [expired, current])
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(
            statusCode: 200,
            data: Data(#"{"five_hour":{"utilization":12,"resets_at":"2026-06-22T19:49:00Z"}}"#.utf8)
        )
    ])
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: store,
        transport: transport,
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    let snapshots = try await provider.quotaSnapshots()
    #expect(snapshots.count == 1)
    #expect(await transport.requests().first?.headers["Authorization"] == "Bearer current-redacted")
}

@Test
func claudeOAuthQuotaProviderPrefersGrantAccessWhenReadableCandidatesFailAndKeychainWasDenied() async throws {
    let expired = ClaudeOAuthCredential(
        accessToken: "expired-redacted",
        refreshToken: "refresh-redacted",
        expiresAt: Date(timeIntervalSince1970: 1_782_149_000),
        scopes: ["user:profile"],
        subscriptionType: "pro",
        rateLimitTier: nil
    )
    let store = InMemoryClaudeOAuthCredentialStore(
        credentials: [expired],
        keychainAccessDenied: true
    )
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: store,
        transport: StubCloudUsageTransport(responses: []),
        observedAt: { Date(timeIntervalSince1970: 1_782_150_000) }
    )

    await #expect(throws: CloudUsageClientError.credentialAccessDenied) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func claudeOAuthQuotaProviderPrioritizesKeychainDenialOverMCPOnlyCandidate() async throws {
    let store = InMemoryClaudeOAuthCredentialStore(
        credentials: [],
        keychainAccessDenied: true,
        mcpOnlyCredentialDetected: true
    )
    let provider = ClaudeCodeOAuthQuotaProvider(
        credentialStore: store,
        transport: StubCloudUsageTransport(responses: [])
    )

    await #expect(throws: CloudUsageClientError.credentialAccessDenied) {
        _ = try await provider.quotaSnapshots()
    }
}

@Test
func claudeCredentialAccessRecognizesNonInteractiveKeychainDenial() {
    #expect(ClaudeCodeCredentialStore.isCredentialAccessDeniedStatus(errSecAuthFailed))
    #expect(ClaudeCodeCredentialStore.isCredentialAccessDeniedStatus(errSecUserCanceled))
    #expect(ClaudeCodeCredentialStore.isCredentialAccessDeniedStatus(errSecInteractionNotAllowed))
    #expect(!ClaudeCodeCredentialStore.isCredentialAccessDeniedStatus(errSecItemNotFound))
}

@Test
func cloudUsageClientErrorsDoNotExposeAPIKeys() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(statusCode: 401, data: Data("unauthorized".utf8))
    ])
    let client = AnthropicClaudeCodeAnalyticsClient(
        adminKey: "sk-ant-private-marker",
        transport: transport
    )

    do {
        _ = try await client.summary(startingAt: date(year: 2025, month: 9, day: 8))
        Issue.record("Expected a request failure")
    } catch let error as CloudUsageClientError {
        #expect(error == .requestFailed(statusCode: 401))
        #expect(!String(describing: error).contains("sk-ant-private-marker"))
    }
}

@Test
func cloudUsageClientRejectsMalformedJSON() async throws {
    let transport = StubCloudUsageTransport(responses: [
        CloudUsageHTTPResponse(statusCode: 200, data: Data("{".utf8))
    ])
    let client = AnthropicClaudeCodeAnalyticsClient(
        adminKey: "sk-ant-admin-redacted",
        transport: transport
    )

    do {
        _ = try await client.summary(startingAt: date(year: 2025, month: 9, day: 8))
        Issue.record("Expected an invalid response failure")
    } catch let error as CloudUsageClientError {
        #expect(error == .invalidResponse)
    }
}

private func date(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}

private func fakeCodexAppServerExecutable() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("fake-codex-app-server.py")
    let script = #"""
#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    if line.startswith("Content-Length:"):
        print("content-length frame received", file=sys.stderr)
        sys.exit(2)
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        client_info = request.get("params", {}).get("clientInfo", {})
        if not all(client_info.get(key) for key in ["name", "title", "version"]):
            print("missing clientInfo", file=sys.stderr)
            sys.exit(3)
        print(json.dumps({"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{"connected":True}}), flush=True)
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":{"protocolVersion":"2026-07-13"}}), flush=True)
    elif method == "account/read":
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":{"requiresOpenaiAuth":False,"account":{"type":"chatgpt","email":"redacted@example.com","planType":"plus"}}}), flush=True)
    elif method == "account/rateLimits/read":
        print(json.dumps({"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{"connected":True}}), flush=True)
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1784529454},"secondary":None,"credits":{"used":0},"planType":"plus"}}}), flush=True)
    else:
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"error":{"code":-32601,"message":"method not found"}}), flush=True)
"""#
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private actor InMemoryClaudeOAuthCredentialStore: ClaudeOAuthCredentialStore {
    private var credentials: [ClaudeOAuthCredential]
    private let keychainAccessDenied: Bool
    private let mcpOnlyCredentialDetected: Bool

    init(credential: ClaudeOAuthCredential?) {
        self.credentials = credential.map { [$0] } ?? []
        self.keychainAccessDenied = false
        self.mcpOnlyCredentialDetected = false
    }

    init(
        credentials: [ClaudeOAuthCredential],
        keychainAccessDenied: Bool = false,
        mcpOnlyCredentialDetected: Bool = false
    ) {
        self.credentials = credentials
        self.keychainAccessDenied = keychainAccessDenied
        self.mcpOnlyCredentialDetected = mcpOnlyCredentialDetected
    }

    func loadCredentials() async throws -> ClaudeOAuthCredentialLoadResult {
        ClaudeOAuthCredentialLoadResult(
            credentials: credentials,
            keychainAccessDenied: keychainAccessDenied,
            mcpOnlyCredentialDetected: mcpOnlyCredentialDetected
        )
    }

}

private extension URL {
    var queryItems: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value
            } ?? [:]
    }
}
