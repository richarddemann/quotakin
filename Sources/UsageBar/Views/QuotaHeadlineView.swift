import SwiftUI
import UsageCore

/// The shared quota-glance body: the percent headline, the window/reset
/// caption, a caller-supplied progress slot, the pace line, and the source
/// detail. `ProviderCardView` and `PetRowView` both render through this so a
/// card restyle can never silently miss the pet row. The only thing that
/// differs between the two callers is what goes in the progress slot — a plain
/// tinted bar for the card, or the pet ground (bar + sprite ZStack) for the
/// pet row.
struct QuotaHeadlineView<ProgressContent: View>: View {
    let snapshot: QuotaSnapshot
    let presentation: ProviderCardPresentation
    let quotaDisplayMode: QuotaDisplayMode
    @ViewBuilder let progress: () -> ProgressContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.quotaText(for: snapshot))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(presentation.isStale(snapshot) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text("\(windowTitle(for: snapshot)) · \(presentation.resetDetail(for: snapshot))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            progress()

        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: quotaDisplayMode.percent(for: snapshot)
        )
    }

    private func windowTitle(for snapshot: QuotaSnapshot) -> String {
        snapshot.window == .session ? "5-hour" : "Weekly"
    }
}

/// The tinted capacity bar shared by the card and the pet ground. Kept as its
/// own view so the fill value clamp and the `CapacityStatus` tint stay in one
/// place.
struct QuotaProgressView: View {
    let snapshot: QuotaSnapshot
    let quotaDisplayMode: QuotaDisplayMode

    var body: some View {
        ProgressView(
            value: min(max(quotaDisplayMode.percent(for: snapshot) / 100, 0), 1)
        )
        .tint(CapacityStatus(remainingPercent: snapshot.remainingPercent).color)
    }
}
