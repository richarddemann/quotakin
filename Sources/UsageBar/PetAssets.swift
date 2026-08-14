import AppKit
import Foundation
import UsageCore

enum PetAssets {
    struct PackSummary: Equatable, Identifiable {
        let id: String
        let displayName: String
    }

    static func resolvedPack(for provider: Provider, preferences: UserPreferences) -> PetPack? {
        PetRowPresentation.resolvedPack(
            for: provider,
            preferences: preferences,
            availablePacks: loadedPacks
        )
    }

    static func spritesheetImage(for pack: PetPack) -> CGImage? {
        spritesheetImageCache[pack.spritesheetURL.standardizedFileURL.path]
    }

    /// The discovered pack with a matching `id`, if any. Additive lookup over
    /// the same once-per-process `loadedPacks` used everywhere else — no new
    /// discovery or caching.
    static func pack(withID id: String) -> PetPack? {
        loadedPacks.first { $0.id == id }
    }

    /// Convenience for callers that only have a pack id (e.g. settings
    /// thumbnails built from `availablePacks`, which yields ids). Resolves the
    /// pack, then hits the existing spritesheet cache; returns nil if the pack
    /// is unknown or its sheet failed to load. Never triggers a fresh load.
    static func spritesheetImage(forPackID id: String) -> CGImage? {
        guard let pack = pack(withID: id) else { return nil }
        return spritesheetImage(for: pack)
    }

    /// Pet packs are discovered once at app launch; newly installed packs
    /// require an app restart before they appear here.
    static var availablePacks: [PackSummary] {
        loadedPacks.map { pack in
            PackSummary(
                id: pack.id,
                displayName: pack.manifest.displayName ?? pack.id
            )
        }
    }

    static var loaderDiagnostics: [PetPackDiagnostic] {
        loadResult.diagnostics
    }

    static var userInstalledPacksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Quotakin")
            .appendingPathComponent("Pets")
    }

    private static let loadResult: PetPackLoadResult = {
        PetPackLoader(rootURLs: packRootURLs).load()
    }()

    private static let loadedPacks: [PetPack] = {
        loadResult.packs
    }()

    /// Cached as CGImage so the sprite view's per-frame Canvas draw is a pure
    /// crop + blit; NSImage→CGImage conversion must not happen on every frame.
    private static let spritesheetImageCache: [String: CGImage] = {
        loadedPacks.reduce(into: [:]) { cache, pack in
            let key = pack.spritesheetURL.standardizedFileURL.path
            if cache[key] == nil,
               let image = NSImage(contentsOf: pack.spritesheetURL),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cache[key] = cgImage
            }
        }
    }()

    private static let packRootURLs: [URL] = {
        var urls: [URL] = []
        if let bundledPetsURL = AppResourceBundle.current.url(forResource: "Pets", withExtension: nil) {
            urls.append(bundledPetsURL)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(userInstalledPacksURL)
        // Continue discovering packs installed before the product rename.
        urls.append(
            home.appendingPathComponent("Library/Application Support/UsageBar/Pets")
        )
        urls.append(home.appendingPathComponent(".codex").appendingPathComponent("pets"))
        return urls
    }()

}
