import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func claudeSignInPlanUsesSubscriptionLogin() throws {
    let executable = URL(fileURLWithPath: "/tmp/.local/bin/claude")
    let resolver = ProviderSignInCommandResolver(
        isExecutable: { $0 == executable.path },
        homeDirectory: URL(fileURLWithPath: "/tmp")
    )

    let command = try #require(resolver.command(for: .claude))

    #expect(command.executableURL == executable)
    #expect(command.arguments == ["auth", "login", "--claudeai"])
    #expect(command.usesPseudoTerminal)
}

@Test
func codexSignInPlanUsesBrowserLogin() throws {
    let executable = URL(fileURLWithPath: "/tmp/.local/bin/codex")
    let resolver = ProviderSignInCommandResolver(
        isExecutable: { $0 == executable.path },
        homeDirectory: URL(fileURLWithPath: "/tmp")
    )

    let command = try #require(resolver.command(for: .codex))

    #expect(command.executableURL == executable)
    #expect(command.arguments == ["login"])
    #expect(command.usesPseudoTerminal == false)
}

@Test
func signInRunnerReportsSuccessAndKeepsSafeDetails() async {
    let command = ProviderSignInCommand(
        provider: .claude,
        executableURL: URL(fileURLWithPath: "/tmp/claude"),
        arguments: ["auth", "login", "--claudeai"],
        usesPseudoTerminal: true
    )
    let runner = CLIProviderSignInRunner(
        commandResolver: StubCommandResolver(command: command),
        processRunner: StubSignInProcessRunner(
            result: ProviderSignInProcessResult(exitCode: 0)
        )
    )

    let result = await runner.signIn(to: .claude)

    #expect(result == .authenticated(details: "Claude sign-in completed."))
}

@Test @MainActor
func appModelTurnsMissingProviderClientIntoGuidedFailure() async {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let model = AppModel(
        defaults: defaults,
        notificationPoster: StubNotificationPoster(),
        providerSignInRunner: StubProviderSignInRunner(result: .clientMissing)
    )

    await model.performSetupAction(.signIn(.claude))

    #expect(
        model.providerSignInStates[.claude]
            == .failed("The Claude CLI is not installed where Quotakin can find it.")
    )
    #expect(model.preferences.accountQuotaConsents == [.claude])
    let saved = defaults.data(forKey: "UsageBar.UserPreferences.v1").flatMap {
        try? JSONDecoder().decode(UserPreferences.self, from: $0)
    }
    #expect(saved?.accountQuotaConsents == [.claude])
}

@Test @MainActor
func appModelStopsAccountChecksAndPersistsRevokedConsent() async throws {
    let suiteName = #function
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = AppModel(
        preferences: UserPreferences(accountQuotaConsents: [.claude, .codex]),
        defaults: defaults,
        notificationPoster: StubNotificationPoster()
    )

    await model.stopAccountChecks(for: .claude)

    #expect(model.preferences.accountQuotaConsents == [.codex])
    #expect(model.statusMessage.contains("account checks are off"))
    let saved = try #require(defaults.data(forKey: "UsageBar.UserPreferences.v1"))
    let decoded = try JSONDecoder().decode(UserPreferences.self, from: saved)
    #expect(decoded.accountQuotaConsents == [.codex])
}

@Test @MainActor
func accountConsentActionsConfigureExactlyOnce() async throws {
    let stopScheduler = CountingRefreshScheduler()
    let stopCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        scheduler: stopScheduler
    )
    let stopModel = AppModel(
        preferences: UserPreferences(accountQuotaConsents: [.claude]),
        defaults: try #require(UserDefaults(suiteName: "\(#function).stop")),
        notificationPoster: StubNotificationPoster(),
        refreshCoordinator: stopCoordinator
    )

    await stopModel.stopAccountChecks(for: .claude)
    try await Task.sleep(for: .milliseconds(20))

    #expect(stopScheduler.scheduleCount == 1)
    #expect(stopModel.statusMessage.contains("account checks are off"))

    let connectScheduler = CountingRefreshScheduler()
    let connectCoordinator = RefreshCoordinator(
        store: try UsageStore.inMemory(),
        collectors: [],
        scheduler: connectScheduler
    )
    let connectModel = AppModel(
        defaults: try #require(UserDefaults(suiteName: "\(#function).connect")),
        notificationPoster: StubNotificationPoster(),
        providerSignInRunner: StubProviderSignInRunner(result: .clientMissing),
        refreshCoordinator: connectCoordinator
    )

    await connectModel.performSetupAction(.signIn(.claude))
    try await Task.sleep(for: .milliseconds(20))

    #expect(connectScheduler.scheduleCount == 1)
    #expect(connectModel.providerSignInStates[.claude]?.isActive == false)
}

@Test @MainActor
func appModelKeepsDeniedClaudeCredentialAccessActionable() async {
    let model = AppModel(
        defaults: UserDefaults(suiteName: #function)!,
        notificationPoster: StubNotificationPoster(),
        providerSignInRunner: StubProviderSignInRunner(
            result: .authenticated(details: "Claude sign-in completed.")
        ),
        credentialAccessAuthorizer: StubCredentialAccessAuthorizer(isAvailable: false)
    )

    await model.performSetupAction(.signIn(.claude))

    guard case .permissionRequired(let detail) = model.providerSignInStates[.claude] else {
        Issue.record("Expected a retryable permission state")
        return
    }
    #expect(detail.contains("Grant Access"))
}

@Test
func signInRunnerExplainsMissingCLI() async {
    let runner = CLIProviderSignInRunner(
        commandResolver: StubCommandResolver(command: nil),
        processRunner: StubSignInProcessRunner(
            result: ProviderSignInProcessResult(exitCode: 0)
        )
    )

    let result = await runner.signIn(to: .codex)

    #expect(result == .clientMissing)
}

@Test
func foundationSignInProcessRunnerTerminatesOnTimeout() async throws {
    let runner = FoundationProviderSignInProcessRunner(timeout: 0.05)
    let command = ProviderSignInCommand(
        provider: .codex,
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        usesPseudoTerminal: false
    )

    let result = try await runner.run(command)

    #expect(result.timedOut)
}

@Test
func foundationSignInProcessRunnerHonorsCancellation() async throws {
    let runner = FoundationProviderSignInProcessRunner(timeout: 5)
    let command = ProviderSignInCommand(
        provider: .codex,
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        usesPseudoTerminal: false
    )
    let task = Task {
        try await runner.run(command)
    }

    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let result = try await task.value

    #expect(result.cancelled)
}

private struct StubCommandResolver: ProviderSignInCommandResolving {
    let command: ProviderSignInCommand?

    func command(for provider: Provider) -> ProviderSignInCommand? {
        command
    }
}

private struct StubSignInProcessRunner: ProviderSignInProcessRunning {
    let result: ProviderSignInProcessResult

    func run(_ command: ProviderSignInCommand) async throws -> ProviderSignInProcessResult {
        result
    }
}

private struct StubProviderSignInRunner: ProviderSignInRunning {
    let result: ProviderSignInResult

    func signIn(to provider: Provider) async -> ProviderSignInResult {
        result
    }
}

private struct StubCredentialAccessAuthorizer: ProviderCredentialAccessAuthorizing {
    let isAvailable: Bool

    func requestAccess(for provider: Provider) async -> Bool {
        isAvailable
    }
}

private final class CountingRefreshScheduler: RefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var scheduleCount: Int {
        lock.withLock { count }
    }

    func schedule(
        after _: TimeInterval,
        repeatingEvery _: TimeInterval?,
        operation _: @escaping @Sendable () -> Void
    ) -> any RefreshCancellation {
        lock.withLock { count += 1 }
        return NoopRefreshCancellation()
    }
}

private struct NoopRefreshCancellation: RefreshCancellation {
    func cancel() {}
}

@MainActor
private final class StubNotificationPoster: QuotaNotificationPosting {
    func authorizationState() async -> NotificationAuthorizationState { .unknown }
    func requestAuthorization() async {}
    func post(_ notifications: [QuotaNotification]) async -> Bool { true }
}
