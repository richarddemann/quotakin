import Darwin
import Foundation
import UsageCore

struct ProviderSignInCommand: Equatable, Sendable {
    let provider: Provider
    let executableURL: URL
    let arguments: [String]
    let usesPseudoTerminal: Bool
}

protocol ProviderSignInCommandResolving: Sendable {
    func command(for provider: Provider) -> ProviderSignInCommand?
}

struct ProviderSignInCommandResolver: ProviderSignInCommandResolving {
    private let isExecutable: @Sendable (String) -> Bool
    private let homeDirectory: URL

    init(
        isExecutable: @escaping @Sendable (String) -> Bool = { access($0, X_OK) == 0 },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.isExecutable = isExecutable
        self.homeDirectory = homeDirectory
    }

    func command(for provider: Provider) -> ProviderSignInCommand? {
        let arguments: [String]
        let usesPseudoTerminal: Bool
        switch provider {
        case .claude:
            arguments = ["auth", "login", "--claudeai"]
            usesPseudoTerminal = true
        case .codex:
            arguments = ["login"]
            usesPseudoTerminal = false
        }

        let candidates = ProviderCLIExecutableLocator.candidates(
            for: provider,
            homeDirectory: homeDirectory
        )
        guard let executableURL = candidates.first(where: { isExecutable($0.path) }) else {
            return nil
        }
        return ProviderSignInCommand(
            provider: provider,
            executableURL: executableURL,
            arguments: arguments,
            usesPseudoTerminal: usesPseudoTerminal
        )
    }
}

struct ProviderSignInProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let timedOut: Bool
    let cancelled: Bool

    init(exitCode: Int32, timedOut: Bool = false, cancelled: Bool = false) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

protocol ProviderSignInProcessRunning: Sendable {
    func run(_ command: ProviderSignInCommand) async throws -> ProviderSignInProcessResult
}

struct FoundationProviderSignInProcessRunner: ProviderSignInProcessRunning {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 180) {
        self.timeout = timeout
    }

    func run(_ command: ProviderSignInCommand) async throws -> ProviderSignInProcessResult {
        let timeout = self.timeout
        let controller = ProviderSignInProcessController()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                if command.usesPseudoTerminal {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
                    process.arguments = ["-q", "/dev/null", command.executableURL.path] + command.arguments
                } else {
                    process.executableURL = command.executableURL
                    process.arguments = command.arguments
                }

                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let appPaths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                let existingPath = environment["PATH"] ?? ""
                environment["PATH"] = (appPaths + [existingPath]).joined(separator: ":")
                environment["TERM"] = environment["TERM"] ?? "xterm-256color"
                process.environment = environment

                let input = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = command.usesPseudoTerminal ? input : FileHandle.nullDevice

                try process.run()
                controller.attach(process)
                if command.usesPseudoTerminal {
                    usleep(500_000)
                    try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                    try? input.fileHandleForWriting.close()
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning
                    && Date() < deadline
                    && !controller.isCancellationRequested
                {
                    usleep(100_000)
                }
                let cancelled = controller.isCancellationRequested
                let timedOut = process.isRunning && !cancelled
                if timedOut || cancelled {
                    controller.terminate()
                    let terminationDeadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < terminationDeadline {
                        usleep(100_000)
                    }
                    if process.isRunning {
                        controller.forceTerminate()
                    }
                }
                process.waitUntilExit()
                return ProviderSignInProcessResult(
                    exitCode: process.terminationStatus,
                    timedOut: timedOut,
                    cancelled: cancelled
                )
            }.value
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class ProviderSignInProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    var isCancellationRequested: Bool {
        lock.lock()
        let value = cancellationRequested
        lock.unlock()
        return value
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancellationRequested
        lock.unlock()
        if shouldTerminate {
            terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
        terminate()
    }

    func terminate() {
        guard let process = currentProcess(), process.isRunning else { return }
        terminateChildren(of: process.processIdentifier, signal: "TERM")
        process.terminate()
    }

    func forceTerminate() {
        guard let process = currentProcess(), process.isRunning else { return }
        terminateChildren(of: process.processIdentifier, signal: "KILL")
        kill(process.processIdentifier, SIGKILL)
    }

    private func currentProcess() -> Process? {
        lock.lock()
        let process = process
        lock.unlock()
        return process
    }

    private func terminateChildren(of processID: pid_t, signal: String) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-\(signal)", "-P", String(processID)]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }
}

enum ProviderSignInResult: Equatable, Sendable {
    case authenticated(details: String)
    case clientMissing
    case cancelled
    case timedOut(details: String)
    case failed(details: String)
}

protocol ProviderSignInRunning: Sendable {
    func signIn(to provider: Provider) async -> ProviderSignInResult
}

protocol ProviderCredentialAccessAuthorizing: Sendable {
    func requestAccess(for provider: Provider) async -> Bool
}

struct LiveProviderCredentialAccessAuthorizer: ProviderCredentialAccessAuthorizing {
    func requestAccess(for provider: Provider) async -> Bool {
        switch provider {
        case .codex:
            return true
        case .claude:
            let granted = await Task.detached(priority: .userInitiated) {
                ClaudeCodeCredentialStore().authorizeKeychainAccessInteractively()
            }.value
            if granted {
                return true
            }
            return (try? await ClaudeCodeCredentialStore().loadCredential()) != nil
        }
    }
}

enum ProviderSignInState: Equatable, Sendable {
    case launching
    case waitingForBrowser
    case authorizingAccess
    case verifying
    case connected(String)
    case permissionRequired(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .launching, .waitingForBrowser, .authorizingAccess, .verifying:
            return true
        case .connected, .permissionRequired, .failed:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .launching, .waitingForBrowser:
            return true
        case .authorizingAccess, .verifying, .connected, .permissionRequired, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .launching:
            return "Opening sign-in…"
        case .waitingForBrowser:
            return "Waiting for browser sign-in…"
        case .authorizingAccess:
            return "Requesting account access…"
        case .verifying:
            return "Checking live quota…"
        case .connected:
            return "Connected"
        case .permissionRequired:
            return "Allow account access"
        case .failed:
            return "Needs attention"
        }
    }

    var details: String? {
        switch self {
        case .connected(let details), .permissionRequired(let details), .failed(let details):
            return details
        case .launching, .waitingForBrowser, .authorizingAccess, .verifying:
            return nil
        }
    }
}

struct CLIProviderSignInRunner: ProviderSignInRunning {
    private let commandResolver: any ProviderSignInCommandResolving
    private let processRunner: any ProviderSignInProcessRunning

    init(
        commandResolver: any ProviderSignInCommandResolving = ProviderSignInCommandResolver(),
        processRunner: any ProviderSignInProcessRunning = FoundationProviderSignInProcessRunner()
    ) {
        self.commandResolver = commandResolver
        self.processRunner = processRunner
    }

    func signIn(to provider: Provider) async -> ProviderSignInResult {
        guard let command = commandResolver.command(for: provider) else {
            return .clientMissing
        }
        do {
            let result = try await processRunner.run(command)
            if result.cancelled {
                return .cancelled
            }
            if result.timedOut {
                return .timedOut(
                    details: "No sign-in confirmation was received before the three-minute timeout."
                )
            }
            if result.exitCode == 0 {
                return .authenticated(details: "\(provider.displayName) sign-in completed.")
            }
            return .failed(
                details: "\(provider.displayName) sign-in stopped before it completed (status \(result.exitCode))."
            )
        } catch {
            return .failed(details: "The \(provider.displayName) sign-in process could not start.")
        }
    }
}
