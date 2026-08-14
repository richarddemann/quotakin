import AppKit
import SwiftUI

/// Spacing rhythm on the 8 pt grid. Views use these instead of magic numbers
/// so surfaces share one vertical/horizontal cadence.
enum Space {
    /// Hairline gaps inside a compound element (icon-to-text, stacked captions).
    static let xxs: CGFloat = 4
    /// Related rows within one group.
    static let xs: CGFloat = 8
    /// Separation between groups inside a card or panel.
    static let s: CGFloat = 12
    /// Card and popover padding.
    static let m: CGFloat = 16
    /// Separation between top-level sections on a window surface.
    static let l: CGFloat = 24
}

/// Corner radii, small to large. Concentric with macOS window corners.
enum Radius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
}

enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    static let minimumWindowWidth = windowWidth
    static let maximumWindowWidth = windowWidth
    static let minimumHeight: CGFloat = 560
    static let maximumHeight: CGFloat = .infinity
    static let minimumSidebarWidth: CGFloat = 150
    static let sidebarWidth: CGFloat = 175
    static let maximumSidebarWidth: CGFloat = 220
    static let maximumContentWidth: CGFloat = 620
}

/// Semantic capacity state derived from remaining quota. The single source
/// of the ok/caution/critical thresholds and their colors and symbols.
enum CapacityStatus {
    case ok
    case caution
    case critical
    case unknown

    init(remainingPercent: Double?) {
        guard let remainingPercent else {
            self = .unknown
            return
        }
        if remainingPercent < 15 {
            self = .critical
        } else if remainingPercent < 35 {
            self = .caution
        } else {
            self = .ok
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .caution: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .caution: "clock.fill"
        case .critical: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension Color {
    /// Appearance-aware color pair; keeps provider hues legible on both
    /// light and dark content surfaces.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Anthropic's terracotta, darkened slightly for light-mode contrast.
    static let claudeTint = dynamic(
        light: NSColor(red: 0.76, green: 0.42, blue: 0.28, alpha: 1),
        dark: NSColor(red: 0.88, green: 0.55, blue: 0.40, alpha: 1)
    )

    /// A restrained teal for Codex — quieter than system green, still
    /// unmistakably "OpenAI".
    static let codexTint = dynamic(
        light: NSColor(red: 0.06, green: 0.55, blue: 0.45, alpha: 1),
        dark: NSColor(red: 0.20, green: 0.70, blue: 0.58, alpha: 1)
    )

    /// GitHub-like activity intensity, kept distinct from either provider.
    static let activityTint = dynamic(
        light: NSColor(red: 0.15, green: 0.52, blue: 0.30, alpha: 1),
        dark: NSColor(red: 0.29, green: 0.68, blue: 0.42, alpha: 1)
    )
}

/// Menu bar status-item metrics. The status item is AppKit-rendered, so its
/// text sizes live here rather than in the semantic SwiftUI ramp.
enum MenuBarMetrics {
    static let height: CGFloat = 18
    static let iconSize: CGFloat = 18
    static let iconSpacing: CGFloat = 4
    static let iconTextSpacing: CGFloat = 4
    static let segmentSpacing: CGFloat = 8
    static var font: NSFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }
}

/// Shared floating surface for pointer-driven usage details. Keeping this in
/// one modifier prevents the chart and activity grid from drifting into two
/// unrelated tooltip styles.
private struct UsageTooltipSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

extension View {
    func usageTooltipSurface() -> some View {
        modifier(UsageTooltipSurface())
    }
}
