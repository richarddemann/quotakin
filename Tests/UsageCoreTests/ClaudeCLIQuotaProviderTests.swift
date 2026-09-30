import Foundation
import Testing
@testable import UsageCore

private struct StubClaudeControlTransport: ClaudeUsageControlTransport {
    let payload: String
    func usage(timeout: TimeInterval) async throws -> Data { Data(payload.utf8) }
}

@Test
func claudeCLIQuotaMapsWeeklyWhenSessionHasNotStarted() async throws {
    let provider = ClaudeCLIQuotaProvider(
        transport: StubClaudeControlTransport(payload: #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":89,"resets_at":"2026-10-01T11:00:00.490875+00:00"},"model_scoped":[{"display_name":"Other","utilization":99,"resets_at":"2026-10-01T11:00:00Z"}]}}"#),
        observedAt: { Date(timeIntervalSince1970: 1_790_683_200) }
    )
    let snapshots = try await provider.quotaSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.window == .weekly)
    #expect(snapshots.first?.usedPercent == 89)
    #expect(snapshots.first?.source == .account)
    #expect(provider.connectionSource == .claudeCLI)
}

@Test
func claudeCLIQuotaFailsClosedForUnavailableAndMalformedPayloads() async {
    for payload in [#"{"rate_limits_available":false,"rate_limits":null}"#, #"{"rate_limits_available":true,"rate_limits":{}}"#] {
        let provider = ClaudeCLIQuotaProvider(transport: StubClaudeControlTransport(payload: payload))
        await #expect(throws: CloudUsageClientError.noUsableQuota) { try await provider.quotaSnapshots() }
    }
    let provider = ClaudeCLIQuotaProvider(transport: StubClaudeControlTransport(payload: "private-error-marker"))
    await #expect(throws: CloudUsageClientError.invalidResponse) { try await provider.quotaSnapshots() }
}

@Test
func claudeControlProcessOnlySendsInitializationAndUsageRequests() async throws {
    let executable = try fakeClaudeControlProcess(mode: "success")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let payload = try await ProcessClaudeUsageControlTransport(executableURL: executable).usage(timeout: 5)
    let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(root["rate_limits_available"] as? Bool == true)
}

@Test
func claudeControlProcessBoundsTimeoutAndSanitizesErrors() async throws {
    for mode in ["hang", "error", "exit"] {
        let executable = try fakeClaudeControlProcess(mode: mode)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = ProcessClaudeUsageControlTransport(executableURL: executable)
        do {
            _ = try await transport.usage(timeout: mode == "hang" ? 0.2 : 5)
            Issue.record("Expected control failure")
        } catch let error as CloudUsageClientError {
            #expect(error == (mode == "hang" ? .timedOut : mode == "exit" ? .clientUnavailable : .invalidResponse))
            #expect(!String(describing: error).contains("private-error-marker"))
        }
    }
}

@Test
func claudeControlProcessCancellationStopsWaiting() async throws {
    let executable = try fakeClaudeControlProcess(mode: "hang")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let task = Task { try await ProcessClaudeUsageControlTransport(executableURL: executable).usage(timeout: 30) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch { }
}

private func fakeClaudeControlProcess(mode: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Quotakin-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "claude")
    let script = """
    #!/usr/bin/env python3
    import json, sys, time
    mode = '\(mode)'
    assert '--no-session-persistence' in sys.argv
    assert '--strict-mcp-config' in sys.argv
    assert sys.argv[sys.argv.index('--tools') + 1] == ''
    for line in sys.stdin:
        req = json.loads(line)
        assert req['type'] == 'control_request'
        subtype = req['request']['subtype']
        assert subtype in ['initialize', 'get_usage']
        if mode == 'hang':
            time.sleep(60)
        if mode == 'exit':
            sys.exit(1)
        print(json.dumps({'type':'system','data':'ignored-notification'}), flush=True)
        response = {'subtype':'success','request_id':req['request_id'],'response':{}}
        if subtype == 'get_usage':
            if mode == 'error':
                response = {'subtype':'error','request_id':req['request_id'],'error':'private-error-marker'}
            else:
                response['response'] = {'rate_limits_available':True,'rate_limits':{}}
        print(json.dumps({'type':'control_response','response':response}), flush=True)
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}
