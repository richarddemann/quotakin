import Foundation
import Testing
@testable import UsageCore

private enum StubError: Error {
    case failed
}

private actor StubCollector: UsageCollector {
    nonisolated let provider: Provider
    nonisolated let sourceDirectories: [URL]
    private var results: [Result<CollectorBatch, Error>]
    private var callCount = 0

    init(
        provider: Provider = .claude,
        sourceDirectories: [URL] = [],
        results: [Result<CollectorBatch, Error>]
    ) {
        self.provider = provider
        self.sourceDirectories = sourceDirectories
        self.results = results
    }

    func collect() async throws -> CollectorBatch {
        callCount += 1
        return try results.removeFirst().get()
    }

    func calls() -> Int {
        callCount
    }
}

private actor StubAccountQuotaProvider: AccountQuotaProvider {
    nonisolated let provider: Provider
    nonisolated let minimumRefreshInterval: TimeInterval
    private let snapshots: [QuotaSnapshot]
    private var callCount = 0

    init(
        provider: Provider,
        snapshots: [QuotaSnapshot],
        minimumRefreshInterval: TimeInterval = 0
    ) {
        self.provider = provider
        self.snapshots = snapshots
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        callCount += 1
        return snapshots
    }

    func calls() -> Int {
        callCount
    }
}

private struct FailingAccountQuotaProvider: AccountQuotaProvider {
    let provider: Provider
    let error: CloudUsageClientError

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        throw error
    }
}

private actor CountingFailingAccountQuotaProvider: AccountQuotaProvider {
    nonisolated let provider: Provider
    private let error: CloudUsageClientError
    private var callCount = 0

    init(provider: Provider, error: CloudUsageClientError) {
        self.provider = provider
        self.error = error
    }

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        callCount += 1
        throw error
    }

    func calls() -> Int {
        callCount
    }
}

private actor SequencedAccountQuotaProvider: AccountQuotaProvider {
    nonisolated let provider: Provider
    nonisolated let minimumRefreshInterval: TimeInterval
    private var results: [Result<[QuotaSnapshot], Error>]
    private var callCount = 0

    init(
        provider: Provider,
        minimumRefreshInterval: TimeInterval = 0,
        results: [Result<[QuotaSnapshot], Error>]
    ) {
        self.provider = provider
        self.minimumRefreshInterval = minimumRefreshInterval
        self.results = results
    }

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        callCount += 1
        return try results.removeFirst().get()
    }

    func calls() -> Int { callCount }
}

private actor SequencedCodexTransport: CodexAppServerTransport {
    private var responses: [Data]
    private var callCount = 0

    init(responses: [Data]) {
        self.responses = responses
    }

    func requests(methods: [String], timeout _: TimeInterval) async throws -> [Data] {
        #expect(methods == ["account/rateLimits/read"])
        callCount += 1
        return [responses.removeFirst()]
    }

    func calls() -> Int { callCount }
}

private final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(interval)
        }
    }
}

private func claudeStatusSnapshotData(observedAt: Date, usedPercent: Double = 21) -> Data {
    let formatter = ISO8601DateFormatter()
    return Data(
        """
        {
          "observedAt": "\(formatter.string(from: observedAt))",
          "fiveHour": {
            "usedPercent": \(usedPercent),
            "resetsAt": \(observedAt.addingTimeInterval(3_600).timeIntervalSince1970)
          },
          "sevenDay": {
            "usedPercent": \(usedPercent + 1),
            "resetsAt": \(observedAt.addingTimeInterval(86_400).timeIntervalSince1970)
          }
        }
        """.utf8
    )
}

private func temporaryQuotaURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-refresh-\(UUID().uuidString).json")
}

private final class StubCancellation: RefreshCancellation, @unchecked Sendable {
    private let operation: @Sendable () -> Void

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func cancel() {
        operation()
    }
}

private final class StubScheduler: RefreshScheduling, @unchecked Sendable {
    struct Entry: Sendable {
        let id: UUID
        let delay: TimeInterval
        let repeatingInterval: TimeInterval?
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var cancelledIDs: Set<UUID> = []

    func schedule(
        after delay: TimeInterval,
        repeatingEvery repeatingInterval: TimeInterval?,
        operation: @escaping @Sendable () -> Void
    ) -> any RefreshCancellation {
        let entry = Entry(
            id: UUID(),
            delay: delay,
            repeatingInterval: repeatingInterval,
            operation: operation
        )
        lock.withLock {
            entries.append(entry)
        }
        return StubCancellation { [weak self] in
            self?.cancel(entry.id)
        }
    }

    func activeEntries() -> [Entry] {
        lock.withLock {
            entries.filter { !cancelledIDs.contains($0.id) }
        }
    }

    func entriesSnapshot() -> [Entry] {
        lock.withLock { entries }
    }

    func fireOneShot(after delay: TimeInterval) {
        let entry = lock.withLock {
            entries.first {
                !cancelledIDs.contains($0.id)
                    && $0.delay == delay
                    && $0.repeatingInterval == nil
            }
        }
        entry?.operation()
    }

    func fireRepeating(after delay: TimeInterval, repeatingEvery repeatingInterval: TimeInterval) {
        let entry = lock.withLock {
            entries.first {
                !cancelledIDs.contains($0.id)
                    && $0.delay == delay
                    && $0.repeatingInterval == repeatingInterval
            }
        }
        entry?.operation()
    }

    private func cancel(_ id: UUID) {
        _ = lock.withLock {
            cancelledIDs.insert(id)
        }
    }
}

private final class StubWatcher: SourceWatching, @unchecked Sendable {
    func cancel() {}
}

private final class StubWatcherFactory: SourceWatcherFactory, @unchecked Sendable {
    struct Registration: Sendable {
        let directories: [URL]
        let onEvent: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var registrations: [Registration] = []

    func watch(
        directories: [URL],
        onEvent: @escaping @Sendable () -> Void
    ) -> [any SourceWatching] {
        lock.withLock {
            registrations.append(Registration(directories: directories, onEvent: onEvent))
        }
        return [StubWatcher()]
    }

    func registrationsSnapshot() -> [Registration] {
        lock.withLock { registrations }
    }

    func emit() {
        emit(index: registrationsSnapshot().count - 1)
    }

    func emit(index: Int) {
        let registration = lock.withLock {
            registrations.indices.contains(index) ? registrations[index] : nil
        }
        registration?.onEvent()
    }
}

private actor GatedCollector: UsageCollector {
    nonisolated let provider = Provider.claude
    private var nextCallID = 0
    private var pending: [Int: CheckedContinuation<CollectorBatch, any Error>] = [:]

    func collect() async throws -> CollectorBatch {
        nextCallID += 1
        let callID = nextCallID
        return try await withCheckedThrowingContinuation { continuation in
            pending[callID] = continuation
        }
    }

    func pendingIDs() -> [Int] {
        pending.keys.sorted()
    }

    func complete(id: Int, with result: Result<CollectorBatch, any Error>) {
        let continuation = pending.removeValue(forKey: id)
        continuation?.resume(with: result)
    }
}

private actor StoreWritingFailureCollector: UsageCollector {
    nonisolated let provider = Provider.claude
    private let firstBatch: CollectorBatch
    private let quotaToWriteBeforeFailure: [QuotaSnapshot]
    private var callCount = 0

    init(firstBatch: CollectorBatch, quotaToWriteBeforeFailure: [QuotaSnapshot]) {
        self.firstBatch = firstBatch
        self.quotaToWriteBeforeFailure = quotaToWriteBeforeFailure
    }

    func collect() async throws -> CollectorBatch {
        firstBatch
    }

    func collect(into store: UsageStore) async throws -> CollectorBatch {
        callCount += 1
        guard callCount > 1 else {
            return firstBatch
        }

        try await store.save(tokens: [], quota: quotaToWriteBeforeFailure)
        throw StubError.failed
    }
}

private actor RefreshObserverProbe {
    private var count = 0

    func record() {
        count += 1
    }

    func calls() -> Int {
        count
    }
}

private func settleActorTasks() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

private func tokenOnlyBatch(observedAt: Date) -> CollectorBatch {
    CollectorBatch(
        tokens: [
            TokenSample(
                provider: .claude,
                observedAt: observedAt,
                model: "claude-sonnet-4-6",
                inputTokens: 3,
                outputTokens: 20,
                totalTokens: 23
            )
        ],
        quota: []
    )
}

private func batch(
    observedAt: Date,
    usedPercent: Double = 42
) -> CollectorBatch {
    CollectorBatch(
        tokens: [
            TokenSample(
                provider: .claude,
                observedAt: observedAt,
                model: "claude-sonnet-4-6",
                inputTokens: 3,
                outputTokens: 20,
                totalTokens: 23
            )
        ],
        quota: [
            QuotaSnapshot(
                provider: .claude,
                window: .session,
                usedPercent: usedPercent,
                resetsAt: observedAt.addingTimeInterval(3_600),
                observedAt: observedAt
            )
        ]
    )
}

private func eventually(
    _ predicate: @escaping () async -> Bool
) async {
    for _ in 0..<100 {
        if await predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Condition did not become true")
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
    try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        )
    )
}

@Test
func successfulRefreshSavesAndExposesLatestQuotaAndSummary() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let collectedBatch = batch(observedAt: observedAt)
    let store = try UsageStore.inMemory()
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.success(collectedBatch)])],
        now: { observedAt }
    )

    await coordinator.refresh()

    #expect(try await store.latestQuota(provider: .claude) == collectedBatch.quota)
    #expect(await coordinator.latestQuota(provider: .claude) == collectedBatch.quota)
    #expect(await coordinator.latestBatch(provider: .claude)?.tokens == collectedBatch.tokens)
    #expect(
        await coordinator.summary(for: .claude, at: observedAt)
            == ProviderSummary(
                provider: .claude,
                tokens: collectedBatch.tokens,
                quota: collectedBatch.quota,
                state: .fresh
            )
    )
}

@Test
func accountRefreshPublishesProviderNeutralConnectionReports() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let store = try UsageStore.inMemory()
    let claude = FailingAccountQuotaProvider(
        provider: .claude,
        error: .credentialUnavailable
    )
    let codex = FailingAccountQuotaProvider(
        provider: .codex,
        error: .requestFailed(statusCode: 429)
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [claude, codex],
        authorizedAccountProviders: [.claude, .codex],
        now: { now }
    )

    await coordinator.refresh(includingAccountQuota: true)

    #expect(
        await coordinator.connectionReport(for: .claude)
            == ProviderConnectionReport(
                provider: .claude,
                state: .authenticationRequired,
                source: .accountProbe,
                issue: .credentialsMissing,
                checkedAt: now
            )
    )
    #expect(
        await coordinator.connectionReport(for: .codex)
            == ProviderConnectionReport(
                provider: .codex,
                state: .rateLimited,
                source: .accountProbe,
                issue: .rateLimited,
                checkedAt: now
            )
    )
}

@Test
func claudeAuthenticationFailuresKeepTheirSpecificConnectionIssue() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let cases: [(CloudUsageClientError, ProviderConnectionState, ProviderConnectionIssue)] = [
        (.credentialAccessDenied, .permissionRequired, .keychainAccessDenied),
        (.credentialExpired, .authenticationRequired, .credentialExpired),
        (.insufficientScope, .permissionRequired, .insufficientScope),
        (.requestFailed(statusCode: 401), .authenticationRequired, .unauthorized)
    ]

    for (error, expectedState, expectedIssue) in cases {
        let coordinator = RefreshCoordinator(
            store: try UsageStore.inMemory(),
            collectors: [],
            accountQuotaProviders: [
                FailingAccountQuotaProvider(provider: .claude, error: error)
            ],
            authorizedAccountProviders: [.claude],
            now: { now }
        )

        await coordinator.refresh(includingAccountQuota: true)
        let report = await coordinator.connectionReport(for: .claude)
        #expect(report?.state == expectedState)
        #expect(report?.issue == expectedIssue)
    }
}

@Test
func providerScopedAccountRefreshDoesNotProbeOtherProviders() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let store = try UsageStore.inMemory()
    let claude = StubAccountQuotaProvider(provider: .claude, snapshots: [])
    let codex = StubAccountQuotaProvider(provider: .codex, snapshots: [])
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [claude, codex],
        authorizedAccountProviders: [.claude, .codex],
        now: { now }
    )

    await coordinator.requestAccountRefresh(for: .codex)

    #expect(await claude.calls() == 0)
    #expect(await codex.calls() == 1)
}

@Test
func accountQuotaProvidersFailClosedWithoutExplicitAuthorization() async throws {
    let provider = StubAccountQuotaProvider(provider: .claude, snapshots: [])
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [provider]
    )

    await coordinator.requestAccountRefresh(for: .claude)

    #expect(await provider.calls() == 0)
    #expect(await coordinator.connectionReport(for: .claude) == nil)
}

@Test
func accountQuotaConsentDynamicallyGatesStartupAndBackgroundProbes() async throws {
    let scheduler = StubScheduler()
    let provider = StubAccountQuotaProvider(provider: .claude, snapshots: [])
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: []
    )

    await coordinator.start(
        profile: .manual,
        liveQuotaRefreshInterval: .oneMinute,
        authorizedAccountProviders: []
    )
    #expect(await provider.calls() == 0)
    #expect(scheduler.activeEntries().allSatisfy { $0.repeatingInterval != 60 })

    await coordinator.configure(
        profile: .manual,
        liveQuotaRefreshInterval: .oneMinute,
        authorizedAccountProviders: [.claude]
    )
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 1 }

    await coordinator.configure(
        profile: .manual,
        liveQuotaRefreshInterval: .oneMinute,
        authorizedAccountProviders: []
    )
    #expect(scheduler.activeEntries().allSatisfy { $0.repeatingInterval != 60 })
    await coordinator.requestAccountRefresh(for: .claude)
    #expect(await provider.calls() == 1)
}

@Test
func productionClaudeCompositionUsesFreshLocalQuotaWithoutAccountProbe() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let snapshotURL = temporaryQuotaURL()
    try claudeStatusSnapshotData(observedAt: now).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .session,
            source: .account,
            usedPercent: 90,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now.addingTimeInterval(-60)
        )
    ])
    let accountProvider = StubAccountQuotaProvider(
        provider: .claude,
        snapshots: [
            QuotaSnapshot(
                provider: .claude,
                window: .session,
                source: .account,
                usedPercent: 80,
                resetsAt: now.addingTimeInterval(3_600),
                observedAt: now
            )
        ]
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [
            ClaudeCollector(
                quotaSnapshotURL: snapshotURL,
                roots: [],
                now: { now }
            )
        ],
        accountQuotaProviders: [accountProvider],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.start(profile: .manual)

    #expect(await accountProvider.calls() == 0)
    #expect(await coordinator.latestQuota(provider: .claude).map(\.source) == [.local, .local])
    #expect(try await store.latestQuota(provider: .claude, at: now).map(\.source) == [.local, .local])

    await coordinator.requestAccountRefresh(for: .claude)
    #expect(await accountProvider.calls() == 1)
    #expect(await coordinator.connectionReport(for: .claude)?.state == .connected)
    #expect(await coordinator.latestQuota(provider: .claude).map(\.source) == [.local, .local])
}

@Test
func productionClaudeCompositionFallsBackToAccountForStaleLocalQuota() async throws {
    let now = Date(timeIntervalSince1970: 3_000)
    let snapshotURL = temporaryQuotaURL()
    try claudeStatusSnapshotData(observedAt: now.addingTimeInterval(-601)).write(to: snapshotURL)
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    let accountQuota = QuotaSnapshot(
        provider: .claude,
        window: .session,
        source: .account,
        usedPercent: 40,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now
    )
    let accountProvider = StubAccountQuotaProvider(provider: .claude, snapshots: [accountQuota])
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [ClaudeCollector(quotaSnapshotURL: snapshotURL, roots: [], now: { now })],
        accountQuotaProviders: [accountProvider],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.start(profile: .manual)

    #expect(await accountProvider.calls() == 1)
    #expect(await coordinator.latestQuota(provider: .claude) == [accountQuota])
}

@Test
func productionClaudeCompositionFallsBackToAccountForMissingMalformedOrUnreadableLocalQuota() async throws {
    let now = Date(timeIntervalSince1970: 4_000)
    let malformedURL = temporaryQuotaURL()
    try Data(#"{"malformed":true}"#.utf8).write(to: malformedURL)
    defer { try? FileManager.default.removeItem(at: malformedURL) }
    let unreadableURL = temporaryQuotaURL()
    try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unreadableURL) }
    let accountQuota = QuotaSnapshot(
        provider: .claude,
        window: .weekly,
        source: .account,
        usedPercent: 50,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now
    )

    for snapshotURL in [URL?](arrayLiteral: nil, malformedURL, unreadableURL) {
        let accountProvider = StubAccountQuotaProvider(provider: .claude, snapshots: [accountQuota])
        let coordinator = RefreshCoordinator(
            store: try UsageStore.inMemory(),
            collectors: [ClaudeCollector(quotaSnapshotURL: snapshotURL, roots: [], now: { now })],
            accountQuotaProviders: [accountProvider],
            scheduler: StubScheduler(),
            watcherFactory: StubWatcherFactory(),
            authorizedAccountProviders: [.claude],
            now: { now }
        )

        await coordinator.start(profile: .manual)

        #expect(await accountProvider.calls() == 1)
        #expect(await coordinator.latestQuota(provider: .claude) == [accountQuota])
    }
}

@Test
func automaticAccountRefreshHonorsProviderMinimumIntervalWhileManualRefreshBypassesIt() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let scheduler = StubScheduler()
    let provider = StubAccountQuotaProvider(
        provider: .claude,
        snapshots: [],
        minimumRefreshInterval: 900
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually {
        await provider.calls() == 1
    }
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await provider.calls() == 1)

    await coordinator.requestAccountRefresh(for: .claude)
    #expect(await provider.calls() == 2)
}

@Test
func backgroundAccountRefreshHonorsOAuthRetryAfterAndPreservesLastKnownQuota() async throws {
    let initialDate = Date(timeIntervalSince1970: 1_000)
    let clock = MutableTestClock(now: initialDate)
    let retryAfter = initialDate.addingTimeInterval(300)
    let scheduler = StubScheduler()
    let provider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .rateLimited(retryAfter: retryAfter)
    )
    let lastKnown = QuotaSnapshot(
        provider: .claude,
        window: .weekly,
        source: .account,
        usedPercent: 37,
        resetsAt: initialDate.addingTimeInterval(3_600),
        observedAt: initialDate.addingTimeInterval(-601)
    )
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [lastKnown])
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: clock.now
    )

    await coordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 1 }

    #expect(await coordinator.latestQuota(provider: .claude) == [lastKnown])
    #expect(await coordinator.connectionReport(for: .claude)?.state == .rateLimited)
    #expect(await coordinator.connectionReport(for: .claude)?.issue == .rateLimited)

    clock.advance(by: 299)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await provider.calls() == 1)

    clock.advance(by: 2)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 2 }

    // The provider returned the same now-expired Retry-After deadline on the
    // second request. Background refreshes fall back to a five-minute cooldown.
    clock.advance(by: 299)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await provider.calls() == 2)

    clock.advance(by: 2)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 3 }
}

@Test
func retryAfterIsBoundedAndPersistedAcrossCoordinatorRestart() async throws {
    let initialDate = Date(timeIntervalSince1970: 10_000)
    let clock = MutableTestClock(now: initialDate)
    let cooldownStore = InMemoryAccountQuotaCooldownStore()
    let policy = AccountQuotaRetryPolicy(
        defaultRateLimitCooldown: 300,
        maximumRateLimitCooldown: 600
    )
    let firstScheduler = StubScheduler()
    let firstProvider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .rateLimited(retryAfter: initialDate.addingTimeInterval(365 * 24 * 60 * 60))
    )
    let firstCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [firstProvider],
        scheduler: firstScheduler,
        watcherFactory: StubWatcherFactory(),
        accountQuotaCooldownStore: cooldownStore,
        accountQuotaRetryPolicy: policy,
        authorizedAccountProviders: [.claude],
        now: clock.now
    )
    await firstCoordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    firstScheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await firstProvider.calls() == 1 }
    #expect(cooldownStore.retryNotBefore(for: .claude) == initialDate.addingTimeInterval(600))

    let restartedScheduler = StubScheduler()
    let restartedProvider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .rateLimited(retryAfter: nil)
    )
    let restartedCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [restartedProvider],
        scheduler: restartedScheduler,
        watcherFactory: StubWatcherFactory(),
        accountQuotaCooldownStore: cooldownStore,
        accountQuotaRetryPolicy: policy,
        authorizedAccountProviders: [.claude],
        now: clock.now
    )
    await restartedCoordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    restartedScheduler.fireRepeating(after: 60, repeatingEvery: 60)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await restartedProvider.calls() == 0)

    clock.advance(by: 601)
    restartedScheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await restartedProvider.calls() == 1 }
}

@Test
func userDefaultsCooldownStoreRoundTripsWithoutAccountData() throws {
    let suiteName = #function
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let deadline = Date(timeIntervalSince1970: 12_345)

    UserDefaultsAccountQuotaCooldownStore(defaults: defaults)
        .setRetryNotBefore(deadline, for: .claude)
    let relaunchedStore = UserDefaultsAccountQuotaCooldownStore(defaults: defaults)

    #expect(relaunchedStore.retryNotBefore(for: .claude) == deadline)
    #expect(relaunchedStore.retryNotBefore(for: .codex) == nil)
}

@Test
func manualAccountRefreshBypassesPersistedRateLimitCooldown() async throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let cooldownStore = InMemoryAccountQuotaCooldownStore()
    cooldownStore.setRetryNotBefore(now.addingTimeInterval(600), for: .claude)
    let provider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .rateLimited(retryAfter: nil)
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [provider],
        accountQuotaCooldownStore: cooldownStore,
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.requestAccountRefresh(for: .claude)

    #expect(await provider.calls() == 1)
}

@Test
func noUsableQuotaRetainsLastKnownQuotaAndReportsTypedFailure() async throws {
    let now = Date(timeIntervalSince1970: 30_000)
    let lastKnown = QuotaSnapshot(
        provider: .claude,
        window: .weekly,
        source: .account,
        usedPercent: 41,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now.addingTimeInterval(-120)
    )
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [lastKnown])
    let provider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .noUsableQuota
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.requestAccountRefresh(for: .claude)

    #expect(await coordinator.latestQuota(provider: .claude) == [lastKnown])
    #expect(await coordinator.connectionReport(for: .claude)?.state == .unavailable)
    #expect(await coordinator.connectionReport(for: .claude)?.issue == .noUsableQuota)
}

@Test
func noUsableQuotaDoesNotAdvanceSuccessfulRefreshCooldown() async throws {
    let initialDate = Date(timeIntervalSince1970: 40_000)
    let clock = MutableTestClock(now: initialDate)
    let scheduler = StubScheduler()
    let validQuota = QuotaSnapshot(
        provider: .claude,
        window: .session,
        source: .account,
        usedPercent: 12,
        resetsAt: initialDate.addingTimeInterval(3_600),
        observedAt: initialDate
    )
    let provider = SequencedAccountQuotaProvider(
        provider: .claude,
        minimumRefreshInterval: 3_600,
        results: [.failure(CloudUsageClientError.noUsableQuota), .success([validQuota])]
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: clock.now
    )
    await coordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 1 }
    #expect(await coordinator.connectionReport(for: .claude)?.issue == .noUsableQuota)

    clock.advance(by: 61)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 2 }
    #expect(await coordinator.connectionReport(for: .claude)?.state == .connected)
}

@Test
func emptyCodexQuotaRetainsPriorQuotaAndDoesNotAdvanceSuccessCooldown() async throws {
    let initialDate = Date(timeIntervalSince1970: 50_000)
    let clock = MutableTestClock(now: initialDate)
    let scheduler = StubScheduler()
    let prior = QuotaSnapshot(
        provider: .codex,
        window: .weekly,
        source: .account,
        usedPercent: 33,
        resetsAt: initialDate.addingTimeInterval(3_600),
        observedAt: initialDate.addingTimeInterval(-7_200)
    )
    let replacement = QuotaSnapshot(
        provider: .codex,
        window: .weekly,
        source: .account,
        usedPercent: 44,
        resetsAt: initialDate.addingTimeInterval(7_200),
        observedAt: initialDate.addingTimeInterval(61)
    )
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [prior])
    let provider = SequencedAccountQuotaProvider(
        provider: .codex,
        minimumRefreshInterval: 3_600,
        results: [.success([]), .success([replacement])]
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.codex],
        now: clock.now
    )
    await coordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)

    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 1 }
    #expect(await coordinator.latestQuota(provider: .codex) == [prior])
    #expect(await coordinator.connectionReport(for: .codex)?.issue == .noUsableQuota)

    clock.advance(by: 61)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await provider.calls() == 2 }
    #expect(await coordinator.connectionReport(for: .codex)?.state == .connected)
}

@Test
func expiredCodexWindowsRetainPriorQuotaAndDoNotAdvanceSuccessCooldown() async throws {
    let initialDate = Date(timeIntervalSince1970: 1_783_700_000)
    let clock = MutableTestClock(now: initialDate)
    let scheduler = StubScheduler()
    let prior = QuotaSnapshot(
        provider: .codex,
        window: .weekly,
        source: .account,
        usedPercent: 33,
        resetsAt: initialDate.addingTimeInterval(3_600),
        observedAt: initialDate.addingTimeInterval(-7_200)
    )
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [prior])
    let transport = SequencedCodexTransport(responses: [
        Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":90,"resetsAt":1783700000,"windowDurationMins":300},"secondary":null}}
        """.utf8),
        Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"resetsAt":1783703600,"windowDurationMins":300},"secondary":null}}
        """.utf8)
    ])
    let provider = CodexAccountQuotaProvider(
        transport: transport,
        observedAt: clock.now
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.codex],
        now: clock.now
    )
    await coordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)

    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await transport.calls() == 1 }
    #expect(await coordinator.latestQuota(provider: .codex) == [prior])
    #expect(await coordinator.connectionReport(for: .codex)?.issue == .noUsableQuota)

    clock.advance(by: 61)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually { await transport.calls() == 2 }
    #expect(await coordinator.connectionReport(for: .codex)?.state == .connected)
    let latestQuota = await coordinator.latestQuota(provider: .codex)
    #expect(latestQuota.map(\.window) == [.session, .weekly])
    #expect(latestQuota.map(\.usedPercent) == [10, 33])
}

@Test
func manualNonRateLimitFailureClearsPersistedCooldownForRestart() async throws {
    let now = Date(timeIntervalSince1970: 60_000)
    let cooldownStore = InMemoryAccountQuotaCooldownStore()
    cooldownStore.setRetryNotBefore(now.addingTimeInterval(600), for: .claude)
    let bypassProvider = CountingFailingAccountQuotaProvider(
        provider: .claude,
        error: .requestFailed(statusCode: 401)
    )
    let bypassCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [bypassProvider],
        accountQuotaCooldownStore: cooldownStore,
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await bypassCoordinator.requestAccountRefresh(for: .claude)
    #expect(await bypassProvider.calls() == 1)
    #expect(cooldownStore.retryNotBefore(for: .claude) == nil)

    let scheduler = StubScheduler()
    let restartedProvider = StubAccountQuotaProvider(
        provider: .claude,
        snapshots: [
            QuotaSnapshot(
                provider: .claude,
                window: .session,
                source: .account,
                usedPercent: 10,
                resetsAt: now.addingTimeInterval(3_600),
                observedAt: now
            )
        ]
    )
    let restartedCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [restartedProvider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        accountQuotaCooldownStore: cooldownStore,
        authorizedAccountProviders: [.claude],
        now: { now }
    )
    await restartedCoordinator.configure(profile: .manual, liveQuotaRefreshInterval: .oneMinute)
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)

    await eventually { await restartedProvider.calls() == 1 }
}

@Test
func startupReusesRecentStoredAccountQuotaWhileManualRefreshStillProbes() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let store = try UsageStore.inMemory()
    try await store.save(tokens: [], quota: [
        QuotaSnapshot(
            provider: .claude,
            window: .weekly,
            source: .account,
            usedPercent: 20,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now.addingTimeInterval(-60)
        )
    ])
    let provider = StubAccountQuotaProvider(
        provider: .claude,
        snapshots: [],
        minimumRefreshInterval: 900
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.claude],
        now: { now }
    )

    await coordinator.start(profile: .manual)
    #expect(await provider.calls() == 0)

    await coordinator.requestAccountRefresh(for: .claude)
    #expect(await provider.calls() == 1)
}

@Test
func successfulAccountRefreshPublishesConnectedReport() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let store = try UsageStore.inMemory()
    let quota = QuotaSnapshot(
        provider: .codex,
        window: .weekly,
        source: .account,
        usedPercent: 30,
        resetsAt: now.addingTimeInterval(3_600),
        observedAt: now
    )
    let provider = StubAccountQuotaProvider(provider: .codex, snapshots: [quota])
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [],
        accountQuotaProviders: [provider],
        authorizedAccountProviders: [.codex],
        now: { now }
    )

    await coordinator.refresh(includingAccountQuota: true)

    #expect(
        await coordinator.connectionReport(for: .codex)
            == ProviderConnectionReport(provider: .codex, state: .connected, checkedAt: now)
    )
}

@Test
func freshClaudeLocalRefreshTakesDisplayPriorityOverCurrentAccountQuota() async throws {
    let accountObservedAt = Date(timeIntervalSince1970: 1_000)
    let localObservedAt = Date(timeIntervalSince1970: 1_100)
    let store = try UsageStore.inMemory()
    let accountQuota = QuotaSnapshot(
        provider: .claude,
        window: .session,
        source: .account,
        usedPercent: 14,
        resetsAt: accountObservedAt.addingTimeInterval(3_600),
        observedAt: accountObservedAt
    )
    try await store.save(tokens: [], quota: [accountQuota])

    let localBatch = batch(observedAt: localObservedAt, usedPercent: 0)
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.success(localBatch)])],
        now: { localObservedAt }
    )

    await coordinator.refresh()

    #expect(await coordinator.latestQuota(provider: .claude) == localBatch.quota)
}

@Test
func successfulRefreshWithMissingQuotaSnapshotPreservesLastKnownQuota() async throws {
    let oldQuotaBatch = batch(observedAt: Date(timeIntervalSince1970: 1_000))
    let tokenOnlyBatch = tokenOnlyBatch(observedAt: Date(timeIntervalSince1970: 1_300))
    let store = try UsageStore.inMemory()
    try await store.save(tokens: oldQuotaBatch.tokens, quota: oldQuotaBatch.quota)
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.success(tokenOnlyBatch)])],
        now: { Date(timeIntervalSince1970: 1_300) }
    )

    await coordinator.refresh()

    #expect(await coordinator.latestQuota(provider: .claude) == oldQuotaBatch.quota)
    #expect(
        await coordinator.summary(for: .claude, at: Date(timeIntervalSince1970: 1_300))
            == ProviderSummary(
                provider: .claude,
                tokens: tokenOnlyBatch.tokens,
                quota: oldQuotaBatch.quota,
                state: .fresh
            )
    )
}

@Test
func emptyIncrementalRefreshPreservesPersistedQuota() async throws {
    let oldQuotaBatch = batch(observedAt: Date(timeIntervalSince1970: 1_000))
    let emptyIncrementalBatch = CollectorBatch(tokens: [], quota: [], isPersisted: true)
    let store = try UsageStore.inMemory()
    try await store.save(tokens: oldQuotaBatch.tokens, quota: oldQuotaBatch.quota)
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.success(emptyIncrementalBatch)])],
        now: { Date(timeIntervalSince1970: 1_300) }
    )

    await coordinator.refresh()

    #expect(await coordinator.latestQuota(provider: .claude) == oldQuotaBatch.quota)
    #expect(
        await coordinator.summary(for: .claude, at: Date(timeIntervalSince1970: 1_300))
            == ProviderSummary(
                provider: .claude,
                tokens: [],
                quota: oldQuotaBatch.quota,
                state: .fresh
            )
    )
}

@Test
func explicitCodexRefreshBatchIsSavedByCoordinator() async throws {
    let sessionURL = try fixtureURL(named: "codex-session", extension: "jsonl")
    let collector = CodexCollector(sessionURLs: [sessionURL])
    let batch = try await collector.collect()
    #expect(!batch.isPersisted)

    let store = try UsageStore.inMemory()
    let coordinator = RefreshCoordinator(store: store, collectors: [collector])

    await coordinator.refresh()

    #expect(try await store.tokenTotal(provider: .codex) == 132)
    #expect(try await store.latestQuota(provider: .codex) == batch.quota)
    #expect(await coordinator.latestQuota(provider: .codex) == batch.quota)
}

@Test
func olderRefreshCompletionCannotOverwriteNewerRefreshState() async throws {
    let olderBatch = batch(
        observedAt: Date(timeIntervalSince1970: 2_000),
        usedPercent: 10
    )
    let newerBatch = batch(
        observedAt: Date(timeIntervalSince1970: 1_000),
        usedPercent: 80
    )
    let store = try UsageStore.inMemory()
    let collector = GatedCollector()
    let coordinator = RefreshCoordinator(store: store, collectors: [collector])

    let olderRefresh = Task {
        await coordinator.refresh()
    }
    await eventually {
        await collector.pendingIDs() == [1]
    }
    let newerRefresh = Task {
        await coordinator.refresh()
    }
    await eventually {
        await collector.pendingIDs() == [1, 2]
    }

    await collector.complete(id: 2, with: .success(newerBatch))
    await newerRefresh.value
    #expect(await coordinator.latestQuota(provider: .claude) == newerBatch.quota)
    await collector.complete(id: 1, with: .success(olderBatch))
    await olderRefresh.value

    #expect(await coordinator.latestQuota(provider: .claude) == newerBatch.quota)
    #expect(try await store.latestQuota(provider: .claude) == newerBatch.quota)
}

@Test
func staleTimerAndWatchCallbacksAreIgnoredAfterReconfigure() async throws {
    let scheduler = StubScheduler()
    let watcherFactory = StubWatcherFactory()
    let collector = StubCollector(
        sourceDirectories: [URL(filePath: "/synthetic/claude")],
        results: [
            .success(CollectorBatch(tokens: [], quota: [])),
            .success(CollectorBatch(tokens: [], quota: []))
        ]
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: scheduler,
        watcherFactory: watcherFactory
    )
    await coordinator.configure(profile: .efficient)
    let oldTimer = try #require(scheduler.entriesSnapshot().first)
    #expect(try #require(watcherFactory.registrationsSnapshot().first).directories == collector.sourceDirectories)

    await coordinator.configure(profile: .manual)
    oldTimer.operation()
    watcherFactory.emit(index: 0)
    await settleActorTasks()

    #expect(await collector.calls() == 0)
    #expect(scheduler.activeEntries().isEmpty)
}

@Test
func failingCollectorReloadsQuotaPersistedBeforeThrowing() async throws {
    let oldBatch = batch(
        observedAt: Date(timeIntervalSince1970: 1_000),
        usedPercent: 25
    )
    let newerQuota = batch(
        observedAt: Date(timeIntervalSince1970: 2_000),
        usedPercent: 70
    ).quota
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [
            StoreWritingFailureCollector(
                firstBatch: oldBatch,
                quotaToWriteBeforeFailure: newerQuota
            )
        ]
    )

    await coordinator.refresh()
    await coordinator.refresh()

    #expect(await coordinator.state(for: .claude, at: Date(timeIntervalSince1970: 2_000)) == .sourceChanged)
    #expect(await coordinator.latestQuota(provider: .claude) == newerQuota)
}

@Test
func coordinatorUsesCollectorIncrementalImportPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    try Data(
        """
        {"type":"assistant","timestamp":"2026-06-01T10:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":3,"output_tokens":20}}}

        """.utf8
    ).write(to: transcript)
    let store = try UsageStore.inMemory()
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [ClaudeCollector(roots: [root])]
    )

    await coordinator.refresh()

    #expect(try await store.tokenTotal(provider: .claude) == 23)
}

@Test
func coordinatorActivatesCanonicalTranscriptAccountingBeforeRefresh() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("transcript.jsonl")
    try Data(
        """
        {"type":"assistant","timestamp":"2026-06-01T10:00:00Z","sessionId":"session","requestId":"request-1","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":3,"output_tokens":20}}}

        """.utf8
    ).write(to: transcript)
    let store = try UsageStore.inMemory()
    let refreshNow = Date(timeIntervalSince1970: 1_780_308_120)
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [ClaudeCollector(roots: [root])],
        now: { refreshNow }
    )

    await coordinator.refresh()

    #expect(try await store.activeAccountingVersion() == 2)
    #expect(try await store.tokenTotal(provider: .claude) == 23)
    #expect(try await store.canonicalTranscriptRecords().count == 1)
    #expect(try await store.canonicalTranscriptRecords().allSatisfy { !$0.logicalDedupeKey.contains("request-1") })
    #expect(
        try await store.latestTokenObservedAt(provider: .claude)
            == Date(timeIntervalSince1970: 1_780_308_000)
    )
    let stateAfterReindex = await coordinator.state(for: .claude, at: refreshNow)
    #expect(stateAfterReindex == .fresh)

    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(
        """
        {"type":"assistant","timestamp":"2026-06-01T10:01:00Z","sessionId":"session","requestId":"request-2","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":4,"output_tokens":21}}}

        """.utf8
    ))
    try handle.close()

    await coordinator.refresh()

    #expect(try await store.tokenTotal(provider: .claude) == 48)
    #expect(
        try await store.canonicalTranscriptRecords().count == 2
    )

    try FileManager.default.removeItem(at: transcript)
    await coordinator.refresh()

    #expect(try await store.tokenTotal(provider: .claude) == 0)
    #expect(try await store.canonicalTranscriptRecords().isEmpty)
}

@Test
func failedRefreshPreservesPriorSnapshotAndMarksSourceChanged() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let previousBatch = batch(observedAt: observedAt)
    let store = try UsageStore.inMemory()
    try await store.save(tokens: previousBatch.tokens, quota: previousBatch.quota)
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.failure(StubError.failed)])],
        now: { observedAt }
    )

    await coordinator.refresh()

    #expect(await coordinator.state(for: .claude, at: observedAt) == .sourceChanged)
    #expect(await coordinator.latestQuota(provider: .claude) == previousBatch.quota)
}

@Test
func successfulRefreshWithoutQuotaIsUnavailable() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let store = try UsageStore.inMemory()
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [
            StubCollector(results: [.success(CollectorBatch(tokens: [], quota: []))])
        ],
        now: { now }
    )

    await coordinator.refresh()

    #expect(await coordinator.state(for: .claude, at: now) == .unavailable)
}

@Test
func successfulRefreshWithTokensButNoQuotaIsFresh() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [
            StubCollector(results: [.success(tokenOnlyBatch(observedAt: observedAt))])
        ],
        now: { observedAt }
    )

    await coordinator.refresh()

    #expect(await coordinator.state(for: .claude, at: observedAt) == .fresh)
    #expect(await coordinator.state(for: .claude, at: observedAt.addingTimeInterval(601)) == .stale)
}

@Test
func successfulRefreshBecomesStaleAfterTenMinutes() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let store = try UsageStore.inMemory()
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [StubCollector(results: [.success(batch(observedAt: observedAt))])],
        now: { observedAt }
    )
    await coordinator.refresh()

    #expect(
        await coordinator.state(
            for: .claude,
            at: observedAt.addingTimeInterval(601)
        ) == .stale
    )
}

@Test
func fallbackTimerRefreshNotifiesObserver() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let collector = StubCollector(
        results: [
            .success(tokenOnlyBatch(observedAt: observedAt)),
            .success(CollectorBatch(tokens: [], quota: []))
        ]
    )
    let scheduler = StubScheduler()
    let probe = RefreshObserverProbe()
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        now: { observedAt }
    )
    await coordinator.setRefreshObserver {
        await probe.record()
    }
    await coordinator.configure(profile: .responsive)

    scheduler.fireRepeating(after: 600, repeatingEvery: 600)
    await eventually {
        await probe.calls() == 1
    }

    #expect(await collector.calls() == 1)
}

@Test(arguments: [
    (RefreshProfile.realTime, 300.0),
    (RefreshProfile.efficient, 900.0),
    (RefreshProfile.responsive, 600.0)
])
func automaticProfilesScheduleExpectedFallbackInterval(
    profile: RefreshProfile,
    interval: TimeInterval
) async throws {
    let scheduler = StubScheduler()
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory()
    )

    await coordinator.configure(profile: profile)

    let entry = try #require(scheduler.activeEntries().first)
    #expect(entry.delay == interval)
    #expect(entry.repeatingInterval == interval)
}

@Test
func manualProfileSchedulesNoFallbackTimer() async throws {
    let scheduler = StubScheduler()
    let watcherFactory = StubWatcherFactory()
    let collector = StubCollector(
        sourceDirectories: [URL(fileURLWithPath: "/tmp/quotakin-manual-source")],
        results: []
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: scheduler,
        watcherFactory: watcherFactory
    )

    await coordinator.configure(profile: .manual)

    #expect(scheduler.activeEntries().isEmpty)
    #expect(watcherFactory.registrationsSnapshot().isEmpty)
}

@Test
func switchingToManualCancelsAutomaticWorkAndIgnoresOldWatcherCallbacks() async throws {
    let scheduler = StubScheduler()
    let watcherFactory = StubWatcherFactory()
    let collector = StubCollector(
        sourceDirectories: [URL(fileURLWithPath: "/tmp/quotakin-automatic-source")],
        results: []
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: scheduler,
        watcherFactory: watcherFactory
    )

    await coordinator.configure(profile: .efficient)
    #expect(scheduler.activeEntries().count == 1)
    #expect(watcherFactory.registrationsSnapshot().count == 1)

    await coordinator.configure(
        profile: .manual,
        liveQuotaRefreshInterval: .manual
    )
    watcherFactory.emit(index: 0)
    await settleActorTasks()

    #expect(scheduler.activeEntries().isEmpty)
    #expect(watcherFactory.registrationsSnapshot().count == 1)
}

@Test
func completedCollectorPassPublishesLocalUsageRefreshTime() async throws {
    let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let collector = StubCollector(
        results: [.success(CollectorBatch(tokens: [], quota: []))]
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory(),
        now: { refreshedAt }
    )

    await coordinator.refresh()

    #expect(await coordinator.localUsageRefreshAt() == refreshedAt)
}

@Test
func accountQuotaTimerRunsSeparatelyFromLocalRefreshProfile() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let accountProvider = StubAccountQuotaProvider(
        provider: .codex,
        snapshots: [
            QuotaSnapshot(
                provider: .codex,
                window: .session,
                source: .account,
                usedPercent: 40,
                resetsAt: observedAt.addingTimeInterval(3_600),
                observedAt: observedAt
            )
        ]
    )
    let scheduler = StubScheduler()
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        accountQuotaProviders: [accountProvider],
        scheduler: scheduler,
        watcherFactory: StubWatcherFactory(),
        authorizedAccountProviders: [.codex],
        now: { observedAt }
    )

    await coordinator.configure(
        profile: .manual,
        liveQuotaRefreshInterval: .oneMinute
    )
    scheduler.fireRepeating(after: 60, repeatingEvery: 60)
    await eventually {
        await accountProvider.calls() == 1
    }

    let quota = await coordinator.latestQuota(provider: .codex)
    #expect(quota.first?.source == .account)
    #expect(await accountProvider.calls() == 1)
}

@Test
func quotaLimitPredictionsReadStoredHistoryAfterRefreshes() async throws {
    let store = try UsageStore.inMemory()
    let reset = Date(timeIntervalSince1970: 5 * 60 * 60)
    let collector = StubCollector(
        provider: .codex,
        results: [
            .success(CollectorBatch(tokens: [], quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .session,
                    source: .account,
                    usedPercent: 10,
                    resetsAt: reset,
                    observedAt: Date(timeIntervalSince1970: 0)
                )
            ])),
            .success(CollectorBatch(tokens: [], quota: [
                QuotaSnapshot(
                    provider: .codex,
                    window: .session,
                    source: .account,
                    usedPercent: 30,
                    resetsAt: reset,
                    observedAt: Date(timeIntervalSince1970: 60 * 60)
                )
            ]))
        ]
    )
    let coordinator = RefreshCoordinator(
        store: store,
        collectors: [collector],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory(),
        now: { Date(timeIntervalSince1970: 60 * 60) }
    )

    await coordinator.start(profile: .manual)
    await coordinator.requestRefresh()

    let predictions = try await coordinator.quotaLimitPredictions(
        provider: .codex,
        source: .account,
        at: Date(timeIntervalSince1970: 60 * 60)
    )
    let session = try #require(predictions.first { $0.window == .session })

    #expect(session.burnRatePercentPerHour == 20)
    guard case .atRisk(let projectedAt) = session.verdict else {
        Issue.record("Expected stored quota history to feed an at-risk prediction")
        return
    }
    #expect(projectedAt == Date(timeIntervalSince1970: 4.5 * 60 * 60))
}

@Test
func launchAndManualRequestAPIsRefreshCollectors() async throws {
    let collector = StubCollector(
        results: [
            .success(CollectorBatch(tokens: [], quota: [])),
            .success(CollectorBatch(tokens: [], quota: []))
        ]
    )
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: StubScheduler(),
        watcherFactory: StubWatcherFactory()
    )

    await coordinator.start(profile: .manual)
    await coordinator.requestRefresh()

    #expect(await collector.calls() == 2)
}

@Test
func watchBurstTriggersOneDebouncedRefresh() async throws {
    let sourceDirectory = URL(filePath: "/synthetic/claude")
    let collector = StubCollector(
        sourceDirectories: [sourceDirectory],
        results: [.success(CollectorBatch(tokens: [], quota: []))]
    )
    let scheduler = StubScheduler()
    let watcherFactory = StubWatcherFactory()
    let coordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [collector],
        scheduler: scheduler,
        watcherFactory: watcherFactory
    )
    await coordinator.configure(profile: .efficient)

    watcherFactory.emit()
    watcherFactory.emit()
    watcherFactory.emit()
    await eventually {
        scheduler.activeEntries().filter {
            $0.delay == 5 && $0.repeatingInterval == nil
        }.count == 1
    }
    scheduler.fireOneShot(after: 5)
    await eventually {
        await collector.calls() == 1
    }

    #expect(watcherFactory.registrationsSnapshot().last?.directories == [sourceDirectory])
    #expect(await collector.calls() == 1)
}
