import Foundation
import Testing
@testable import UsageCore

private enum StubStatusError: Error {
    case failed
}

private actor StubStatusTransport: CloudUsageTransport {
    private let responses: [String: Result<CloudUsageHTTPResponse, Error>]
    private var requestedPaths: [String] = []

    init(responses: [String: Result<CloudUsageHTTPResponse, Error>]) {
        self.responses = responses
    }

    func data(for request: CloudUsageHTTPRequest) async throws -> CloudUsageHTTPResponse {
        requestedPaths.append(request.url.path)
        guard let result = responses[request.url.path] else {
            throw StubStatusError.failed
        }
        return try result.get()
    }

    func paths() -> [String] {
        requestedPaths
    }
}

private final class StubProviderStatusCancellation: RefreshCancellation, @unchecked Sendable {
    func cancel() {}
}

private final class StubProviderStatusScheduler: RefreshScheduling, @unchecked Sendable {
    struct Entry: Sendable {
        let delay: TimeInterval
        let repeatingInterval: TimeInterval?
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval,
        repeatingEvery repeatingInterval: TimeInterval?,
        operation: @escaping @Sendable () -> Void
    ) -> any RefreshCancellation {
        lock.withLock {
            entries.append(Entry(delay: delay, repeatingInterval: repeatingInterval, operation: operation))
        }
        return StubProviderStatusCancellation()
    }

    func entriesSnapshot() -> [Entry] {
        lock.withLock { entries }
    }
}

@Test
func providerStatusPollerMapsStatusIndicatorsAndExtractsIncidentTitle() async throws {
    let endpoint = endpoint(provider: .claude)
    let fetchedAt = Date(timeIntervalSinceReferenceDate: 10)
    let transport = StubStatusTransport(responses: [
        "/api/v2/status.json": .success(jsonResponse("""
        {"status":{"indicator":"minor","description":"Partial System Outage"}}
        """)),
        "/api/v2/incidents/unresolved.json": .success(jsonResponse("""
        {"incidents":[{"name":"Messages are delayed","status":"investigating","shortlink":"https://stspg.io/example"}]}
        """))
    ])
    let poller = ProviderStatusPoller(
        endpoints: [endpoint],
        transport: transport,
        scheduler: StubProviderStatusScheduler(),
        interval: 600,
        now: { fetchedAt }
    )

    await poller.pollIfDue()

    let status = await poller.status(for: .claude)
    #expect(status.indicator == .minor)
    #expect(status.incident?.title == "Messages are delayed")
    #expect(status.incident?.shortlink == URL(string: "https://stspg.io/example"))
    #expect(status.fetchedAt == fetchedAt)
}

@Test
func providerStatusPollerMapsMajorAndNoCurrentIncident() async throws {
    let endpoint = endpoint(provider: .codex, incidentsPath: "/api/v2/incidents.json")
    let transport = StubStatusTransport(responses: [
        "/api/v2/status.json": .success(jsonResponse("""
        {"status":{"indicator":"major"}}
        """)),
        "/api/v2/incidents.json": .success(jsonResponse("""
        {"incidents":[{"name":"Resolved issue","status":"resolved","shortlink":"https://stspg.io/resolved"}]}
        """))
    ])
    let poller = ProviderStatusPoller(
        endpoints: [endpoint],
        transport: transport,
        scheduler: StubProviderStatusScheduler()
    )

    await poller.pollIfDue()

    let status = await poller.status(for: .codex)
    #expect(status.indicator == .major)
    #expect(status.incident == nil)
}

@Test
func providerStatusPollerMapsNoneWithoutIncident() async throws {
    let endpoint = endpoint(provider: .claude)
    let transport = StubStatusTransport(responses: [
        "/api/v2/status.json": .success(jsonResponse("""
        {"status":{"indicator":"none"}}
        """)),
        "/api/v2/incidents/unresolved.json": .success(jsonResponse("""
        {"incidents":[]}
        """))
    ])
    let poller = ProviderStatusPoller(
        endpoints: [endpoint],
        transport: transport,
        scheduler: StubProviderStatusScheduler()
    )

    await poller.pollIfDue()

    let status = await poller.status(for: .claude)
    #expect(status.indicator == .none)
    #expect(status.incident == nil)
}

@Test
func providerStatusPollerTreatsUnreachableFeedAsUnknown() async throws {
    let endpoint = endpoint(provider: .claude)
    let fetchedAt = Date(timeIntervalSinceReferenceDate: 20)
    let transport = StubStatusTransport(responses: [
        "/api/v2/status.json": .failure(StubStatusError.failed),
        "/api/v2/incidents/unresolved.json": .success(jsonResponse("""
        {"incidents":[]}
        """))
    ])
    let poller = ProviderStatusPoller(
        endpoints: [endpoint],
        transport: transport,
        scheduler: StubProviderStatusScheduler(),
        now: { fetchedAt }
    )

    await poller.pollIfDue()

    let status = await poller.status(for: .claude)
    #expect(status.indicator == .unknown)
    #expect(status.incident == nil)
    #expect(status.fetchedAt == fetchedAt)
}

@Test
func providerStatusPollerGatesCadence() async throws {
    let first = Date(timeIntervalSinceReferenceDate: 100)
    #expect(ProviderStatusPoller.shouldPoll(lastPollAt: nil, now: first, interval: 600))
    #expect(!ProviderStatusPoller.shouldPoll(lastPollAt: first, now: first.addingTimeInterval(599), interval: 600))
    #expect(ProviderStatusPoller.shouldPoll(lastPollAt: first, now: first.addingTimeInterval(600), interval: 600))
}

@Test
func providerStatusPollerStartSchedulesSlowRepeatingTimer() async throws {
    let endpoint = endpoint(provider: .claude)
    let scheduler = StubProviderStatusScheduler()
    let transport = StubStatusTransport(responses: [
        "/api/v2/status.json": .success(jsonResponse("""
        {"status":{"indicator":"none"}}
        """)),
        "/api/v2/incidents/unresolved.json": .success(jsonResponse("""
        {"incidents":[]}
        """))
    ])
    let poller = ProviderStatusPoller(
        endpoints: [endpoint],
        transport: transport,
        scheduler: scheduler,
        interval: 900
    )

    await poller.start()

    let entries = scheduler.entriesSnapshot()
    #expect(entries.count == 1)
    #expect(entries.first?.delay == 900)
    #expect(entries.first?.repeatingInterval == 900)
}

private func endpoint(
    provider: Provider,
    incidentsPath: String = "/api/v2/incidents/unresolved.json"
) -> ProviderStatusEndpoint {
    ProviderStatusEndpoint(
        provider: provider,
        statusURL: URL(string: "https://example.test/api/v2/status.json")!,
        incidentsURL: URL(string: "https://example.test\(incidentsPath)")!
    )
}

private func jsonResponse(_ json: String) -> CloudUsageHTTPResponse {
    CloudUsageHTTPResponse(statusCode: 200, data: Data(json.utf8))
}
