import Foundation

public enum ClaudeStatusLineInstallerError: Error, Equatable, CustomStringConvertible {
    case invalidSettingsJSON
    case invalidMetadata
    case conflictingInstallation
    case cleanupFailed

    public var description: String {
        switch self {
        case .invalidSettingsJSON:
            "Claude settings must be a JSON object."
        case .invalidMetadata:
            "Quotakin Claude status-line metadata is invalid."
        case .conflictingInstallation:
            "Claude statusLine changed after Quotakin installed its wrapper."
        case .cleanupFailed:
            "Claude status-line settings were restored, but generated file cleanup is incomplete."
        }
    }
}

public struct ClaudeStatusLineFileOperations {
    public let fileExists: (URL) -> Bool
    public let readData: (URL) throws -> Data
    public let createDirectory: (URL) throws -> Void
    public let writeDataAtomically: (Data, URL) throws -> Void
    public let setExecutable: (URL) throws -> Void
    public let removeItem: (URL) throws -> Void

    public init(
        fileExists: @escaping (URL) -> Bool,
        readData: @escaping (URL) throws -> Data,
        createDirectory: @escaping (URL) throws -> Void,
        writeDataAtomically: @escaping (Data, URL) throws -> Void,
        setExecutable: @escaping (URL) throws -> Void,
        removeItem: @escaping (URL) throws -> Void
    ) {
        self.fileExists = fileExists
        self.readData = readData
        self.createDirectory = createDirectory
        self.writeDataAtomically = writeDataAtomically
        self.setExecutable = setExecutable
        self.removeItem = removeItem
    }

    public static var live: Self {
        Self(
            fileExists: {
                FileManager.default.fileExists(atPath: $0.path)
            },
            readData: {
                try Data(contentsOf: $0)
            },
            createDirectory: {
                try FileManager.default.createDirectory(
                    at: $0,
                    withIntermediateDirectories: true
                )
            },
            writeDataAtomically: {
                try $0.write(to: $1, options: .atomic)
            },
            setExecutable: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: $0.path
                )
            },
            removeItem: {
                try FileManager.default.removeItem(at: $0)
            }
        )
    }
}

public struct ClaudeStatusLineInstaller {
    public let settingsJSON: URL
    public let appSupportDir: URL
    public let snapshotURL: URL
    public let diagnosticURL: URL
    public let metadataURL: URL
    public let wrapperURL: URL
    public let extractorURL: URL
    public let operations: ClaudeStatusLineFileOperations

    public init(
        settingsJSON: URL = Self.defaultSettingsJSON,
        appSupportDir: URL = Self.defaultAppSupportDir,
        snapshotURL: URL? = nil,
        diagnosticURL: URL? = nil,
        metadataURL: URL? = nil,
        operations: ClaudeStatusLineFileOperations = .live
    ) {
        self.settingsJSON = settingsJSON
        self.appSupportDir = appSupportDir
        self.snapshotURL = snapshotURL
            ?? appSupportDir.appending(path: "claude-quota-snapshot.json")
        self.diagnosticURL = diagnosticURL
            ?? appSupportDir.appending(path: "claude-statusline-diagnostic.json")
        self.metadataURL = metadataURL
            ?? appSupportDir.appending(path: "claude-statusline-metadata.json")
        wrapperURL = appSupportDir.appending(path: "claude-statusline-wrapper.sh")
        extractorURL = appSupportDir.appending(path: "claude-quota-extractor.js")
        self.operations = operations
    }

    public func install(replacingExistingStatusLine: Bool = false) throws {
        let settingsExisted = operations.fileExists(settingsJSON)
        var settings = try readSettings()

        if operations.fileExists(metadataURL) {
            let metadata = try readMetadata()
            let upgradedMetadata = Metadata(
                settingsExisted: metadata.settingsExisted,
                hadStatusLine: metadata.hadStatusLine,
                priorStatusLine: metadata.priorStatusLine,
                installedStatusLine: installedStatusLine(chaining: metadata.priorStatusLine)
            )
            if jsonValuesEqual(settings["statusLine"], metadata.installedStatusLine)
                || jsonValuesEqual(settings["statusLine"], upgradedMetadata.installedStatusLine) {
                try writeGeneratedFilesRecoverably(chaining: metadata.priorStatusLine)
                settings["statusLine"] = upgradedMetadata.installedStatusLine
                try writeJSON(upgradedMetadata.jsonObject, to: metadataURL)
                try writeJSON(settings, to: settingsJSON)
                return
            }
            guard metadata.matchesPriorStatusLine(in: settings) else {
                throw ClaudeStatusLineInstallerError.conflictingInstallation
            }
            do {
                try writeGeneratedFiles(chaining: metadata.priorStatusLine)
                settings["statusLine"] = upgradedMetadata.installedStatusLine
                try writeJSON(upgradedMetadata.jsonObject, to: metadataURL)
                try writeJSON(settings, to: settingsJSON)
            } catch {
                removeGeneratedArtifactsBestEffort()
                throw error
            }
            return
        }

        let hadStatusLine = settings.keys.contains("statusLine")
        let priorStatusLine = hadStatusLine && !replacingExistingStatusLine
            ? settings["statusLine"]
            : nil
        let metadata = Metadata(
            settingsExisted: settingsExisted,
            hadStatusLine: priorStatusLine != nil,
            priorStatusLine: priorStatusLine,
            installedStatusLine: installedStatusLine(chaining: priorStatusLine)
        )

        do {
            try writeGeneratedFiles(chaining: priorStatusLine)
        } catch {
            removeGeneratedArtifactsBestEffort()
            throw error
        }
        do {
            try writeJSON(metadata.jsonObject, to: metadataURL)
            settings["statusLine"] = metadata.installedStatusLine
            try writeJSON(settings, to: settingsJSON)
        } catch {
            removeGeneratedArtifactsBestEffort()
            throw error
        }
    }

    public func uninstall() throws {
        guard operations.fileExists(metadataURL) else {
            return
        }

        let metadata = try readMetadata()
        var settings = try readSettings()
        guard
            jsonValuesEqual(settings["statusLine"], metadata.installedStatusLine)
                || metadata.matchesPriorStatusLine(in: settings)
        else {
            throw ClaudeStatusLineInstallerError.conflictingInstallation
        }

        if metadata.hadStatusLine {
            settings["statusLine"] = metadata.priorStatusLine
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        if !metadata.settingsExisted && settings.isEmpty {
            try removeIfExists(settingsJSON)
        } else {
            try writeJSON(settings, to: settingsJSON)
        }
        try removeGeneratedFiles()
    }

    private func installedStatusLine(chaining priorStatusLine: Any? = nil) -> [String: Any] {
        var statusLine: [String: Any] = [
            "type": "command",
            "command": Self.shellQuoted(wrapperURL.path),
            "refreshInterval": 5
        ]
        if let padding = (priorStatusLine as? [String: Any])?["padding"] {
            statusLine["padding"] = padding
        }
        return statusLine
    }

    private func readSettings() throws -> [String: Any] {
        guard operations.fileExists(settingsJSON) else {
            return [:]
        }
        do {
            return try readJSONObject(from: settingsJSON)
        } catch {
            throw ClaudeStatusLineInstallerError.invalidSettingsJSON
        }
    }

    private func readMetadata() throws -> Metadata {
        do {
            return try Metadata(jsonObject: readJSONObject(from: metadataURL))
        } catch let error as ClaudeStatusLineInstallerError {
            throw error
        } catch {
            throw ClaudeStatusLineInstallerError.invalidMetadata
        }
    }

    private func readJSONObject(from url: URL) throws -> [String: Any] {
        let data = try operations.readData(url)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeStatusLineInstallerError.invalidSettingsJSON
        }
        return object
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try operations.createDirectory(url.deletingLastPathComponent())
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(UInt8(ascii: "\n"))
        try operations.writeDataAtomically(data, url)
    }

    private func writeGeneratedFiles(chaining priorStatusLine: Any? = nil) throws {
        try operations.createDirectory(appSupportDir)
        try operations.createDirectory(snapshotURL.deletingLastPathComponent())
        try operations.createDirectory(diagnosticURL.deletingLastPathComponent())
        try operations.writeDataAtomically(Data(Self.extractorSource.utf8), extractorURL)
        try operations.writeDataAtomically(
            Data(wrapperSource(chaining: priorStatusLine).utf8),
            wrapperURL
        )
        try operations.setExecutable(wrapperURL)
    }

    private func writeGeneratedFilesRecoverably(chaining priorStatusLine: Any? = nil) throws {
        do {
            try writeGeneratedFiles(chaining: priorStatusLine)
        } catch {
            removeGeneratedArtifactsBestEffort()
            throw error
        }
    }

    private func wrapperSource(chaining priorStatusLine: Any? = nil) -> String {
        _ = priorStatusLine
        return """
        #!/bin/sh
        EXTRACTOR=\(Self.shellQuoted(extractorURL.path))
        SNAPSHOT=\(Self.shellQuoted(snapshotURL.path))
        DIAGNOSTIC=\(Self.shellQuoted(diagnosticURL.path))
        INPUT=$(/bin/cat)
        printf '%s' "$INPUT" | /usr/bin/osascript -l JavaScript "$EXTRACTOR" "$SNAPSHOT" "$DIAGNOSTIC"

        """
    }

    private func removeGeneratedFiles() throws {
        var cleanupFailed = false
        for url in [wrapperURL, extractorURL, snapshotURL, diagnosticURL] {
            do {
                try removeIfExists(url)
            } catch {
                cleanupFailed = true
            }
        }
        guard !cleanupFailed else {
            throw ClaudeStatusLineInstallerError.cleanupFailed
        }
        do {
            try removeIfExists(metadataURL)
        } catch {
            throw ClaudeStatusLineInstallerError.cleanupFailed
        }
    }

    private func removeGeneratedArtifactsBestEffort() {
        for url in [wrapperURL, extractorURL, snapshotURL, diagnosticURL] {
            try? removeIfExists(url)
        }
    }

    private func removeIfExists(_ url: URL) throws {
        guard operations.fileExists(url) else {
            return
        }
        try operations.removeItem(url)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let extractorSource = """
    ObjC.import("Foundation");

    function writeJSON(destination, object) {
      const output = $(JSON.stringify(object));
      if (!output.writeToFileAtomicallyEncodingError(
        destination,
        true,
        $.NSUTF8StringEncoding,
        null
      )) {
        throw new Error("Could not write Claude status-line JSON.");
      }
    }

    function run(argv) {
      const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      const text = $.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding).js;
      let source;
      try {
        source = JSON.parse(text);
      } catch (error) {
        writeJSON(argv[1], {
          observedAt: new Date().toISOString(),
          status: "invalid_json",
          hasRateLimits: false,
          hasFiveHour: false,
          hasSevenDay: false
        });
        return;
      }
      const limits = source.rate_limits;
      const hasRateLimits = !!limits;
      const hasFiveHour = !!(limits && limits.five_hour);
      const hasSevenDay = !!(limits && limits.seven_day);
      if (!limits || !limits.five_hour || !limits.seven_day) {
        writeJSON(argv[1], {
          observedAt: new Date().toISOString(),
          status: "missing_rate_limits",
          hasRateLimits: hasRateLimits,
          hasFiveHour: hasFiveHour,
          hasSevenDay: hasSevenDay
        });
        return;
      }

      // Claude Code emits zeroed placeholder rate_limits (used 0%, reset
      // stamps in the past) in some non-interactive harnesses. Writing them
      // would shadow a real snapshot with an expired one.
      const nowSeconds = Date.now() / 1000;
      if (limits.five_hour.resets_at <= nowSeconds && limits.seven_day.resets_at <= nowSeconds) {
        writeJSON(argv[1], {
          observedAt: new Date().toISOString(),
          status: "placeholder_rate_limits",
          hasRateLimits: true,
          hasFiveHour: true,
          hasSevenDay: true
        });
        return;
      }

      const snapshot = {
        observedAt: new Date().toISOString(),
        fiveHour: {
          usedPercent: limits.five_hour.used_percentage,
          resetsAt: limits.five_hour.resets_at
        },
        sevenDay: {
          usedPercent: limits.seven_day.used_percentage,
          resetsAt: limits.seven_day.resets_at
        }
      };
      writeJSON(argv[0], snapshot);
      writeJSON(argv[1], {
        observedAt: snapshot.observedAt,
        status: "snapshot_written",
        hasRateLimits: true,
        hasFiveHour: true,
        hasSevenDay: true
      });
    }

    """

    public static let defaultAppSupportDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyRoot = home.appending(path: "Library/Application Support/UsageBar")
        return QuotakinSupportDirectory.resolvedRoot(
            homeDirectory: home,
            legacyDirectoryExists: FileManager.default.fileExists(atPath: legacyRoot.path)
        ).appending(path: "statusline")
    }()

    public static let defaultSettingsJSON = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/settings.json")
}

private struct Metadata {
    let settingsExisted: Bool
    let hadStatusLine: Bool
    let priorStatusLine: Any?
    let installedStatusLine: [String: Any]

    init(
        settingsExisted: Bool,
        hadStatusLine: Bool,
        priorStatusLine: Any?,
        installedStatusLine: [String: Any]
    ) {
        self.settingsExisted = settingsExisted
        self.hadStatusLine = hadStatusLine
        self.priorStatusLine = priorStatusLine
        self.installedStatusLine = installedStatusLine
    }

    init(jsonObject: [String: Any]) throws {
        guard
            jsonObject["version"] as? Int == 1,
            let settingsExisted = jsonObject["settingsExisted"] as? Bool,
            let hadStatusLine = jsonObject["hadStatusLine"] as? Bool,
            let installedStatusLine = jsonObject["installedStatusLine"] as? [String: Any],
            hadStatusLine == jsonObject.keys.contains("priorStatusLine")
        else {
            throw ClaudeStatusLineInstallerError.invalidMetadata
        }
        self.settingsExisted = settingsExisted
        self.hadStatusLine = hadStatusLine
        priorStatusLine = jsonObject["priorStatusLine"]
        self.installedStatusLine = installedStatusLine
    }

    func matchesPriorStatusLine(in settings: [String: Any]) -> Bool {
        if hadStatusLine {
            return settings.keys.contains("statusLine")
                && jsonValuesEqual(settings["statusLine"], priorStatusLine)
        }
        return !settings.keys.contains("statusLine")
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "version": 1,
            "settingsExisted": settingsExisted,
            "hadStatusLine": hadStatusLine,
            "installedStatusLine": installedStatusLine
        ]
        if hadStatusLine {
            object["priorStatusLine"] = priorStatusLine
        }
        return object
    }
}

private func jsonValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else {
        return lhs == nil && rhs == nil
    }
    return (lhs as AnyObject).isEqual(rhs)
}
