import Foundation
import Testing
@testable import UsageCore

private struct ClaudeStatusLineSandbox {
    let root: URL
    let settingsJSON: URL
    let appSupportDir: URL
    let snapshotURL: URL
    let diagnosticURL: URL
    let metadataURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UsageBar-ClaudeStatusLineInstallerTests-\(UUID().uuidString)")
        settingsJSON = root.appending(path: ".claude/settings.json")
        appSupportDir = root.appending(path: "Library/Application Support/UsageBar's statusline")
        snapshotURL = appSupportDir.appending(path: "Snapshots/quota's snapshot.json")
        diagnosticURL = appSupportDir.appending(path: "Diagnostics/statusline's diagnostic.json")
        metadataURL = appSupportDir.appending(path: "Metadata/installer's metadata.json")
        try FileManager.default.createDirectory(
            at: settingsJSON.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    var installer: ClaudeStatusLineInstaller {
        makeInstaller()
    }

    func makeInstaller(
        operations: ClaudeStatusLineFileOperations = .live
    ) -> ClaudeStatusLineInstaller {
        ClaudeStatusLineInstaller(
            settingsJSON: settingsJSON,
            appSupportDir: appSupportDir,
            snapshotURL: snapshotURL,
            diagnosticURL: diagnosticURL,
            metadataURL: metadataURL,
            operations: operations
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func writeJSONObject(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
}

private func readJSONObject(from url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}

private func jsonValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else {
        return lhs == nil && rhs == nil
    }
    return (lhs as AnyObject).isEqual(rhs)
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private enum InjectedFileSystemError: Error {
    case expected
}

private final class OneShotFileSystemFailure {
    enum Point {
        case write(URL)
        case chmod(URL)
        case remove(URL)
    }

    private var point: Point?

    init(_ point: Point) {
        self.point = point
    }

    func operations() -> ClaudeStatusLineFileOperations {
        let live = ClaudeStatusLineFileOperations.live
        return ClaudeStatusLineFileOperations(
            fileExists: live.fileExists,
            readData: live.readData,
            createDirectory: live.createDirectory,
            writeDataAtomically: { [self] data, url in
                if consumeWrite(at: url) {
                    throw InjectedFileSystemError.expected
                }
                try live.writeDataAtomically(data, url)
            },
            setExecutable: { [self] url in
                if consumeChmod(at: url) {
                    throw InjectedFileSystemError.expected
                }
                try live.setExecutable(url)
            },
            removeItem: { [self] url in
                if consumeRemove(at: url) {
                    throw InjectedFileSystemError.expected
                }
                try live.removeItem(url)
            }
        )
    }

    private func consumeWrite(at url: URL) -> Bool {
        guard case .write(let expectedURL) = point, expectedURL == url else {
            return false
        }
        point = nil
        return true
    }

    private func consumeChmod(at url: URL) -> Bool {
        guard case .chmod(let expectedURL) = point, expectedURL == url else {
            return false
        }
        point = nil
        return true
    }

    private func consumeRemove(at url: URL) -> Bool {
        guard case .remove(let expectedURL) = point, expectedURL == url else {
            return false
        }
        point = nil
        return true
    }
}

private enum ReinstallFailure: CaseIterable, Sendable {
    case extractorWrite
    case chmod
    case settingsWrite
}

private enum UninstallCleanupFailure: CaseIterable, Sendable {
    case wrapperRemove
    case metadataRemove
}

@Test
func claudeStatusLineInstallPreservesSettingsWithoutExistingStatusLine() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([
        "model": "claude-sonnet",
        "permissions": ["allow": ["Bash(git status)"]]
    ], to: sandbox.settingsJSON)

    try sandbox.installer.install()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    let installedStatusLine = try #require(settings["statusLine"] as? [String: Any])
    #expect(settings["model"] as? String == "claude-sonnet")
    #expect(jsonValuesEqual(settings["permissions"], ["allow": ["Bash(git status)"]]))
    #expect(installedStatusLine["type"] as? String == "command")
    #expect(
        installedStatusLine["command"] as? String
            == shellQuoted(sandbox.installer.wrapperURL.path)
    )
    #expect(installedStatusLine["refreshInterval"] as? Int == 5)

    let metadata = try readJSONObject(from: sandbox.metadataURL)
    #expect(metadata["hadStatusLine"] as? Bool == false)
    #expect(metadata["priorStatusLine"] == nil)
    #expect(String(data: try Data(contentsOf: sandbox.metadataURL), encoding: .utf8)?
        .contains("previous") == false)

    #expect(FileManager.default.fileExists(atPath: sandbox.installer.wrapperURL.path))
    #expect(FileManager.default.fileExists(atPath: sandbox.installer.extractorURL.path))
    let attributes = try FileManager.default.attributesOfItem(
        atPath: sandbox.installer.wrapperURL.path
    )
    let permissions = try #require(
        attributes[FileAttributeKey.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o111 != 0)
}

@Test
func claudeStatusLineInstallStoresExistingThirdPartyStatusLineWithoutChaining() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorStatusLine: [String: Any] = [
        "type": "command",
        "command": "printf 'prior display'",
        "padding": 7
    ]
    try writeJSONObject([
        "statusLine": priorStatusLine,
        "theme": "dark"
    ], to: sandbox.settingsJSON)

    try sandbox.installer.install()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["theme"] as? String == "dark")
    let installedStatusLine = try #require(settings["statusLine"] as? [String: Any])
    #expect(installedStatusLine["type"] as? String == "command")
    #expect(installedStatusLine["command"] as? String == shellQuoted(sandbox.installer.wrapperURL.path))
    #expect(installedStatusLine["padding"] as? Int == 7)
    #expect(installedStatusLine["refreshInterval"] as? Int == 5)

    let metadata = try readJSONObject(from: sandbox.metadataURL)
    #expect(metadata["hadStatusLine"] as? Bool == true)
    #expect(jsonValuesEqual(metadata["priorStatusLine"], priorStatusLine))

    let wrapper = try String(contentsOf: sandbox.installer.wrapperURL, encoding: .utf8)
    #expect(!wrapper.contains("CHAIN_COMMAND"))
    #expect(!wrapper.contains("prior display"))

    try sandbox.installer.uninstall()

    let restoredSettings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(jsonValuesEqual(restoredSettings["statusLine"], priorStatusLine))
}

@Test
func claudeStatusLineReplaceInstallOverwritesExistingStatusLineWithoutRetainingIt() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorCommand = "printf '$SECRET' && cd /private/synthetic/project"
    try writeJSONObject([
        "statusLine": [
            "type": "command",
            "command": priorCommand
        ],
        "theme": "dark"
    ], to: sandbox.settingsJSON)

    try sandbox.installer.install(replacingExistingStatusLine: true)

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    let installedStatusLine = try #require(settings["statusLine"] as? [String: Any])
    #expect(settings["theme"] as? String == "dark")
    #expect(installedStatusLine["command"] as? String == shellQuoted(sandbox.installer.wrapperURL.path))
    let generatedFileContents = try [
        sandbox.installer.wrapperURL,
        sandbox.installer.extractorURL,
        sandbox.metadataURL
    ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    #expect(!generatedFileContents.contains(priorCommand))
    #expect(!generatedFileContents.contains("$SECRET"))
    #expect(!generatedFileContents.contains("/private/synthetic/project"))

    try sandbox.installer.uninstall()

    let restoredSettings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(restoredSettings["theme"] as? String == "dark")
    #expect(restoredSettings["statusLine"] == nil)
}

@Test
func claudeStatusLineReinstallUpgradesExistingUsageBarStatusLineMetadata() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorStatusLine: [String: Any] = [
        "type": "command",
        "command": "printf 'prior display'",
        "padding": 0
    ]
    let oldInstalledStatusLine: [String: Any] = [
        "type": "command",
        "command": shellQuoted(sandbox.installer.wrapperURL.path),
        "padding": 0
    ]
    try writeJSONObject([
        "statusLine": oldInstalledStatusLine,
        "theme": "dark"
    ], to: sandbox.settingsJSON)
    try FileManager.default.createDirectory(
        at: sandbox.metadataURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try writeJSONObject([
        "version": 1,
        "settingsExisted": true,
        "hadStatusLine": true,
        "priorStatusLine": priorStatusLine,
        "installedStatusLine": oldInstalledStatusLine
    ], to: sandbox.metadataURL)

    try sandbox.installer.install()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    let installedStatusLine = try #require(settings["statusLine"] as? [String: Any])
    #expect(installedStatusLine["refreshInterval"] as? Int == 5)
    let metadata = try readJSONObject(from: sandbox.metadataURL)
    let metadataInstalledStatusLine = try #require(metadata["installedStatusLine"] as? [String: Any])
    #expect(metadataInstalledStatusLine["refreshInterval"] as? Int == 5)
    #expect(jsonValuesEqual(metadata["priorStatusLine"], priorStatusLine))
}

@Test
func claudeStatusLineUninstallRemovesStatusLineWhenOriginallyAbsent() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject(["theme": "dark"], to: sandbox.settingsJSON)
    try sandbox.installer.install()

    try sandbox.installer.uninstall()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["theme"] as? String == "dark")
    #expect(settings["statusLine"] == nil)
}

@Test
func claudeStatusLineUninstallRecoversInterruptedInstallBeforeSettingsUpdate() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorSettings: [String: Any] = [
        "theme": "dark"
    ]
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)
    try sandbox.installer.install()
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)
    try Data("snapshot".utf8).write(to: sandbox.snapshotURL)

    try sandbox.installer.uninstall()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["theme"] as? String == "dark")
    #expect(settings["statusLine"] == nil)
    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.wrapperURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.extractorURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.snapshotURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}

@Test
func claudeStatusLineUninstallRecoversInterruptedInstallWithNoPriorStatusLine() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorSettings = ["theme": "dark"]
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)
    try sandbox.installer.install()
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)

    try sandbox.installer.uninstall()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["theme"] as? String == "dark")
    #expect(settings["statusLine"] == nil)
    #expect(!FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}

@Test
func claudeStatusLineUninstallRejectsUnrelatedLaterStatusLineEdit() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    let unrelatedStatusLine: [String: Any] = [
        "type": "command",
        "command": "printf third-party"
    ]
    try writeJSONObject(["statusLine": unrelatedStatusLine], to: sandbox.settingsJSON)

    do {
        try sandbox.installer.uninstall()
        Issue.record("Expected uninstall to reject an unrelated statusLine edit")
    } catch let error as ClaudeStatusLineInstallerError {
        #expect(error == .conflictingInstallation)
    }

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(jsonValuesEqual(settings["statusLine"], unrelatedStatusLine))
    #expect(FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}

@Test
func claudeStatusLineInstallFinishesInterruptedSettingsUpdate() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorSettings = ["theme": "dark"]
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)
    try sandbox.installer.install()
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)

    try sandbox.installer.install()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    let statusLine = try #require(settings["statusLine"] as? [String: Any])
    #expect(
        statusLine["command"] as? String
            == shellQuoted(sandbox.installer.wrapperURL.path)
    )
}

@Test
func claudeStatusLineWrapperAvoidsFullInputTempFilesAndPriorCommandRetention() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)

    try sandbox.installer.install()

    let wrapper = try String(contentsOf: sandbox.installer.wrapperURL, encoding: .utf8)
    #expect(wrapper.contains("EXTRACTOR=\(shellQuoted(sandbox.installer.extractorURL.path))"))
    #expect(wrapper.contains("SNAPSHOT=\(shellQuoted(sandbox.snapshotURL.path))"))
    #expect(!wrapper.contains("/usr/bin/mktemp"))
    #expect(!wrapper.contains("/bin/cat >"))
    #expect(wrapper.contains("INPUT=$(/bin/cat)"))
    #expect(wrapper.contains("printf '%s' \"$INPUT\" | /usr/bin/osascript -l JavaScript \"$EXTRACTOR\" \"$SNAPSHOT\""))
    #expect(!wrapper.contains("workspace"))
    #expect(!wrapper.contains("cwd"))
    #expect(!wrapper.contains("project"))
}

@Test
func claudeStatusLineWrapperDoesNotExecutePriorCommandWhileCapturingQuota() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorOutputURL = sandbox.root.appending(path: "prior-output.txt")
    let priorStatusLine: [String: Any] = [
        "type": "command",
        "command": "jq -r '.model.display_name' > \(shellQuoted(priorOutputURL.path))"
    ]
    try writeJSONObject(["statusLine": priorStatusLine], to: sandbox.settingsJSON)
    try sandbox.installer.install()

    let input = Data("""
    {
      "model": {"display_name": "Claude Sonnet"},
      "rate_limits": {
        "five_hour": {"used_percentage": 9, "resets_at": 2051222400},
        "seven_day": {"used_percentage": 29, "resets_at": 2051654400}
      }
    }
    """.utf8)
    let process = Process()
    process.executableURL = sandbox.installer.wrapperURL
    let standardInput = Pipe()
    process.standardInput = standardInput

    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: input)
    try standardInput.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: priorOutputURL.path))
    let snapshot = try readJSONObject(from: sandbox.snapshotURL)
    let fiveHour = try #require(snapshot["fiveHour"] as? [String: Any])
    #expect(fiveHour["usedPercent"] as? Int == 9)
    let sevenDay = try #require(snapshot["sevenDay"] as? [String: Any])
    #expect(sevenDay["usedPercent"] as? Int == 29)
}

@Test
func claudeStatusLineExtractorOnlyReadsQuotaFields() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)

    try sandbox.installer.install()

    let extractor = try String(
        contentsOf: sandbox.installer.extractorURL,
        encoding: .utf8
    )
    #expect(extractor.contains("rate_limits"))
    #expect(extractor.contains("five_hour"))
    #expect(extractor.contains("seven_day"))
    #expect(extractor.contains("used_percentage"))
    #expect(extractor.contains("resets_at"))
    #expect(extractor.contains("observedAt"))
    #expect(extractor.contains("fiveHour"))
    #expect(extractor.contains("sevenDay"))
    #expect(!extractor.contains("transcript"))
    #expect(!extractor.contains("workspace"))
    #expect(!extractor.contains("cwd"))
    #expect(!extractor.contains("project"))
    #expect(!extractor.contains("path"))
}

@Test
func claudeStatusLineWrapperWritesMinimalSnapshotWithoutPersistingRawInput() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    let input = Data("""
    {
      "transcript_path": "/private/synthetic/transcript.jsonl",
      "cwd": "/private/synthetic/current",
      "workspace": {"project_dir": "/private/synthetic/project"},
      "rate_limits": {
        "five_hour": {"used_percentage": 42.5, "resets_at": 2051222400},
        "seven_day": {"used_percentage": 61.25, "resets_at": 2051654400}
      }
    }
    """.utf8)
    let process = Process()
    process.executableURL = sandbox.installer.wrapperURL
    let standardInput = Pipe()
    process.standardInput = standardInput

    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: input)
    try standardInput.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let generatedFileContents = try [
        sandbox.installer.wrapperURL,
        sandbox.installer.extractorURL,
        sandbox.metadataURL,
        sandbox.snapshotURL
    ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    #expect(!generatedFileContents.contains("/private/synthetic/transcript.jsonl"))
    #expect(!generatedFileContents.contains("/private/synthetic/current"))
    #expect(!generatedFileContents.contains("/private/synthetic/project"))
    let snapshot = try readJSONObject(from: sandbox.snapshotURL)
    #expect(Set(snapshot.keys) == ["observedAt", "fiveHour", "sevenDay"])
    #expect(snapshot["observedAt"] as? String != nil)
    let fiveHour = try #require(snapshot["fiveHour"] as? [String: Any])
    #expect(Set(fiveHour.keys) == ["usedPercent", "resetsAt"])
    #expect(fiveHour["usedPercent"] as? Double == 42.5)
    #expect(fiveHour["resetsAt"] as? Int == 2_051_222_400)
    let sevenDay = try #require(snapshot["sevenDay"] as? [String: Any])
    #expect(Set(sevenDay.keys) == ["usedPercent", "resetsAt"])
    #expect(sevenDay["usedPercent"] as? Double == 61.25)
    #expect(sevenDay["resetsAt"] as? Int == 2_051_654_400)
}

@Test
func claudeStatusLineWrapperWritesDiagnosticWhenQuotaFieldsAreMissing() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    let input = Data("""
    {
      "model": {"display_name": "Claude Sonnet"},
      "workspace": {"project_dir": "/private/synthetic/project"}
    }
    """.utf8)
    let process = Process()
    process.executableURL = sandbox.installer.wrapperURL
    let standardInput = Pipe()
    process.standardInput = standardInput

    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: input)
    try standardInput.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: sandbox.snapshotURL.path))
    let diagnostic = try readJSONObject(from: sandbox.diagnosticURL)
    #expect(diagnostic["status"] as? String == "missing_rate_limits")
    #expect(diagnostic["observedAt"] as? String != nil)
    #expect(diagnostic["hasRateLimits"] as? Bool == false)
    #expect(diagnostic["hasFiveHour"] as? Bool == false)
    #expect(diagnostic["hasSevenDay"] as? Bool == false)
    let diagnosticText = try String(contentsOf: sandbox.diagnosticURL, encoding: .utf8)
    #expect(!diagnosticText.contains("/private/synthetic/project"))
    #expect(!diagnosticText.contains("Claude Sonnet"))
}

@Test
func claudeStatusLineReinstallIsIdempotent() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    let firstMetadata = try Data(contentsOf: sandbox.metadataURL)

    try sandbox.installer.install()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    let metadata = try readJSONObject(from: sandbox.metadataURL)
    #expect(firstMetadata == (try Data(contentsOf: sandbox.metadataURL)))
    #expect(metadata["priorStatusLine"] == nil)
    #expect(
        (settings["statusLine"] as? [String: Any])?["command"] as? String
            == shellQuoted(sandbox.installer.wrapperURL.path)
    )
}

@Test(arguments: ReinstallFailure.allCases)
private func claudeStatusLineReinstallFailurePreservesRecoverableState(
    _ failure: ReinstallFailure
) throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    let priorSettings = ["theme": "dark"]
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)
    try sandbox.installer.install()
    try writeJSONObject(priorSettings, to: sandbox.settingsJSON)

    let point: OneShotFileSystemFailure.Point
    switch failure {
    case .extractorWrite:
        point = .write(sandbox.installer.extractorURL)
    case .chmod:
        point = .chmod(sandbox.installer.wrapperURL)
    case .settingsWrite:
        point = .write(sandbox.settingsJSON)
    }
    let failingInstaller = sandbox.makeInstaller(
        operations: OneShotFileSystemFailure(point).operations()
    )

    do {
        try failingInstaller.install()
        Issue.record("Expected reinstall failure")
    } catch is InjectedFileSystemError {
    }

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["statusLine"] == nil)
    #expect(settings["theme"] as? String == "dark")
    #expect(FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.wrapperURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.extractorURL.path))

    try sandbox.installer.install()
    try sandbox.installer.uninstall()

    let restoredSettings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(restoredSettings["statusLine"] == nil)
    #expect(restoredSettings["theme"] as? String == "dark")
    #expect(!FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}

@Test
func claudeStatusLineInstalledReinstallFailureStillAllowsUninstall() throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    let failingInstaller = sandbox.makeInstaller(
        operations: OneShotFileSystemFailure(
            .chmod(sandbox.installer.wrapperURL)
        ).operations()
    )

    do {
        try failingInstaller.install()
        Issue.record("Expected reinstall failure")
    } catch is InjectedFileSystemError {
    }

    #expect(FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
    try sandbox.installer.uninstall()

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["statusLine"] == nil)
    #expect(!FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}

@Test(arguments: UninstallCleanupFailure.allCases)
private func claudeStatusLineUninstallCleanupFailureCanBeRetried(
    _ failure: UninstallCleanupFailure
) throws {
    let sandbox = try ClaudeStatusLineSandbox()
    defer { sandbox.cleanUp() }
    try writeJSONObject([:], to: sandbox.settingsJSON)
    try sandbox.installer.install()
    try Data("snapshot".utf8).write(to: sandbox.snapshotURL)
    let point: OneShotFileSystemFailure.Point
    switch failure {
    case .wrapperRemove:
        point = .remove(sandbox.installer.wrapperURL)
    case .metadataRemove:
        point = .remove(sandbox.metadataURL)
    }
    let failingInstaller = sandbox.makeInstaller(
        operations: OneShotFileSystemFailure(point).operations()
    )

    do {
        try failingInstaller.uninstall()
        Issue.record("Expected cleanup failure")
    } catch let error as ClaudeStatusLineInstallerError {
        #expect(error == .cleanupFailed)
    }

    let settings = try readJSONObject(from: sandbox.settingsJSON)
    #expect(settings["statusLine"] == nil)
    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.extractorURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.snapshotURL.path))
    #expect(FileManager.default.fileExists(atPath: sandbox.metadataURL.path))

    try sandbox.installer.uninstall()

    #expect(!FileManager.default.fileExists(atPath: sandbox.installer.wrapperURL.path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.metadataURL.path))
}
