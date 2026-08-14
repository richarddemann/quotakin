import Combine
import Foundation
import UsageCore

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: UserPreferences {
        didSet {
            let enabledFirstAlert = oldValue.notificationPreferences.enabledKinds.isEmpty
                && !preferences.notificationPreferences.enabledKinds.isEmpty
            persistPreferences()
            if enabledFirstAlert {
                Task {
                    await notificationPoster.requestAuthorization()
                    await refreshNotificationAuthorizationState()
                }
            }
            guard
                oldValue.refreshProfile != preferences.refreshProfile
                    || oldValue.liveQuotaRefreshInterval != preferences.liveQuotaRefreshInterval,
                let refreshCoordinator
            else {
                return
            }
            Task {
                await refreshCoordinator.configure(
                    profile: preferences.refreshProfile,
                    liveQuotaRefreshInterval: preferences.liveQuotaRefreshInterval,
                    authorizedAccountProviders: preferences.accountQuotaConsents
                )
                statusMessage = "Refresh settings updated."
            }
        }
    }

    @Published private(set) var providerSummaries: [ProviderSummary]
    /// When each provider's quota window last reset (a refill). Drives the pet
    /// celebration; updated on the refresh loop via `QuotaResetDetector`.
    @Published private(set) var lastWindowResetAt: [Provider: Date] = [:]
    @Published private(set) var dashboardOverviews: [ProviderUsageOverview] = []
    @Published private(set) var collectorDiagnostics: [CollectorDiagnostic] = []
    @Published private(set) var providerConnectionReports: [Provider: ProviderConnectionReport] = [:]
    @Published private(set) var statusMessage: String
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastLocalUsageRefreshAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var checkingProviders: Set<Provider> = []
    @Published private(set) var manualConnectionCheckTimestamps: [Provider: Date] = [:]
    @Published private(set) var providerSignInStates: [Provider: ProviderSignInState] = [:]
    @Published private(set) var bootstrapState: AppBootstrapState = .idle
    @Published private(set) var metricOrder: [MenuBarMetric]
    @Published private(set) var providerStatuses: [Provider: ProviderStatus]
    @Published private(set) var shouldAutomaticallyPresentOnboarding = false
    @Published private(set) var onboardingPresentationRequest = 0
    @Published var historyRange: UsageHistoryRange = .thirtyDays {
        didSet {
            Task {
                await reloadDashboard()
            }
        }
    }
    @Published private(set) var historySeries: UsageHistorySeries?
    @Published private(set) var activityGrid: DailyActivityGrid?
    @Published private(set) var predictions: [QuotaLimitPrediction] = []
    @Published var helperConfirmation: HelperConfirmation?
    @Published private(set) var notificationAuthorizationState: NotificationAuthorizationState = .unknown

    @Published private(set) var pricingCatalog: PricingCatalog
    var formatter: MenuBarFormatter { MenuBarFormatter(pricingCatalog: pricingCatalog) }

    var disabledMenuBarMetrics: [MenuBarMetric] {
        metricOrder.filter { !preferences.menuBarMetrics.contains($0) }
    }

    var visibleProviderSummaries: [ProviderSummary] {
        let selectedProviders = preferences.providers
        guard !selectedProviders.isEmpty else {
            return []
        }
        return providerSummaries.filter { selectedProviders.contains($0.provider) }
    }

    private var store: UsageStore?
    private var refreshCoordinator: RefreshCoordinator?
    private var providerStatusPoller: ProviderStatusPoller?
    private let defaults: UserDefaults
    private let notificationPoster: any QuotaNotificationPosting
    private let providerSignInRunner: any ProviderSignInRunning
    private let credentialAccessAuthorizer: any ProviderCredentialAccessAuthorizing
    private let pricingCatalogLoader: (any PricingCatalogLoading)?
    private var providerSignInTasks: [Provider: Task<Void, Never>] = [:]
    private var notificationPolicyState = QuotaNotificationPolicyState()
    private var lastNotificationSnapshots: [QuotaSnapshot] = []
    private var hasPersistedNotificationState = false
    private var hasStarted = false

    init(
        pricingCatalog: PricingCatalog = .bundled,
        preferences: UserPreferences = .default,
        metricOrder: [MenuBarMetric]? = nil,
        defaults: UserDefaults = .standard,
        statusMessage: String = "Loading usage store...",
        notificationPoster: any QuotaNotificationPosting = UserNotificationsQuotaPoster(),
        providerSignInRunner: any ProviderSignInRunning = CLIProviderSignInRunner(),
        credentialAccessAuthorizer: any ProviderCredentialAccessAuthorizing = LiveProviderCredentialAccessAuthorizer(),
        pricingCatalogLoader: (any PricingCatalogLoading)? = nil,
        refreshCoordinator: RefreshCoordinator? = nil
    ) {
        let onboardingDecision = OnboardingLaunchDecision.evaluate(defaults: defaults)
        shouldAutomaticallyPresentOnboarding = onboardingDecision.shouldPresentAutomatically
        switch onboardingDecision {
        case .newInstall:
            defaults.set(true, forKey: OnboardingLaunchDecision.startedKey)
        case .existingInstall:
            // Migrate existing installations so adding onboarding never turns
            // into a surprise after unrelated preferences are cleared later.
            defaults.set(true, forKey: OnboardingLaunchDecision.completionKey)
        case .incomplete, .completed:
            break
        }
        self.pricingCatalog = pricingCatalog
        let normalizedPreferences = AppBootstrap.normalizedPreferences(preferences)
        self.preferences = normalizedPreferences
        self.metricOrder = AppBootstrap.normalizedMetricOrder(
            metricOrder,
            preferences: normalizedPreferences
        )
        self.defaults = defaults
        self.notificationPoster = notificationPoster
        self.providerSignInRunner = providerSignInRunner
        self.credentialAccessAuthorizer = credentialAccessAuthorizer
        self.pricingCatalogLoader = pricingCatalogLoader
        self.refreshCoordinator = refreshCoordinator
        self.statusMessage = statusMessage
        providerSummaries = Provider.allCases.map {
            ProviderSummary(provider: $0, tokens: [], quota: [], state: .unavailable)
        }
        providerStatuses = Dictionary(
            uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderStatus.unknown) }
        )
    }

    static func live() -> AppModel {
        // Public v0.1 uses the reviewed bundled catalogue. A mutable remote
        // pricing feed must not silently change locally displayed estimates.
        AppModel()
    }

    /// Consumes the one automatic presentation for this process. Completion
    /// is persisted separately so an interrupted first run resumes next launch.
    func consumeAutomaticOnboardingPresentation() -> Bool {
        guard shouldAutomaticallyPresentOnboarding else {
            return false
        }
        shouldAutomaticallyPresentOnboarding = false
        return true
    }

    /// Requests onboarding from any surface, including Settings. The app-level
    /// launch observer owns `openWindow` and accessory-app focus handling.
    func showOnboarding() {
        onboardingPresentationRequest &+= 1
    }

    func completeOnboarding() {
        defaults.set(true, forKey: OnboardingLaunchDecision.completionKey)
        defaults.removeObject(forKey: OnboardingLaunchDecision.startedKey)
        shouldAutomaticallyPresentOnboarding = false
    }

    func bootstrap() async {
        switch bootstrapState {
        case .ready, .loading:
            return
        case .idle, .failed:
            break
        }

        bootstrapState = .loading
        statusMessage = "Loading usage store..."

        do {
            let environment = try await Task.detached(priority: .userInitiated) {
                try AppBootstrap.makeLiveEnvironment()
            }.value

            store = environment.store
            refreshCoordinator = environment.refreshCoordinator
            providerStatusPoller = environment.providerStatusPoller
            if let pricingCatalogLoader {
                pricingCatalog = await pricingCatalogLoader.load()
            }
            preferences = environment.preferences
            metricOrder = environment.metricOrder
            if let notificationState = environment.notificationState {
                notificationPolicyState = notificationState.policyState
                lastNotificationSnapshots = notificationState.lastSnapshots
                hasPersistedNotificationState = true
            } else {
                notificationPolicyState = QuotaNotificationPolicyState()
                lastNotificationSnapshots = []
                hasPersistedNotificationState = false
            }
            await installRefreshObserver(on: environment.refreshCoordinator)
            await installProviderStatusObserver(on: environment.providerStatusPoller)
            bootstrapState = .ready
            statusMessage = environment.statusMessage
            await reloadProviderSummaries()
            await reloadProviderStatuses()
            await reloadDashboard()
        } catch {
            bootstrapState = .failed("Usage store unavailable")
            statusMessage = "Usage store unavailable. Manual refresh is disabled for this launch."
        }
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        await bootstrap()
        guard let refreshCoordinator else {
            return
        }
        await performRefresh {
            await refreshCoordinator.start(
                profile: preferences.refreshProfile,
                liveQuotaRefreshInterval: preferences.liveQuotaRefreshInterval,
                authorizedAccountProviders: preferences.accountQuotaConsents
            )
        }
        await providerStatusPoller?.start()
        if let store {
            AppBootstrap.startCodexQuotaHistoryBackfillIfNeeded(store: store)
        }
    }

    func refreshNow() async {
        if refreshCoordinator == nil {
            await bootstrap()
        }
        guard let refreshCoordinator else {
            if case .loading = bootstrapState {
                statusMessage = "Usage store is still loading."
            } else {
                statusMessage = "Usage store unavailable. Manual refresh is disabled for this launch."
            }
            return
        }
        await performRefresh {
            await refreshCoordinator.requestRefresh()
        }
    }

    func setRefreshProfile(_ profile: RefreshProfile) {
        preferences.refreshProfile = profile
    }

    func setLiveQuotaRefreshInterval(_ interval: LiveQuotaRefreshInterval) {
        preferences.liveQuotaRefreshInterval = interval
    }

    func setRefreshSettings(
        localUsage: RefreshProfile,
        accountQuota: LiveQuotaRefreshInterval
    ) {
        var updated = preferences
        updated.refreshProfile = localUsage
        updated.liveQuotaRefreshInterval = accountQuota
        preferences = updated
    }

    func reloadDashboardData() async {
        await reloadDashboard()
    }

    func refreshNotificationAuthorizationState() async {
        notificationAuthorizationState = await notificationPoster.authorizationState()
    }

    func setMetric(_ metric: MenuBarMetric, isEnabled: Bool) {
        var metrics = preferences.menuBarMetrics.filter { $0 != metric }
        if isEnabled {
            metrics = inserting(metric, into: metrics)
        }
        preferences.menuBarMetrics = metrics
    }

    func setProvider(_ provider: Provider, isEnabled: Bool) {
        var providers = preferences.providers.filter { $0 != provider }
        if isEnabled {
            providers.append(provider)
        }
        preferences.providers = providers.sorted { first, second in
            let firstIndex = Provider.allCases.firstIndex(of: first) ?? 0
            let secondIndex = Provider.allCases.firstIndex(of: second) ?? 0
            return firstIndex < secondIndex
        }
    }

    /// Stops future account-wide probes without deleting cached quota or local
    /// history. Returning guarantees the active coordinator applied the filter.
    func stopAccountChecks(for provider: Provider) async {
        preferences.accountQuotaConsents.remove(provider)
        if let refreshCoordinator {
            await refreshCoordinator.configure(
                profile: preferences.refreshProfile,
                liveQuotaRefreshInterval: preferences.liveQuotaRefreshInterval,
                authorizedAccountProviders: preferences.accountQuotaConsents
            )
        }
        statusMessage = "\(provider.displayName) account checks are off. Saved usage remains available."
    }

    func performSetupAction(_ action: ProviderSetupActionKind) async {
        switch action {
        case .signIn(let provider):
            await grantAccountQuotaConsent(to: provider)
            await beginSignIn(to: provider)
        case .checkConnection(let provider):
            await grantAccountQuotaConsent(to: provider)
            _ = await checkConnection(provider)
        case .authorizeClaudeAccount:
            await grantAccountQuotaConsent(to: .claude)
            await grantClaudeKeychainAccess()
        case .installClaudeFallback:
            requestInstallClaudeHelper()
        case .replaceClaudeFallback:
            requestReplaceClaudeHelper()
        case .uninstallClaudeFallback:
            requestUninstallClaudeHelper()
        }
    }

    private func grantAccountQuotaConsent(to provider: Provider) async {
        preferences.accountQuotaConsents.insert(provider)
        if let refreshCoordinator {
            await refreshCoordinator.configure(
                profile: preferences.refreshProfile,
                liveQuotaRefreshInterval: preferences.liveQuotaRefreshInterval,
                authorizedAccountProviders: preferences.accountQuotaConsents
            )
        }
    }

    private func beginSignIn(to provider: Provider) async {
        guard providerSignInTasks[provider] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.signIn(to: provider)
        }
        providerSignInTasks[provider] = task
        await task.value
        providerSignInTasks[provider] = nil
    }

    func cancelSignIn(for provider: Provider) {
        providerSignInTasks[provider]?.cancel()
        providerSignInStates[provider] = .failed("Sign-in was cancelled. You can try again whenever you're ready.")
    }

    private func signIn(to provider: Provider) async {
        guard providerSignInStates[provider]?.isActive != true else {
            return
        }
        providerSignInStates[provider] = .launching
        statusMessage = "Opening \(provider.displayName) sign-in…"
        await Task.yield()
        providerSignInStates[provider] = .waitingForBrowser

        let result = await providerSignInRunner.signIn(to: provider)
        guard !Task.isCancelled else {
            providerSignInStates[provider] = .failed(
                "Sign-in was cancelled. You can try again whenever you're ready."
            )
            return
        }
        switch result {
        case .clientMissing:
            providerSignInStates[provider] = .failed(
                "The \(provider.displayName) CLI is not installed where Quotakin can find it."
            )
        case .timedOut(let details):
            providerSignInStates[provider] = .failed(
                details.isEmpty ? "Sign-in timed out. You can try again." : details
            )
        case .failed(let details):
            providerSignInStates[provider] = .failed(details)
        case .cancelled:
            providerSignInStates[provider] = .failed(
                "Sign-in was cancelled. You can try again whenever you're ready."
            )
        case .authenticated(let details):
            if provider == .claude {
                providerSignInStates[provider] = .authorizingAccess
                let hasAccess = await credentialAccessAuthorizer.requestAccess(for: provider)
                guard !Task.isCancelled else {
                    providerSignInStates[provider] = .failed(
                        "Sign-in was cancelled. You can try again whenever you're ready."
                    )
                    return
                }
                guard hasAccess else {
                    providerSignInStates[provider] = .permissionRequired(
                        "Claude sign-in finished, but Quotakin still cannot read the saved Claude Code credential. Choose Grant Access and approve the Keychain prompt."
                    )
                    return
                }
            }
            providerSignInStates[provider] = .verifying
            let report = await checkConnection(provider)
            guard !Task.isCancelled else {
                providerSignInStates[provider] = .failed(
                    "Sign-in was cancelled. You can try again whenever you're ready."
                )
                return
            }
            if report?.state == .connected {
                providerSignInStates[provider] = .connected(
                    details.isEmpty ? "Live account quota is connected." : details
                )
            } else if report?.state == .rateLimited {
                providerSignInStates[provider] = .connected(
                    "Sign-in completed. The provider temporarily paused the quota check; Quotakin will retry."
                )
            } else {
                providerSignInStates[provider] = .failed(
                    "Sign-in completed, but live quota could not be verified. Check the details and try again."
                )
            }
        }
    }

    @discardableResult
    private func checkConnection(_ provider: Provider) async -> ProviderConnectionReport? {
        guard checkingProviders.insert(provider).inserted else {
            return providerConnectionReports[provider]
        }
        isRefreshing = true
        manualConnectionCheckTimestamps[provider] = nil
        defer {
            checkingProviders.remove(provider)
            isRefreshing = false
        }
        if refreshCoordinator == nil {
            await bootstrap()
        }
        guard let refreshCoordinator else {
            statusMessage = "Usage store unavailable. Connection check could not run."
            return nil
        }
        statusMessage = "Checking \(provider.displayName)…"
        await refreshCoordinator.requestAccountRefresh(for: provider)
        await reloadProviderSummaries()
        if let report = providerConnectionReports[provider] {
            statusMessage = Self.connectionCheckMessage(for: report)
            manualConnectionCheckTimestamps[provider] = report.checkedAt
            return report
        }
        statusMessage = "\(provider.displayName) did not return a connection result."
        return nil
    }

    private static func connectionCheckMessage(for report: ProviderConnectionReport) -> String {
        switch report.state {
        case .connected:
            return "\(report.provider.displayName) account quota connected."
        case .authenticationRequired:
            return "\(report.provider.displayName) needs sign-in or authorization."
        case .permissionRequired:
            return "\(report.provider.displayName) account access was denied."
        case .rateLimited:
            return "\(report.provider.displayName) account check was temporarily throttled."
        case .unavailable:
            return "\(report.provider.displayName) account check failed."
        }
    }

    func moveMetricUp(_ metric: MenuBarMetric) {
        moveMetric(metric, offset: -1)
    }

    func moveMetricDown(_ metric: MenuBarMetric) {
        moveMetric(metric, offset: 1)
    }

    /// User-initiated keychain grant: the only place the legacy-ACL prompt
    /// is allowed to appear. Background refreshes never prompt.
    func grantClaudeKeychainAccess() async {
        statusMessage = "Requesting keychain access..."
        if await credentialAccessAuthorizer.requestAccess(for: .claude) {
            providerSignInStates[.claude] = .verifying
            statusMessage = "Account access granted. Checking live quota..."
            let report = await checkConnection(.claude)
            if report?.state == .connected {
                providerSignInStates[.claude] = .connected("Live account quota is connected.")
            } else if report?.state == .rateLimited {
                providerSignInStates[.claude] = .connected(
                    "Account access is granted. Claude temporarily paused the quota check; Quotakin will retry."
                )
            } else {
                providerSignInStates[.claude] = .failed(
                    "Account access was granted, but live quota could not be verified."
                )
            }
        } else {
            statusMessage = "Keychain access was not granted. Claude account quota stays on local sources."
            providerSignInStates[.claude] = .permissionRequired(
                "Quotakin needs approval to read Claude Code's saved credential. Choose Grant Access and approve the Keychain prompt."
            )
        }
    }

    func requestInstallClaudeHelper() {
        helperConfirmation = HelperConfirmation(kind: .install)
    }

    func requestReplaceClaudeHelper() {
        helperConfirmation = HelperConfirmation(kind: .replaceInstall)
    }

    func requestUninstallClaudeHelper() {
        helperConfirmation = HelperConfirmation(kind: .uninstall)
    }

    func cancelHelperConfirmation() {
        helperConfirmation = nil
    }

    func confirmHelperAction(_ kind: HelperActionKind) async {
        helperConfirmation = nil
        statusMessage = "Running Claude helper \(kind.verb)..."

        let failureMessage = await Task.detached(priority: .userInitiated) {
            AppBootstrap.runHelperAction(kind)
        }.value

        if let message = failureMessage {
            statusMessage = "Claude helper \(kind.verb) failed: \(kind.failureGuidance(for: message))"
        } else {
            statusMessage = kind.successMessage
            await refreshNow()
        }
    }

    private func performRefresh(_ operation: () async -> Void) async {
        isRefreshing = true
        statusMessage = "Refreshing usage..."
        await operation()
        lastRefreshAt = Date()
        await decideAndPostNotifications()
        await reloadProviderSummaries()
        await reloadDashboard()
        statusMessage = "Last refreshed \(Self.shortTimeFormatter.string(from: lastRefreshAt ?? Date()))."
        isRefreshing = false
    }

    private func reloadProviderSummaries() async {
        guard let store, let refreshCoordinator else {
            providerSummaries = Provider.allCases.map {
                ProviderSummary(provider: $0, tokens: [], quota: [], state: .unavailable)
            }
            collectorDiagnostics = Provider.allCases.map {
                CollectorDiagnostic(provider: $0, state: .unavailable, sampleCount: 0, latestObservedAt: nil)
            }
            return
        }

        let now = Date()
        let summaryStart = Calendar.current.date(byAdding: .day, value: -35, to: now) ?? now
        var summaries: [ProviderSummary] = []
        var diagnostics: [CollectorDiagnostic] = []

        for provider in Provider.allCases {
            let tokens = (try? await store.tokenSamples(since: summaryStart, provider: provider)) ?? []
            let quota = await refreshCoordinator.latestQuota(provider: provider)
            let state = effectiveState(
                coordinatorState: await refreshCoordinator.state(for: provider, at: now),
                tokens: tokens,
                at: now
            )
            summaries.append(ProviderSummary(provider: provider, tokens: tokens, quota: quota, state: state))
            diagnostics.append(
                CollectorDiagnostic(
                    provider: provider,
                    state: state,
                    sampleCount: tokens.count,
                    latestObservedAt: Self.latestObservedAt(tokens: tokens, quota: quota)
                )
            )
            providerConnectionReports[provider] = await refreshCoordinator.connectionReport(for: provider)
        }

        providerSummaries = summaries
        collectorDiagnostics = diagnostics
        lastLocalUsageRefreshAt = await refreshCoordinator.localUsageRefreshAt()
    }

    private func reloadDashboard() async {
        guard let store else {
            dashboardOverviews = Provider.allCases.map {
                ProviderUsageOverview(provider: $0, samples: [], pricingCatalog: pricingCatalog)
            }
            historySeries = nil
            activityGrid = nil
            predictions = []
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let start = historyRange.startDate(endingAt: now, calendar: calendar)
        var overviews: [ProviderUsageOverview] = []

        for provider in Provider.allCases {
            let samples = (try? await store.tokenSamples(since: start, provider: provider)) ?? []
            overviews.append(ProviderUsageOverview(provider: provider, samples: samples, pricingCatalog: pricingCatalog))
        }

        dashboardOverviews = overviews
        historySeries = try? await store.usageHistorySeries(
            range: historyRange,
            endingAt: now,
            calendar: calendar,
            pricingCatalog: pricingCatalog
        )
        let year = calendar.component(.year, from: now)
        let gridStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let gridEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now
        activityGrid = try? await store.dailyActivityGrid(
            from: gridStart,
            through: gridEnd,
            calendar: calendar,
            pricingCatalog: pricingCatalog
        )

        if let refreshCoordinator {
            var collected: [QuotaLimitPrediction] = []
            for provider in Provider.allCases {
                collected += (try? await refreshCoordinator.quotaLimitPredictions(provider: provider)) ?? []
            }
            predictions = collected
        }
    }

    private func reloadProviderStatuses() async {
        guard let providerStatusPoller else {
            providerStatuses = Dictionary(
                uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderStatus.unknown) }
            )
            return
        }
        providerStatuses = await providerStatusPoller.currentStatuses()
    }

    private func installRefreshObserver(on coordinator: RefreshCoordinator) async {
        await coordinator.setRefreshObserver { [weak self] in
            await self?.backgroundRefreshCompleted()
        }
    }

    private func installProviderStatusObserver(on poller: ProviderStatusPoller) async {
        await poller.setObserver { [weak self] in
            await self?.providerStatusPollCompleted()
        }
    }

    private func backgroundRefreshCompleted() async {
        lastRefreshAt = Date()
        await decideAndPostNotifications()
        await reloadProviderSummaries()
        await reloadPredictions()
        statusMessage = "Last refreshed \(Self.shortTimeFormatter.string(from: lastRefreshAt ?? Date()))."
    }

    /// Predictions read only the 90-minute history lookback — cheap enough
    /// for every background refresh, unlike the full history reload.
    private func reloadPredictions() async {
        guard let refreshCoordinator else {
            return
        }
        var collected: [QuotaLimitPrediction] = []
        for provider in Provider.allCases {
            collected += (try? await refreshCoordinator.quotaLimitPredictions(provider: provider)) ?? []
        }
        predictions = collected
    }

    private func decideAndPostNotifications() async {
        guard let refreshCoordinator else {
            lastNotificationSnapshots = providerSummaries.flatMap(\.quota)
            hasPersistedNotificationState = true
            persistNotificationState()
            return
        }

        let currentSnapshots = await currentQuotaSnapshots(from: refreshCoordinator)

        guard hasPersistedNotificationState else {
            lastNotificationSnapshots = currentSnapshots
            hasPersistedNotificationState = true
            persistNotificationState()
            return
        }

        // Stamp window resets before the notification gate so the pet
        // celebration (which reuses this signal) fires even when notifications
        // are disabled. Runs on every refresh, popover open or not.
        let resetProviders = QuotaResetDetector.resetProviders(
            previous: lastNotificationSnapshots,
            current: currentSnapshots
        )
        if !resetProviders.isEmpty {
            let now = Date()
            for provider in resetProviders {
                lastWindowResetAt[provider] = now
            }
        }

        guard preferences.notificationPreferences.isEnabled else {
            lastNotificationSnapshots = currentSnapshots
            persistNotificationState()
            return
        }

        let predictions = await currentQuotaLimitPredictions(from: refreshCoordinator)
        let decision = QuotaNotificationPolicy.decide(
            previousSnapshots: lastNotificationSnapshots,
            currentSnapshots: currentSnapshots,
            predictions: predictions,
            preferences: preferences.notificationPreferences,
            state: notificationPolicyState,
            now: Date()
        )
        let delivered = await notificationPoster.post(decision.notifications)
        notificationPolicyState = Self.committedNotificationPolicyState(
            currentState: notificationPolicyState,
            decision: decision,
            notificationsDelivered: delivered
        )
        if Self.shouldAdvanceNotificationTracking(
            notifications: decision.notifications,
            notificationsDelivered: delivered
        ) {
            lastNotificationSnapshots = currentSnapshots
        }
        persistNotificationState()
    }

    private func currentQuotaSnapshots(from refreshCoordinator: RefreshCoordinator) async -> [QuotaSnapshot] {
        var snapshots: [QuotaSnapshot] = []
        for provider in Provider.allCases {
            snapshots += await refreshCoordinator.latestQuota(provider: provider)
        }
        return snapshots
    }

    private func currentQuotaLimitPredictions(
        from refreshCoordinator: RefreshCoordinator
    ) async -> [QuotaLimitPrediction] {
        var predictions: [QuotaLimitPrediction] = []
        for provider in Provider.allCases {
            predictions += (try? await refreshCoordinator.quotaLimitPredictions(provider: provider)) ?? []
        }
        return predictions
    }

    private func providerStatusPollCompleted() async {
        await reloadProviderStatuses()
    }

    private func effectiveState(
        coordinatorState: CollectorState,
        tokens: [TokenSample],
        at date: Date
    ) -> CollectorState {
        guard coordinatorState == .unavailable else {
            return coordinatorState
        }
        guard let latestTokenObservedAt = tokens.map(\.observedAt).max() else {
            return .unavailable
        }
        let age = date.timeIntervalSince(latestTokenObservedAt)
        return age >= 0 && age <= 600 ? .fresh : .stale
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: AppBootstrap.preferencesKey)
    }

    private func persistMetricOrder() {
        guard let data = try? JSONEncoder().encode(metricOrder) else {
            return
        }
        defaults.set(data, forKey: AppBootstrap.metricOrderKey)
    }

    private func persistNotificationState() {
        let state = PersistedNotificationState(
            policyState: notificationPolicyState,
            lastSnapshots: lastNotificationSnapshots
        )
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: AppBootstrap.notificationStateKey)
    }

    static func committedNotificationPolicyState(
        currentState: QuotaNotificationPolicyState,
        decision: QuotaNotificationDecision,
        notificationsDelivered: Bool
    ) -> QuotaNotificationPolicyState {
        shouldAdvanceNotificationTracking(
            notifications: decision.notifications,
            notificationsDelivered: notificationsDelivered
        ) ? decision.state : currentState
    }

    static func shouldAdvanceNotificationTracking(
        notifications: [QuotaNotification],
        notificationsDelivered: Bool
    ) -> Bool {
        notifications.isEmpty || notificationsDelivered
    }

    private func moveMetric(_ metric: MenuBarMetric, offset: Int) {
        guard
            let currentIndex = preferences.menuBarMetrics.firstIndex(of: metric)
        else {
            return
        }

        let newIndex = currentIndex + offset
        guard preferences.menuBarMetrics.indices.contains(newIndex) else {
            return
        }

        let target = preferences.menuBarMetrics[newIndex]
        var order = metricOrder.filter { $0 != metric }
        guard let targetIndex = order.firstIndex(of: target) else {
            return
        }

        order.insert(metric, at: offset < 0 ? targetIndex : targetIndex + 1)
        metricOrder = AppBootstrap.normalizedMetricOrder(order, preferences: preferences)
        persistMetricOrder()
        preferences.menuBarMetrics = sortedEnabledMetrics(preferences.menuBarMetrics)
    }

    private func inserting(_ metric: MenuBarMetric, into enabledMetrics: [MenuBarMetric]) -> [MenuBarMetric] {
        sortedEnabledMetrics(enabledMetrics + [metric])
    }

    private func sortedEnabledMetrics(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        let orderByMetric = Dictionary(uniqueKeysWithValues: metricOrder.enumerated().map { ($0.element, $0.offset) })
        return AppBootstrap.uniqueMetrics(metrics).sorted {
            (orderByMetric[$0] ?? Int.max) < (orderByMetric[$1] ?? Int.max)
        }
    }

    private static func latestObservedAt(tokens: [TokenSample], quota: [QuotaSnapshot]) -> Date? {
        (tokens.map(\.observedAt) + quota.map(\.observedAt)).max()
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

enum AppBootstrapState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

private struct AppBootstrapEnvironment: Sendable {
    let store: UsageStore
    let refreshCoordinator: RefreshCoordinator
    let providerStatusPoller: ProviderStatusPoller
    let preferences: UserPreferences
    let metricOrder: [MenuBarMetric]
    let notificationState: PersistedNotificationState?
    let statusMessage: String
}

private struct PersistedNotificationState: Codable, Sendable {
    let policyState: QuotaNotificationPolicyState
    let lastSnapshots: [QuotaSnapshot]
}

private struct AppStoreResult: Sendable {
    let store: UsageStore
    let statusMessage: String
}

private enum AppBootstrapError: Error {
    case storeUnavailable
}

private enum AppBootstrap {
    static let preferencesKey = "UsageBar.UserPreferences.v1"
    static let metricOrderKey = "UsageBar.MenuBarMetricOrder.v1"
    static let notificationStateKey = "UsageBar.NotificationState.v1"
    static let codexQuotaHistoryBackfillKey = "UsageBar.CodexQuotaHistoryBackfill.v1"

    static func makeLiveEnvironment() throws -> AppBootstrapEnvironment {
        let defaults = UserDefaults.standard
        let preferences = loadPreferences(defaults: defaults)
        let metricOrder = loadMetricOrder(defaults: defaults, preferences: preferences)
        let notificationState = loadNotificationState(defaults: defaults)
        let installer = ClaudeStatusLineInstaller()
        let storeResult = try makeLiveStore()
        let coordinator = RefreshCoordinator(
            store: storeResult.store,
            collectors: [
                ClaudeCollector(
                    quotaSnapshotURL: installer.snapshotURL
                ),
                CodexCollector()
            ],
            accountQuotaProviders: [
                ClaudeCodeOAuthQuotaProvider(),
                CodexAccountQuotaProvider()
            ],
            accountQuotaCooldownStore: UserDefaultsAccountQuotaCooldownStore(defaults: defaults),
            authorizedAccountProviders: preferences.accountQuotaConsents
        )
        let statusPoller = ProviderStatusPoller()

        return AppBootstrapEnvironment(
            store: storeResult.store,
            refreshCoordinator: coordinator,
            providerStatusPoller: statusPoller,
            preferences: preferences,
            metricOrder: metricOrder,
            notificationState: notificationState,
            statusMessage: storeResult.statusMessage
        )
    }

    static func runHelperAction(_ kind: HelperActionKind) -> String? {
        do {
            switch kind {
            case .install, .replaceInstall:
                try ClaudeStatusLineInstaller().install(
                    replacingExistingStatusLine: kind.replacesExistingStatusLine
                )
            case .uninstall:
                try ClaudeStatusLineInstaller().uninstall()
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @MainActor
    static func startCodexQuotaHistoryBackfillIfNeeded(store: UsageStore) {
        guard !UserDefaults.standard.bool(forKey: codexQuotaHistoryBackfillKey) else {
            return
        }

        let key = codexQuotaHistoryBackfillKey
        Task.detached(priority: .utility) {
            do {
                _ = try await CodexQuotaHistoryBackfill().run(into: store)
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: key)
                }
            } catch {
                await MainActor.run {
                    UserDefaults.standard.set(false, forKey: key)
                }
            }
        }
    }

    static func loadPreferences(defaults: UserDefaults) -> UserPreferences {
        guard
            let data = defaults.data(forKey: preferencesKey),
            let preferences = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else {
            return .default
        }
        return normalizedPreferences(preferences)
    }

    static func loadMetricOrder(defaults: UserDefaults, preferences: UserPreferences) -> [MenuBarMetric] {
        guard
            let data = defaults.data(forKey: metricOrderKey),
            let metricOrder = try? JSONDecoder().decode([MenuBarMetric].self, from: data)
        else {
            return normalizedMetricOrder(nil, preferences: preferences)
        }
        return normalizedMetricOrder(metricOrder, preferences: preferences)
    }

    static func loadNotificationState(defaults: UserDefaults) -> PersistedNotificationState? {
        guard
            let data = defaults.data(forKey: notificationStateKey),
            let state = try? JSONDecoder().decode(PersistedNotificationState.self, from: data)
        else {
            return nil
        }
        return state
    }

    static func normalizedPreferences(_ preferences: UserPreferences) -> UserPreferences {
        var normalized = preferences
        normalized.menuBarMetrics = uniqueMetrics(preferences.menuBarMetrics)
        if normalized.menuBarMetrics == [.sessionPercentage, .resetCountdown]
            || normalized.menuBarMetrics == [.sessionPercentage] {
            normalized.menuBarMetrics = []
        }
        return normalized
    }

    static func normalizedMetricOrder(_ metricOrder: [MenuBarMetric]?, preferences: UserPreferences) -> [MenuBarMetric] {
        uniqueMetrics((metricOrder ?? preferences.menuBarMetrics) + preferences.menuBarMetrics + MenuBarMetric.allCases)
    }

    static func uniqueMetrics(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen: Set<MenuBarMetric> = []
        return metrics.filter { seen.insert($0).inserted }
    }

    private static func makeLiveStore() throws -> AppStoreResult {
        let supportDirectory = AppSupportDirectory.current
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            return AppStoreResult(
                store: try UsageStore(path: supportDirectory.appending(path: "usage.sqlite3").path),
                statusMessage: "Ready."
            )
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appending(path: "usagebar-fallback.sqlite3")
            if let store = try? UsageStore(path: fallback.path) {
                return AppStoreResult(
                    store: store,
                    statusMessage: "Using a temporary usage store because the app store could not be opened."
                )
            }
            if let store = try? UsageStore.inMemory() {
                return AppStoreResult(
                    store: store,
                    statusMessage: "Using an in-memory usage store for this launch."
                )
            }
            throw AppBootstrapError.storeUnavailable
        }
    }
}

extension UsageHistoryRange: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHours:
            "5h"
        case .twentyFourHours:
            "24h"
        case .sevenDays:
            "7 days"
        case .thirtyDays:
            "30 days"
        case .ninetyDays:
            "90 days"
        }
    }

    var accessibleTitle: String {
        switch self {
        case .fiveHours:
            "Last 5 hours"
        case .twentyFourHours:
            "Last 24 hours"
        case .sevenDays:
            "Last 7 days"
        case .thirtyDays:
            "Last 30 days"
        case .ninetyDays:
            "Last 90 days"
        }
    }
}

struct ProviderUsageOverview: Identifiable {
    let provider: Provider
    let sampleCount: Int
    let totalTokens: Int
    let estimatedCost: Decimal
    let estimatedCostProvenance: UsageCostProvenance
    let modelRows: [ModelUsageRow]
    let categoryRows: [TokenCategoryRow]
    let trendPoints: [UsageTrendPoint]
    let unknownPricingCount: Int
    let uncachedInputTokens: Int
    let cachedInputTokens: Int
    let cacheCreationInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let cacheSavings: Decimal

    var id: Provider { provider }

    var primaryDriver: TokenCategoryRow? {
        categoryRows.max { $0.tokens < $1.tokens }
    }

    var primaryDriverSummary: String {
        guard let primaryDriver else {
            return "No local token samples in this range yet."
        }
        return "Most observed tokens came from \(primaryDriver.userFacingName.lowercased())."
    }

    init(provider: Provider, samples: [TokenSample], pricingCatalog: PricingCatalog) {
        self.provider = provider
        sampleCount = samples.count
        totalTokens = samples.reduce(0) { $0 + $1.totalTokens }

        var modelTotals: [String: Int] = [:]
        var modelCosts: [String: Decimal] = [:]
        var modelUnknownPricingCounts: [String: Int] = [:]
        var cost = Decimal(0)
        var cacheSavings = Decimal(0)
        var costProvenance: UsageCostProvenance = .unpriced
        var unknownPricingCount = 0
        var input = 0
        var output = 0
        var cachedInput = 0
        var cacheWrite = 0
        var reasoning = 0

        for sample in samples {
            modelTotals[sample.model, default: 0] += sample.totalTokens
            input += sample.inputTokens
            output += sample.outputTokens
            cachedInput += sample.cachedInputTokens
            cacheWrite += sample.cacheCreationInputTokens
            reasoning += sample.reasoningOutputTokens

            let estimate = pricingCatalog.costEstimate(for: sample)
            if let amount = estimate.amountUSD {
                cost += amount
                modelCosts[sample.model, default: 0] += amount
                costProvenance = estimate.provenance
            } else {
                unknownPricingCount += 1
                modelUnknownPricingCounts[sample.model, default: 0] += 1
            }
            cacheSavings += pricingCatalog.cacheSavings(for: sample) ?? 0
        }

        estimatedCost = cost
        estimatedCostProvenance = unknownPricingCount == 0 ? costProvenance : .unpriced
        self.unknownPricingCount = unknownPricingCount
        self.uncachedInputTokens = input
        self.cachedInputTokens = cachedInput
        self.cacheCreationInputTokens = cacheWrite
        self.outputTokens = output
        self.reasoningOutputTokens = reasoning
        self.cacheSavings = cacheSavings
        modelRows = modelTotals
            .map {
                ModelUsageRow(
                    model: $0.key,
                    tokens: $0.value,
                    estimatedCost: modelCosts[$0.key, default: 0],
                    unknownPricingCount: modelUnknownPricingCounts[$0.key, default: 0]
                )
            }
            .sorted { $0.tokens > $1.tokens }
        categoryRows = [
            TokenCategoryRow(name: "Input", tokens: input),
            TokenCategoryRow(name: "Cached", tokens: cachedInput),
            TokenCategoryRow(name: "Cache Write", tokens: cacheWrite),
            TokenCategoryRow(name: "Output", tokens: output),
            TokenCategoryRow(name: "Reasoning", tokens: reasoning)
        ].filter { $0.tokens > 0 }
        trendPoints = Self.makeTrendPoints(samples: samples)
    }

    private static func makeTrendPoints(samples: [TokenSample]) -> [UsageTrendPoint] {
        guard
            let earliest = samples.map(\.observedAt).min(),
            let latest = samples.map(\.observedAt).max()
        else {
            return []
        }

        let calendar = Calendar.current
        let span = latest.timeIntervalSince(earliest)
        let useHours = span <= 36 * 60 * 60

        let grouped = Dictionary(grouping: samples) { sample in
            if useHours {
                return calendar.dateInterval(of: .hour, for: sample.observedAt)?.start
                    ?? sample.observedAt
            }
            return calendar.startOfDay(for: sample.observedAt)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = useHours ? "HH" : "MMM d"

        return grouped
            .map { date, bucketSamples in
                UsageTrendPoint(
                    label: formatter.string(from: date),
                    tokens: bucketSamples.reduce(0) { $0 + $1.totalTokens },
                    date: date
                )
            }
            .sorted { $0.date < $1.date }
            .suffix(14)
            .enumerated()
            .map { index, point in
                UsageTrendPoint(label: point.label, tokens: point.tokens, date: point.date, index: index)
            }
    }
}

struct ModelUsageRow: Identifiable {
    let model: String
    let tokens: Int
    let estimatedCost: Decimal
    let unknownPricingCount: Int
    var id: String { model }
}

struct UsageTrendPoint: Identifiable {
    let label: String
    let tokens: Int
    let date: Date
    let index: Int

    init(label: String, tokens: Int, date: Date, index: Int = 0) {
        self.label = label
        self.tokens = tokens
        self.date = date
        self.index = index
    }

    var id: Int { index }
}

struct TokenCategoryRow: Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }

    var userFacingName: String {
        switch name {
        case "Input":
            "Sent context"
        case "Cached":
            "Cache reuse"
        case "Cache Write":
            "Cache setup"
        case "Output":
            "Generated text"
        case "Reasoning":
            "Reasoning"
        default:
            name
        }
    }

    var explanation: String {
        switch name {
        case "Input":
            "Fresh prompt, files, and context sent to the model."
        case "Cached":
            "Context the provider reused from cache. Large numbers here are usually cheaper than fresh input."
        case "Cache Write":
            "Context written into a provider cache so later turns can reuse it."
        case "Output":
            "Text generated back to you."
        case "Reasoning":
            "Hidden reasoning or deliberation tokens reported by the provider."
        default:
            "Provider-reported token category."
        }
    }
}

struct CollectorDiagnostic: Identifiable {
    let provider: Provider
    let state: CollectorState
    let sampleCount: Int
    let latestObservedAt: Date?
    var id: Provider { provider }
}

enum HelperActionKind: Sendable {
    case install
    case replaceInstall
    case uninstall

    var title: String {
        switch self {
        case .install:
            "Install Claude Helper?"
        case .replaceInstall:
            "Replace Claude Status Line?"
        case .uninstall:
            "Uninstall Claude Helper?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .install:
            "Install"
        case .replaceInstall:
            "Replace & Install"
        case .uninstall:
            "Uninstall"
        }
    }

    var verb: String {
        switch self {
        case .install, .replaceInstall:
            "install"
        case .uninstall:
            "uninstall"
        }
    }

    var replacesExistingStatusLine: Bool {
        if case .replaceInstall = self {
            return true
        }
        return false
    }

    var successMessage: String {
        switch self {
        case .install:
            "Claude helper installed. Claude will refresh Quotakin quota snapshots every 5 seconds while the status line is active."
        case .replaceInstall:
            "Claude helper installed after replacing the existing status line. Claude will refresh Quotakin quota snapshots every 5 seconds while the status line is active."
        case .uninstall:
            "Claude helper uninstalled."
        }
    }

    var message: String {
        switch self {
        case .install:
            """
            Quotakin will read and update Claude settings, write a status-line wrapper, extractor, metadata, and a quota snapshot in Application Support. The snapshot contains observedAt plus five-hour and seven-day usedPercent and resetsAt fields.

            If Claude already has a custom status-line command, Quotakin will store it so uninstall can restore it, but will not run that command during Quotakin's refresh loop.
            """
        case .replaceInstall:
            """
            Quotakin will replace Claude's existing status-line command with its own helper and ask Claude to rerun the status line every 5 seconds while the status line is active. It will not store or restore the previous command, because that command may contain private paths, arguments, or credentials.

            Uninstalling later removes Quotakin's status line instead of restoring the overwritten one.
            """
        case .uninstall:
            """
            Quotakin will read Claude settings and its metadata, remove Quotakin's generated status-line command, and remove the generated wrapper, extractor, metadata, and quota snapshot.
            """
        }
    }

    func failureGuidance(for message: String) -> String {
        if message.contains("statusLine changed") {
            return "Claude already has a custom status line. Use Replace & Install if you want Quotakin to overwrite it without storing the previous command."
        }
        return message
    }
}

struct HelperConfirmation: Identifiable {
    let id = UUID()
    let kind: HelperActionKind
}

extension Provider {
    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var neutralSymbolName: String {
        switch self {
        case .claude:
            "text.bubble"
        case .codex:
            "terminal"
        }
    }
}

extension QuotaWindow {
    var displayName: String {
        switch self {
        case .session:
            "Session"
        case .weekly:
            "Weekly"
        }
    }
}

extension CollectorState {
    var displayName: String {
        switch self {
        case .fresh:
            "Fresh"
        case .stale:
            "Stale"
        case .unavailable:
            "Unavailable"
        case .sourceChanged:
            "Updating"
        }
    }
}

extension RefreshProfile {
    var displayName: String {
        switch self {
        case .realTime:
            "Real Time"
        case .efficient:
            "Balanced"
        case .responsive:
            "Live-ish"
        case .manual:
            "Manual"
        }
    }

    var impact: RefreshImpact {
        switch self {
        case .realTime:
            RefreshImpact(
                cadence: "Every 5 minutes, plus coalesced file changes",
                checksPerHour: 12,
                checksPerDay: 288,
                performance: "Low",
                detail: "Best for active use. File changes stay responsive while safety scans remain infrequent."
            )
        case .efficient:
            RefreshImpact(
                cadence: "Every 15 minutes",
                checksPerHour: 4,
                checksPerDay: 96,
                performance: "Low",
                detail: "Good default. Uses filesystem events plus infrequent safety checks; no provider network calls."
            )
        case .responsive:
            RefreshImpact(
                cadence: "Every 10 minutes, plus coalesced file changes",
                checksPerHour: 6,
                checksPerDay: 144,
                performance: "Low",
                detail: "A balance between background quietness and a safety check when filesystem events are missed."
            )
        case .manual:
            RefreshImpact(
                cadence: "Only on click or file change",
                checksPerHour: 0,
                checksPerDay: 0,
                performance: "Lowest",
                detail: "Quietest mode. Use Refresh when you want a new read."
            )
        }
    }
}

struct RefreshImpact: Equatable {
    let cadence: String
    let checksPerHour: Int
    let checksPerDay: Int
    let performance: String
    let detail: String
}

extension MenuBarMetric {
    func displayName(quotaDisplayMode: QuotaDisplayMode = .remaining) -> String {
        switch self {
        case .sessionPercentage:
            "Session \(quotaDisplayMode.label)"
        case .resetCountdown:
            "Reset countdown"
        case .weeklyPercentage:
            "Weekly \(quotaDisplayMode.label)"
        case .dailyTokens:
            "Daily tokens"
        case .weeklyTokens:
            "Weekly tokens"
        case .monthlyTokens:
            "Monthly tokens"
        case .estimatedMonthlyCost:
            "Estimated monthly cost"
        }
    }

    var displayName: String {
        displayName()
    }
}

extension QuotaDisplayMode {
    var displayName: String {
        switch self {
        case .remaining:
            "Remaining"
        case .used:
            "Used"
        }
    }
}

extension LiveQuotaRefreshInterval {
    var displayName: String {
        switch self {
        case .oneMinute:
            "Every minute"
        case .fiveMinutes:
            "Every 5 min"
        case .fifteenMinutes:
            "Every 15 min"
        case .manual:
            "Manual"
        }
    }
}

extension Decimal {
    var usageCurrencyString: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }
}

extension Int {
    var compactTokenString: String {
        let value = Double(self)
        let divisor: Double
        let suffix: String
        switch abs(value) {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return self.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
        }
        let scaled = value / divisor
        let precision = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
        return scaled.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(precision))
        ) + suffix
    }
}
