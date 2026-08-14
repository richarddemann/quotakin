import Foundation

public enum QuotakinSupportDirectory {
    public static func resolvedRoot(
        homeDirectory: URL,
        legacyDirectoryExists: Bool
    ) -> URL {
        homeDirectory.appending(
            path: "Library/Application Support/\(legacyDirectoryExists ? "UsageBar" : "Quotakin")"
        )
    }
}
