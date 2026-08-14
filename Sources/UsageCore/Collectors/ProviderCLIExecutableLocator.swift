import Foundation

public enum ProviderCLIExecutableLocator {
    public static func candidates(
        for provider: Provider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        switch provider {
        case .claude:
            return [
                homeDirectory.appending(path: ".local/bin/claude"),
                homeDirectory.appending(path: ".claude/local/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude")
            ]
        case .codex:
            return [
                homeDirectory.appending(path: ".local/bin/codex"),
                homeDirectory.appending(path: ".codex/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
            ]
        }
    }

    public static func locate(
        provider: Provider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        candidates(for: provider, homeDirectory: homeDirectory)
            .first { isExecutable($0.path) }
    }
}
