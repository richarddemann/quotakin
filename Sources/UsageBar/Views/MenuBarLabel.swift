import SwiftUI
import UsageCore

struct MenuBarLabel: View {
    let summaries: [ProviderSummary]
    let preferences: UserPreferences
    let formatter: MenuBarFormatter

    var body: some View {
        let segments = formatter.segments(summaries: summaries, preferences: preferences)
        let iconProviders = formatter.iconProviders(preferences: preferences)

        if segments.isEmpty, !iconProviders.isEmpty,
           let image = MenuBarStatusImageRenderer.iconImage(providers: iconProviders) {
            Image(nsImage: image)
                .accessibilityLabel(iconProviders.map(\.displayName).joined(separator: ", "))
        } else if segments.isEmpty {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: MenuBarMetrics.font.pointSize, weight: .semibold))
                .accessibilityLabel("Quotakin")
        } else if let image = MenuBarStatusImageRenderer.image(
            segments: segments.map { MenuBarStatusSegment(provider: $0.provider, text: metricText(for: $0)) }
        ) {
            Image(nsImage: image)
                .accessibilityLabel(formatter.label(summaries: summaries, preferences: preferences))
        } else {
            Text(formatter.label(summaries: summaries, preferences: preferences))
                .font(.system(size: MenuBarMetrics.font.pointSize, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func metricText(for segment: MenuBarTextSegment) -> String {
        let providerName = segment.provider.shortDisplayName
        let prefix = "\(providerName) "
        guard segment.text.hasPrefix(prefix) else {
            return segment.text
        }
        return String(segment.text.dropFirst(prefix.count))
    }
}

private struct MenuBarStatusSegment {
    let provider: Provider
    let text: String
}

private enum MenuBarStatusImageRenderer {
    static func iconImage(providers: [Provider]) -> NSImage? {
        guard !providers.isEmpty else {
            return nil
        }

        let iconSize = MenuBarMetrics.iconSize
        let height = MenuBarMetrics.height
        let iconSpacing = MenuBarMetrics.iconSpacing
        let totalWidth = iconSize * CGFloat(providers.count)
            + iconSpacing * CGFloat(max(providers.count - 1, 0))
        let image = NSImage(size: CGSize(width: ceil(totalWidth), height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        var x: CGFloat = 0
        for provider in providers {
            if let icon = provider.iconImage {
                let rect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(
                    in: rect,
                    from: NSRect(origin: .zero, size: icon.size),
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            x += iconSize + iconSpacing
        }

        // The provider glyphs are shapes in the alpha channel; rendering the
        // whole status image as a template lets the menu bar recolor it for
        // light/dark appearances and menu highlight states.
        image.isTemplate = true
        return image
    }

    static func image(segments: [MenuBarStatusSegment]) -> NSImage? {
        guard !segments.isEmpty else {
            return nil
        }

        let font = MenuBarMetrics.font
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        let iconSize = MenuBarMetrics.iconSize
        let height = MenuBarMetrics.height
        let iconTextSpacing = MenuBarMetrics.iconTextSpacing
        let segmentSpacing = MenuBarMetrics.segmentSpacing
        let separator = "•" as NSString
        let separatorWidth = separator.size(withAttributes: separatorAttributes).width

        let widths = segments.enumerated().map { index, segment in
            let textWidth = (segment.text as NSString).size(withAttributes: textAttributes).width
            let separatorSpace = index < segments.count - 1 ? segmentSpacing + separatorWidth + segmentSpacing : 0
            return iconSize + iconTextSpacing + textWidth + separatorSpace
        }
        let totalWidth = max(widths.reduce(0, +), iconSize)
        let image = NSImage(size: CGSize(width: ceil(totalWidth), height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if let icon = segment.provider.iconImage {
                let rect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(
                    in: rect,
                    from: NSRect(origin: .zero, size: icon.size),
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            x += iconSize + iconTextSpacing

            let text = segment.text as NSString
            let textSize = text.size(withAttributes: textAttributes)
            text.draw(
                at: CGPoint(x: x, y: (height - textSize.height) / 2),
                withAttributes: textAttributes
            )
            x += textSize.width

            if index < segments.count - 1 {
                x += segmentSpacing
                let separatorSize = separator.size(withAttributes: separatorAttributes)
                separator.draw(
                    at: CGPoint(x: x, y: (height - separatorSize.height) / 2),
                    withAttributes: separatorAttributes
                )
                x += separatorWidth + segmentSpacing
            }
        }

        // Template rendering: shape comes from alpha, so text is drawn in
        // plain black (full and 55% alpha) and the system supplies the
        // appearance-correct color.
        image.isTemplate = true
        return image
    }
}
