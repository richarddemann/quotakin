import Foundation

public enum ProviderStatusIndicator: String, Codable, Sendable {
    case unknown
    case none
    case minor
    case major
    case critical
}

public struct ProviderIncident: Codable, Equatable, Sendable {
    public let title: String
    public let shortlink: URL?

    public init(title: String, shortlink: URL?) {
        self.title = title
        self.shortlink = shortlink
    }
}

public struct ProviderStatus: Codable, Equatable, Sendable {
    public let indicator: ProviderStatusIndicator
    public let incident: ProviderIncident?
    public let fetchedAt: Date?

    public init(
        indicator: ProviderStatusIndicator,
        incident: ProviderIncident?,
        fetchedAt: Date?
    ) {
        self.indicator = indicator
        self.incident = incident
        self.fetchedAt = fetchedAt
    }

    public static let unknown = ProviderStatus(
        indicator: .unknown,
        incident: nil,
        fetchedAt: nil
    )
}

public struct ProviderStatusEndpoint: Sendable {
    public let provider: Provider
    public let statusURL: URL
    public let incidentsURL: URL

    public init(
        provider: Provider,
        statusURL: URL,
        incidentsURL: URL
    ) {
        self.provider = provider
        self.statusURL = statusURL
        self.incidentsURL = incidentsURL
    }

    public static let live: [ProviderStatusEndpoint] = [
        ProviderStatusEndpoint(
            provider: .claude,
            statusURL: URL(string: "https://status.claude.com/api/v2/status.json")!,
            incidentsURL: URL(string: "https://status.claude.com/api/v2/incidents/unresolved.json")!
        ),
        ProviderStatusEndpoint(
            provider: .codex,
            statusURL: URL(string: "https://status.openai.com/api/v2/status.json")!,
            incidentsURL: URL(string: "https://status.openai.com/api/v2/incidents.json")!
        )
    ]
}

public actor ProviderStatusPoller {
    public static let defaultInterval: TimeInterval = 900

    private let endpoints: [ProviderStatusEndpoint]
    private let transport: any CloudUsageTransport
    private let scheduler: any RefreshScheduling
    private let interval: TimeInterval
    private let now: @Sendable () -> Date

    private var statuses: [Provider: ProviderStatus]
    private var timer: (any RefreshCancellation)?
    private var lastPollAt: Date?
    private var observer: (@Sendable () async -> Void)?

    public init(
        endpoints: [ProviderStatusEndpoint] = ProviderStatusEndpoint.live,
        transport: any CloudUsageTransport = URLSessionCloudUsageTransport(),
        scheduler: any RefreshScheduling = DispatchRefreshScheduler(),
        interval: TimeInterval = ProviderStatusPoller.defaultInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpoints = endpoints
        self.transport = transport
        self.scheduler = scheduler
        self.interval = interval
        self.now = now
        statuses = Dictionary(
            uniqueKeysWithValues: endpoints.map { ($0.provider, ProviderStatus.unknown) }
        )
    }

    deinit {
        timer?.cancel()
    }

    public func start() async {
        timer?.cancel()
        timer = scheduler.schedule(after: interval, repeatingEvery: interval) { [weak self] in
            Task {
                await self?.pollFromTimer()
            }
        }
        await pollIfDue(force: true)
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func setObserver(_ observer: (@Sendable () async -> Void)?) {
        self.observer = observer
    }

    public func currentStatuses() -> [Provider: ProviderStatus] {
        statuses
    }

    public func status(for provider: Provider) -> ProviderStatus {
        statuses[provider] ?? .unknown
    }

    public func pollIfDue(force: Bool = false) async {
        let pollDate = now()
        guard force || Self.shouldPoll(lastPollAt: lastPollAt, now: pollDate, interval: interval) else {
            return
        }
        lastPollAt = pollDate

        var nextStatuses: [Provider: ProviderStatus] = [:]
        for endpoint in endpoints {
            nextStatuses[endpoint.provider] = await fetchStatus(endpoint: endpoint, fetchedAt: pollDate)
        }
        statuses = nextStatuses
        await observer?()
    }

    public static func shouldPoll(
        lastPollAt: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard let lastPollAt else {
            return true
        }
        return now.timeIntervalSince(lastPollAt) >= interval
    }

    private func pollFromTimer() async {
        await pollIfDue()
    }

    private func fetchStatus(
        endpoint: ProviderStatusEndpoint,
        fetchedAt: Date
    ) async -> ProviderStatus {
        do {
            async let statusResponse = transport.data(
                for: CloudUsageHTTPRequest(url: endpoint.statusURL, headers: [:])
            )
            async let incidentsResponse = transport.data(
                for: CloudUsageHTTPRequest(url: endpoint.incidentsURL, headers: [:])
            )
            let (status, incidents) = try await (statusResponse, incidentsResponse)
            guard status.statusCode == 200, incidents.statusCode == 200 else {
                return ProviderStatus(indicator: .unknown, incident: nil, fetchedAt: fetchedAt)
            }

            let statusEnvelope = try JSONDecoder().decode(StatuspageStatusEnvelope.self, from: status.data)
            let incidentsEnvelope = try JSONDecoder().decode(StatuspageIncidentsEnvelope.self, from: incidents.data)
            let currentIncident = incidentsEnvelope.currentIncident()

            return ProviderStatus(
                indicator: statusEnvelope.status.indicator.providerStatusIndicator,
                incident: currentIncident.map {
                    ProviderIncident(title: $0.name, shortlink: $0.resolvedShortlink)
                },
                fetchedAt: fetchedAt
            )
        } catch {
            return ProviderStatus(indicator: .unknown, incident: nil, fetchedAt: fetchedAt)
        }
    }
}

private struct StatuspageStatusEnvelope: Decodable {
    let status: Status

    struct Status: Decodable {
        let indicator: String
    }
}

private struct StatuspageIncidentsEnvelope: Decodable {
    let incidents: [Incident]

    func currentIncident() -> Incident? {
        incidents.first { incident in
            incident.isUnresolved
        }
    }
}

private struct Incident: Decodable {
    let name: String
    let status: String?
    let shortlink: String?

    var isUnresolved: Bool {
        status != "resolved"
    }

    var resolvedShortlink: URL? {
        shortlink.flatMap(URL.init(string:))
    }
}

private extension String {
    var providerStatusIndicator: ProviderStatusIndicator {
        switch lowercased() {
        case "none":
            return .none
        case "minor":
            return .minor
        case "major":
            return .major
        case "critical":
            return .critical
        default:
            return .unknown
        }
    }
}
