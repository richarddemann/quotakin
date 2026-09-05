import SwiftUI
import UsageCore

/// Quota headline and reset time with either a plain bar or pet track.
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
