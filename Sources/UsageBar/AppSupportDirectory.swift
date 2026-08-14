import Foundation
import UsageCore

enum AppSupportDirectory {
    static var current: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["QUOTAKIN_SUPPORT_DIRECTORY"]
            ?? environment["USAGEBAR_SUPPORT_DIRECTORY"],
           !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = supportDirectory(named: "UsageBar", homeDirectory: home)
        return QuotakinSupportDirectory.resolvedRoot(
            homeDirectory: home,
            legacyDirectoryExists: FileManager.default.fileExists(atPath: legacy.path)
        )
    }

    static func resolved(homeDirectory: URL, legacyDirectoryExists: Bool) -> URL {
        QuotakinSupportDirectory.resolvedRoot(
            homeDirectory: homeDirectory,
            legacyDirectoryExists: legacyDirectoryExists
        )
    }

    private static func supportDirectory(named name: String, homeDirectory: URL) -> URL {
        homeDirectory.appending(path: "Library/Application Support/\(name)")
    }
}
