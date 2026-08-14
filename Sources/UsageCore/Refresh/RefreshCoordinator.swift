import Darwin
import Dispatch
import Foundation

public protocol RefreshCancellation: Sendable {
    func cancel()
}

public protocol RefreshScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        repeatingEvery repeatingInterval: TimeInterval?,
        operation: @escaping @Sendable () -> Void
    ) -> any RefreshCancellation
}

public protocol SourceWatching: Sendable {
    func cancel()
}

public protocol SourceWatcherFactory: Sendable {
    func watch(
        directories: [URL],
        onEvent: @escaping @Sendable () -> Void
    ) -> [any SourceWatching]
}

public protocol AccountQuotaCooldownStore: Sendable {
    func retryNotBefore(for provider: Provider) -> Date?
    func setRetryNotBefore(_ date: Date?, for provider: Provider)
}

public struct AccountQuotaRetryPolicy: Equatable, Sendable {
    public let defaultRateLimitCooldown: TimeInterval
    public let maximumRateLimitCooldown: TimeInterval

    public init(
        defaultRateLimitCooldown: TimeInterval = 5 * 60,
        maximumRateLimitCooldown: TimeInterval = 60 * 60
    ) {
        self.defaultRateLimitCooldown = max(defaultRateLimitCooldown, 0)
        self.maximumRateLimitCooldown = max(maximumRateLimitCooldown, 0)
    }

    func retryNotBefore(retryAfter: Date?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(defaultRateLimitCooldown)
        let requested = retryAfter.flatMap { $0 > now ? $0 : nil } ?? fallback
        return min(requested, now.addingTimeInterval(maximumRateLimitCooldown))
    }
}

public final class InMemoryAccountQuotaCooldownStore: AccountQuotaCooldownStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [Provider: Date] = [:]

    public init() {}

    public func retryNotBefore(for provider: Provider) -> Date? {
        lock.withLock { deadlines[provider] }
    }

    public func setRetryNotBefore(_ date: Date?, for provider: Provider) {
        lock.withLock { deadlines[provider] = date }
    }
}

public final class UserDefaultsAccountQuotaCooldownStore: AccountQuotaCooldownStore, @unchecked Sendable {
    private static let keyPrefix = "UsageBar.AccountQuotaRetryNotBefore.v1."
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func retryNotBefore(for provider: Provider) -> Date? {
        lock.withLock {
            guard let value = defaults.object(forKey: key(for: provider)) as? Double else {
                return nil
            }
            return Date(timeIntervalSince1970: value)
        }
    }

    public func setRetryNotBefore(_ date: Date?, for provider: Provider) {
        lock.withLock {
            let key = key(for: provider)
            if let date {
                defaults.set(date.timeIntervalSince1970, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func key(for provider: Provider) -> String {
        Self.keyPrefix + provider.rawValue
    }
}

public final class DispatchRefreshScheduler: RefreshScheduling, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "Quotakin.refresh-timer")) {
        self.queue = queue
    }

    public func schedule(
        after delay: TimeInterval,
        repeatingEvery repeatingInterval: TimeInterval?,
        operation: @escaping @Sendable () -> Void
    ) -> any RefreshCancellation {
        let source = DispatchSource.makeTimerSource(queue: queue)
        if let repeatingInterval {
            source.schedule(deadline: .now() + delay, repeating: repeatingInterval)
        } else {
            source.schedule(deadline: .now() + delay)
        }
        source.setEventHandler(handler: operation)
        source.resume()
        return DispatchCancellation {
            source.cancel()
        }
    }
}

public final class DispatchSourceWatcherFactory: SourceWatcherFactory, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "Quotakin.source-watcher")) {
        self.queue = queue
    }

    public func watch(
        directories: [URL],
        onEvent: @escaping @Sendable () -> Void
    ) -> [any SourceWatching] {
        directories.compactMap { directory in
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                return nil
            }
            return DispatchDirectoryWatch(
                descriptor: descriptor,
                queue: queue,
                onEvent: onEvent
            )
        }
    }
}

public actor RefreshCoordinator {
    private struct AccountRefreshState {
        var failureCount = 0
        var retryNotBefore: Date?
        var lastSucceededAt: Date?
        var report: ProviderConnectionReport?
    }

    private struct ConnectionFailure {
        let state: ProviderConnectionState
        let issue: ProviderConnectionIssue
    }

    private let store: UsageStore
    private let collectors: [any UsageCollector]
    private let usageReindexCoordinator: UsageReindexCoordinator
    private let accountQuotaProviders: [any AccountQuotaProvider]
    private let scheduler: any RefreshScheduling
    private let watcherFactory: any SourceWatcherFactory
    private let accountQuotaCooldownStore: any AccountQuotaCooldownStore
    private let accountQuotaRetryPolicy: AccountQuotaRetryPolicy
    private let now: @Sendable () -> Date

    private var states: [Provider: CollectorState] = [:]
    private var latestBatches: [Provider: CollectorBatch] = [:]
    private var latestQuotaByProvider: [Provider: [QuotaSnapshot]] = [:]
    private var latestTokenObservedAtByProvider: [Provider: Date] = [:]
    private var lastLocalUsageRefreshAt: Date?
    private var accountRefreshStates: [Provider: AccountRefreshState] = [:]
    private var authorizedAccountProviders: Set<Provider>
    private var fallbackTimer: (any RefreshCancellation)?
    private var accountRefreshTimer: (any RefreshCancellation)?
    private var debounceTimer: (any RefreshCancellation)?
    private var sourceWatchers: [any SourceWatching] = []
    private var configurationGeneration: UInt64 = 0
    private var latestRefreshGeneration: UInt64 = 0
    private var refreshObserver: (@Sendable () async -> Void)?

    public init(
        store: UsageStore,
        collectors: [any UsageCollector],
        accountQuotaProviders: [any AccountQuotaProvider] = [],
        scheduler: any RefreshScheduling = DispatchRefreshScheduler(),
        watcherFactory: any SourceWatcherFactory = DispatchSourceWatcherFactory(),
        accountQuotaCooldownStore: any AccountQuotaCooldownStore = InMemoryAccountQuotaCooldownStore(),
        accountQuotaRetryPolicy: AccountQuotaRetryPolicy = AccountQuotaRetryPolicy(),
        authorizedAccountProviders: Set<Provider> = [],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.collectors = collectors
        usageReindexCoordinator = UsageReindexCoordinator(
            store: store,
            backupDirectory: store.accountingBackupDirectory
        )
        self.accountQuotaProviders = accountQuotaProviders
        self.scheduler = scheduler
        self.watcherFactory = watcherFactory
        self.accountQuotaCooldownStore = accountQuotaCooldownStore
        self.accountQuotaRetryPolicy = accountQuotaRetryPolicy
        self.authorizedAccountProviders = authorizedAccountProviders
        self.now = now
    }

    public func start(
        profile: RefreshProfile,
        liveQuotaRefreshInterval: LiveQuotaRefreshInterval = .manual,
        authorizedAccountProviders: Set<Provider>? = nil
    ) async {
        configure(
            profile: profile,
            liveQuotaRefreshInterval: liveQuotaRefreshInterval,
            authorizedAccountProviders: authorizedAccountProviders
        )
        await refresh(includingAccountQuota: true, forceAccountQuota: false)
    }

    public func requestRefresh() async {
        await refresh(includingAccountQuota: true)
    }

    public func requestAccountRefresh(for provider: Provider) async {
        await refreshAccountQuota(only: provider, force: true)
        await refreshObserver?()
    }

    public func setRefreshObserver(_ observer: (@Sendable () async -> Void)?) {
        refreshObserver = observer
    }

    public func configure(
        profile: RefreshProfile,
        liveQuotaRefreshInterval: LiveQuotaRefreshInterval = .manual,
        authorizedAccountProviders: Set<Provider>? = nil
    ) {
        if let authorizedAccountProviders {
            self.authorizedAccountProviders = authorizedAccountProviders
        }
        configurationGeneration += 1
        let callbackGeneration = configurationGeneration

        fallbackTimer?.cancel()
        fallbackTimer = nil
        accountRefreshTimer?.cancel()
        accountRefreshTimer = nil
        debounceTimer?.cancel()
        debounceTimer = nil
        sourceWatchers.forEach { $0.cancel() }
        sourceWatchers = []

        if let interval = profile.fallbackInterval {
            fallbackTimer = scheduler.schedule(
                after: interval,
                repeatingEvery: interval
            ) { [weak self] in
                Task {
                    await self?.refreshFromCallback(generation: callbackGeneration)
                }
            }
        }

        let hasAuthorizedAccountProvider = accountQuotaProviders.contains {
            self.authorizedAccountProviders.contains($0.provider)
        }
        if let interval = liveQuotaRefreshInterval.interval, hasAuthorizedAccountProvider {
            accountRefreshTimer = scheduler.schedule(
                after: interval,
                repeatingEvery: interval
            ) { [weak self] in
                Task {
                    await self?.accountRefreshFromCallback(generation: callbackGeneration)
                }
            }
        }

        if profile != .manual {
            sourceWatchers = watcherFactory.watch(
                directories: sourceDirectories()
            ) { [weak self] in
                Task {
                    await self?.sourceDidChange(generation: callbackGeneration)
                }
            }
        }
    }

    public func refresh(
        includingAccountQuota: Bool = false,
        forceAccountQuota: Bool = true
    ) async {
        try? await ensureCurrentTranscriptAccounting()
        latestRefreshGeneration += 1
        let refreshGeneration = latestRefreshGeneration

        for collector in collectors {
            let provider = collector.provider

            do {
                let batch = try await collector.collect(into: store)
                guard isCurrentRefresh(refreshGeneration) else {
                    return
                }
                if !batch.isPersisted {
                    try await store.save(tokens: batch.tokens, quota: batch.quota)
                }
                guard isCurrentRefresh(refreshGeneration) else {
                    return
                }
                let quota = try await resolvedQuota(for: provider, collectedQuota: batch.quota)
                latestBatches[provider] = batch
                latestQuotaByProvider[provider] = quota
                if let latestTokenObservedAt = batch.tokens.map(\.observedAt).max() {
                    latestTokenObservedAtByProvider[provider] = latestTokenObservedAt
                } else if let latestTokenObservedAt = try await store.latestTokenObservedAt(provider: provider) {
                    latestTokenObservedAtByProvider[provider] = latestTokenObservedAt
                }
                states[provider] = calculatedState(
                    for: quota,
                    latestTokenObservedAt: latestTokenObservedAtByProvider[provider],
                    at: now()
                )
            } catch {
                guard isCurrentRefresh(refreshGeneration) else {
                    return
                }
                let quota = (try? await store.latestQuota(provider: provider)) ?? []
                guard isCurrentRefresh(refreshGeneration) else {
                    return
                }
                latestQuotaByProvider[provider] = quota
                states[provider] = .sourceChanged
            }
        }

        if !collectors.isEmpty, isCurrentRefresh(refreshGeneration) {
            lastLocalUsageRefreshAt = now()
        }

        if includingAccountQuota {
            await refreshAccountQuota(force: forceAccountQuota)
        }
    }

    public func state(for provider: Provider, at date: Date? = nil) -> CollectorState {
        if states[provider] == .sourceChanged {
            return .sourceChanged
        }
        return calculatedState(
            for: latestQuotaByProvider[provider] ?? [],
            latestTokenObservedAt: latestTokenObservedAtByProvider[provider],
            at: date ?? now()
        )
    }

    public func latestQuota(provider: Provider) -> [QuotaSnapshot] {
        latestQuotaByProvider[provider] ?? []
    }

    public func latestBatch(provider: Provider) -> CollectorBatch? {
        latestBatches[provider]
    }

    public func localUsageRefreshAt() -> Date? {
        lastLocalUsageRefreshAt
    }

    public func connectionReport(for provider: Provider) -> ProviderConnectionReport? {
        accountRefreshStates[provider]?.report
    }

    public func summary(for provider: Provider, at date: Date? = nil) -> ProviderSummary {
        ProviderSummary(
            provider: provider,
            tokens: latestBatches[provider]?.tokens ?? [],
            quota: latestQuotaByProvider[provider] ?? [],
            state: state(for: provider, at: date)
        )
    }

    public func quotaLimitPredictions(
        provider: Provider,
        source: QuotaSource? = nil,
        predictor: QuotaLimitPredictor = QuotaLimitPredictor(),
        at date: Date? = nil
    ) async throws -> [QuotaLimitPrediction] {
        let endDate = date ?? now()
        let startDate = endDate.addingTimeInterval(-predictor.lookback)
        var snapshots: [QuotaSnapshot] = []

        for window in QuotaWindow.allCases {
            snapshots += try await store.quotaHistory(
                provider: provider,
                window: window,
                from: startDate,
                to: endDate.addingTimeInterval(1)
            )
        }

        return predictor.predictions(
            for: snapshots,
            provider: provider,
            source: source
        )
    }

    private func sourceDirectories() -> [URL] {
        var paths: Set<String> = []
        return collectors.flatMap(\.sourceDirectories).filter { directory in
            paths.insert(directory.path).inserted
        }
    }

    private func ensureCurrentTranscriptAccounting() async throws {
        guard try await store.activeAccountingVersion()
                != UsageIndexVersion.transcriptAccountingV2.rawValue else {
            return
        }
        let collectors = self.collectors
        guard !collectors.flatMap(\.transcriptIndexSources).isEmpty else { return }
        _ = try await usageReindexCoordinator.run {
            collectors.flatMap(\.transcriptIndexSources)
        }
    }

    private func refreshFromCallback(generation: UInt64) async {
        guard generation == configurationGeneration else {
            return
        }
        await refresh()
        guard generation == configurationGeneration else {
            return
        }
        await refreshObserver?()
    }

    private func accountRefreshFromCallback(generation: UInt64) async {
        guard generation == configurationGeneration else {
            return
        }
        await refreshAccountQuota()
        guard generation == configurationGeneration else {
            return
        }
        await refreshObserver?()
    }

    private func refreshAccountQuota(only providerFilter: Provider? = nil, force: Bool = false) async {
        for provider in accountQuotaProviders
            where authorizedAccountProviders.contains(provider.provider)
                && (providerFilter == nil || provider.provider == providerFilter) {
            if !force,
               provider.provider == .claude,
               hasFreshLocalQuota(for: .claude) {
                continue
            }
            var refreshState = accountRefreshStates[provider.provider] ?? AccountRefreshState()
            if refreshState.retryNotBefore == nil,
               let persistedRetryNotBefore = accountQuotaCooldownStore.retryNotBefore(for: provider.provider) {
                if persistedRetryNotBefore > now() {
                    refreshState.retryNotBefore = persistedRetryNotBefore
                } else {
                    accountQuotaCooldownStore.setRetryNotBefore(nil, for: provider.provider)
                }
            }
            if refreshState.lastSucceededAt == nil {
                refreshState.lastSucceededAt = try? await store.latestQuota(provider: provider.provider)
                    .filter { $0.source == .account }
                    .map(\.observedAt)
                    .max()
            }
            if !force,
               let lastSucceededAt = refreshState.lastSucceededAt,
               (0..<provider.minimumRefreshInterval).contains(now().timeIntervalSince(lastSucceededAt)) {
                accountRefreshStates[provider.provider] = refreshState
                continue
            }
            if !force,
               let retryNotBefore = refreshState.retryNotBefore,
               retryNotBefore > now() {
                accountRefreshStates[provider.provider] = refreshState
                continue
            }
            do {
                let snapshots = try await provider.quotaSnapshots()
                guard !snapshots.isEmpty else {
                    throw CloudUsageClientError.noUsableQuota
                }
                try await store.save(tokens: [], quota: snapshots)
                let quota = try await store.latestQuota(provider: provider.provider)
                latestQuotaByProvider[provider.provider] = quota
                refreshState.failureCount = 0
                refreshState.retryNotBefore = nil
                accountQuotaCooldownStore.setRetryNotBefore(nil, for: provider.provider)
                refreshState.lastSucceededAt = now()
                refreshState.report = ProviderConnectionReport(
                    provider: provider.provider,
                    state: .connected,
                    source: provider.connectionSource,
                    checkedAt: now()
                )
                states[provider.provider] = calculatedState(
                    for: quota,
                    latestTokenObservedAt: latestTokenObservedAtByProvider[provider.provider],
                    at: now()
                )
            } catch {
                let failure = connectionFailure(for: error)
                refreshState.report = ProviderConnectionReport(
                    provider: provider.provider,
                    state: failure.state,
                    source: provider.connectionSource,
                    issue: failure.issue,
                    checkedAt: now()
                )
                refreshState.failureCount += 1
                let backoff = 60 * (1 << min(refreshState.failureCount - 1, 3))
                let currentDate = now()
                if case let CloudUsageClientError.rateLimited(retryAfter) = error {
                    let retryNotBefore = accountQuotaRetryPolicy.retryNotBefore(
                        retryAfter: retryAfter,
                        now: currentDate
                    )
                    refreshState.retryNotBefore = retryNotBefore
                    accountQuotaCooldownStore.setRetryNotBefore(
                        retryNotBefore,
                        for: provider.provider
                    )
                } else if case CloudUsageClientError.requestFailed(statusCode: 429) = error {
                    let retryNotBefore = accountQuotaRetryPolicy.retryNotBefore(
                        retryAfter: nil,
                        now: currentDate
                    )
                    refreshState.retryNotBefore = retryNotBefore
                    accountQuotaCooldownStore.setRetryNotBefore(
                        retryNotBefore,
                        for: provider.provider
                    )
                } else {
                    // A manual bypass reached the provider and received a
                    // definitive non-429 result. Do not let an obsolete
                    // persisted rate-limit gate suppress probes after relaunch.
                    accountQuotaCooldownStore.setRetryNotBefore(nil, for: provider.provider)
                    refreshState.retryNotBefore = currentDate.addingTimeInterval(TimeInterval(backoff))
                }
                let quota = (try? await store.latestQuota(provider: provider.provider)) ?? []
                latestQuotaByProvider[provider.provider] = quota
                states[provider.provider] = quota.isEmpty
                    ? .sourceChanged
                    : calculatedState(
                        for: quota,
                        latestTokenObservedAt: latestTokenObservedAtByProvider[provider.provider],
                        at: now()
                    )
            }
            accountRefreshStates[provider.provider] = refreshState
        }
    }

    private func connectionFailure(for error: any Error) -> ConnectionFailure {
        guard let error = error as? CloudUsageClientError else {
            return ConnectionFailure(state: .unavailable, issue: .unavailable)
        }
        switch error {
        case .credentialUnavailable:
            return ConnectionFailure(state: .authenticationRequired, issue: .credentialsMissing)
        case .credentialAccessDenied:
            return ConnectionFailure(state: .permissionRequired, issue: .keychainAccessDenied)
        case .credentialExpired:
            return ConnectionFailure(state: .authenticationRequired, issue: .credentialExpired)
        case .mcpOnlyCredential:
            return ConnectionFailure(state: .authenticationRequired, issue: .mcpOnlyCredential)
        case .insufficientScope:
            return ConnectionFailure(state: .permissionRequired, issue: .insufficientScope)
        case .clientUnavailable, .timedOut:
            return ConnectionFailure(
                state: .unavailable,
                issue: error == .clientUnavailable ? .clientMissing : .timedOut
            )
        case .requestFailed(statusCode: 401):
            return ConnectionFailure(state: .authenticationRequired, issue: .unauthorized)
        case .requestFailed(statusCode: 403):
            return ConnectionFailure(state: .permissionRequired, issue: .permissionDenied)
        case .requestFailed(statusCode: 429):
            return ConnectionFailure(state: .rateLimited, issue: .rateLimited)
        case .rateLimited:
            return ConnectionFailure(state: .rateLimited, issue: .rateLimited)
        case .invalidResponse:
            return ConnectionFailure(state: .unavailable, issue: .invalidResponse)
        case .noUsableQuota:
            return ConnectionFailure(state: .unavailable, issue: .noUsableQuota)
        case .invalidBaseURL:
            return ConnectionFailure(state: .unavailable, issue: .unavailable)
        case .requestFailed(statusCode: _):
            return ConnectionFailure(state: .unavailable, issue: .requestRejected)
        }
    }

    private func sourceDidChange(generation: UInt64) {
        guard generation == configurationGeneration else {
            return
        }
        debounceTimer?.cancel()
        debounceTimer = scheduler.schedule(
            after: 5,
            repeatingEvery: nil
        ) { [weak self] in
            Task {
                await self?.refreshFromCallback(generation: generation)
            }
        }
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        generation == latestRefreshGeneration
    }

    private func resolvedQuota(
        for provider: Provider,
        collectedQuota _: [QuotaSnapshot]
    ) async throws -> [QuotaSnapshot] {
        return try await store.latestQuota(provider: provider, at: now())
    }

    private func hasFreshLocalQuota(for provider: Provider) -> Bool {
        latestBatches[provider]?.quota.contains {
            $0.source == .local && $0.isCurrent(at: now())
        } ?? false
    }

    private func calculatedState(
        for quota: [QuotaSnapshot],
        latestTokenObservedAt: Date?,
        at date: Date
    ) -> CollectorState {
        guard let latestSnapshot = quota.max(by: { $0.observedAt < $1.observedAt }) else {
            guard let latestTokenObservedAt else {
                return .unavailable
            }
            let age = date.timeIntervalSince(latestTokenObservedAt)
            return age >= 0 && age <= 600 ? .fresh : .stale
        }
        return latestSnapshot.freshness(at: date) == .fresh ? .fresh : .stale
    }
}

private final class DispatchCancellation: RefreshCancellation, @unchecked Sendable {
    private let operation: @Sendable () -> Void

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func cancel() {
        operation()
    }
}

private final class DispatchDirectoryWatch: SourceWatching, @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject

    init(
        descriptor: Int32,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        self.source = source
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}
