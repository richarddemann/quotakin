import SwiftUI
import UsageCore

struct ProviderCardView: View {
    let summary: ProviderSummary
    let preferences: UserPreferences
    var status: ProviderStatus?
    /// Passed through to the pet row to drive reset celebrations. Optional.
    var resetPulse: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = ProviderCardPresentation(
            summary: summary,
            quotaDisplayMode: preferences.quotaDisplayMode,
            now: Date()
        )
        let petPack = PetAssets.resolvedPack(for: summary.provider, preferences: preferences)
        let petPresentation = PetRowPresentation(
            isEnabled: preferences.petModeEnabled,
            pack: petPack,
            layout: presentation.layout
        )

        VStack(alignment: .leading, spacing: Space.xs) {
            Group {
                if petPresentation.shouldRenderPetRow, let petPack, let primary = presentation.primaryQuota {
                    PetRowView(
                        summary: summary,
                        presentation: presentation,
                        primary: primary,
                        quotaDisplayMode: preferences.quotaDisplayMode,
                        pack: petPack,
                        showProviderName: preferences.showProviderNamesInPetMode,
                        resetPulse: resetPulse
                    )
                    if let secondary = presentation.secondaryQuota {
                        secondaryQuota(snapshot: secondary, presentation: presentation)
                    }
                    sourceDetails(presentation: presentation)
                } else {
                    providerHeader(presentation: presentation)

                    switch presentation.layout {
                    case .compactUnavailable:
                        unavailableState
                    case .quotaGlance:
                        quotaGlance(presentation: presentation)
                    }
                }
            }
            .accessibilityRepresentation {
                Text(presentation.accessibilitySummary(from: []))
            }

            incidentLine
        }
    }

    /// One restrained line when the provider itself reports trouble —
    /// "quota fine, provider down" is exactly what a capacity glance owes.
    @ViewBuilder
    private var incidentLine: some View {
        if let status, status.indicator != .none, status.indicator != .unknown {
            HStack(spacing: Space.xxs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(status.indicator == .minor ? CapacityStatus.caution.color : CapacityStatus.critical.color)
                if let incident = status.incident {
                    if let link = incident.shortlink {
                        Link(incident.title, destination: link)
                    } else {
                        Text(incident.title)
                    }
                } else {
                    Text("Provider reports degraded service")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func quotaGlance(presentation: ProviderCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let primary = presentation.primaryQuota {
                quotaHeadline(snapshot: primary, presentation: presentation)
            }

            if let secondary = presentation.secondaryQuota {
                secondaryQuota(snapshot: secondary, presentation: presentation)
            }
            sourceDetails(presentation: presentation)
        }
    }

    private func providerHeader(presentation: ProviderCardPresentation) -> some View {
        HStack(spacing: 7) {
            ProviderIconView(provider: summary.provider, size: 16)
            Text(summary.provider.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if presentation.shouldShowStatusBadge {
                Text(presentation.badgeText)
                    .font(.caption)
                    .foregroundStyle(presentation.badgeColor)
            }
        }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quota unavailable")
                .font(.body.weight(.medium))
            Text(unavailableHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unavailableHint: String {
        "Open Settings → Connections to finish setup."
    }

    private func quotaHeadline(
        snapshot: QuotaSnapshot,
        presentation: ProviderCardPresentation
    ) -> some View {
        QuotaHeadlineView(
            snapshot: snapshot,
            presentation: presentation,
            quotaDisplayMode: preferences.quotaDisplayMode
        ) {
            QuotaProgressView(snapshot: snapshot, quotaDisplayMode: preferences.quotaDisplayMode)
        }
    }

    private func secondaryQuota(
        snapshot: QuotaSnapshot,
        presentation: ProviderCardPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(snapshot.window == .session ? "5-hour" : "Weekly")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(presentation.quotaLineText(for: snapshot))
                    .monospacedDigit()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func sourceDetails(presentation: ProviderCardPresentation) -> some View {
        ForEach(presentation.usableQuotas, id: \.window) { snapshot in
            if let source = presentation.sourceDetail(for: snapshot) {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
