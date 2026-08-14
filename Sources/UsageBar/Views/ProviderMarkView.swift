import SwiftUI
import UsageCore

struct ProviderIconView: View {
    let provider: Provider
    var size: CGFloat = 18

    var body: some View {
        if let image = provider.iconImage {
            Image(nsImage: image)
                .resizable()
                .renderingMode(provider.rendersIconInColor ? .original : .template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                .accessibilityLabel(provider.shortDisplayName)
        } else {
            Text(provider.fallbackIconText)
                .font(.system(size: size * 0.58, weight: .bold, design: .rounded))
                .frame(width: size, height: size)
                .background(provider.tint.opacity(0.16), in: Circle())
                .foregroundStyle(provider.tint)
                .accessibilityLabel(provider.shortDisplayName)
        }
    }
}

struct ProviderMarkView: View {
    let provider: Provider

    var body: some View {
        HStack(spacing: 5) {
            ProviderIconView(provider: provider, size: 15)
            Text(provider.shortDisplayName)
                .font(.caption.bold())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(provider.tint.opacity(0.14), in: Capsule())
        .foregroundStyle(provider.tint)
        .accessibilityLabel(provider.shortDisplayName)
    }
}

extension Provider {
    var shortDisplayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var iconResourceName: String {
        switch self {
        case .claude:
            "claude"
        case .codex:
            "openai"
        }
    }

    var rendersIconInColor: Bool {
        switch self {
        case .claude:
            true
        case .codex:
            false
        }
    }

    var fallbackIconText: String {
        switch self {
        case .claude:
            "C"
        case .codex:
            ">"
        }
    }

    var iconImage: NSImage? {
        Self.iconImageCache[self]
    }

    /// Resolved once per process: bundle lookup and image decode are too
    /// expensive for view bodies — the menu bar label re-renders on every
    /// refresh, and repeated `Bundle.module` probing can starve the main
    /// thread during `MenuBarExtra` setup.
    private static let iconImageCache: [Provider: NSImage] = {
        var cache: [Provider: NSImage] = [:]
        for provider in Provider.allCases {
            if let url = AppResourceBundle.current.url(forResource: provider.iconResourceName, withExtension: "svg"),
               let image = cachedIconImage(contentsOf: url) {
                cache[provider] = image
            }
        }
        return cache
    }()

    private static func cachedIconImage(contentsOf url: URL) -> NSImage? {
        // Keep the SVG's native vector representation and logical size.
        // Rewriting NSImage.size here makes SwiftUI render an oversized
        // intermediate and downsample it, softening small toolbar/table marks.
        NSImage(contentsOf: url)
    }

    /// The installed app carries the SwiftPM resource bundle in
    /// Contents/Resources, where the generated `Bundle.module` accessor does
    /// not look — its fallback is the machine-specific `.build` path, which
    /// must never be touched from an installed app. Resolve the sub-bundle
    /// explicitly and use `Bundle.module` only for dev/test runs.
    var tint: Color {
        switch self {
        case .claude:
            .claudeTint
        case .codex:
            .codexTint
        }
    }
}
