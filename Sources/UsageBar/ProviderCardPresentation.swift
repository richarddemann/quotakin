import Foundation
import SwiftUI
import UsageCore

struct ProviderCardPresentation {
    struct PaceDetail: Equatable {
        let text: String
        let telemetryDetail: String
        let isAtRisk: Bool
        let window: QuotaWindow?
    }

    enum Layout {
        case quotaGlance
        case compactUnavailable
    }

    let summary: ProviderSummary
    let quotaDisplayMode: QuotaDisplayMode
    let now: Date

    var layout: Layout {
        primaryQuota == nil ? .compactUnavailable : .quotaGlance
    }

    var shouldShowQuotaBars: Bool {
        layout == .quotaGlance
    }

    var shouldShowStatusBadge: Bool {
        layout == .compactUnavailable || summary.state != .fresh
    }

    var badgeText: String {
        if layout == .compactUnavailable {
            return "Unavailable"
        }
        return summary.state.displayName
    }

    var badgeColor: Color {
        switch layout {
        case .compactUnavailable:
            .secondary
        case .quotaGlance:
            switch summary.state {
            case .fresh:
                .green
            case .stale:
                .orange
            case .unavailable:
                .secondary
            case .sourceChanged:
                .blue
            }
        }
    }

    var primaryTitle: String {
        guard let quota = primaryQuota else {
            return summary.provider.displayName
        }
        return quotaText(for: quota)
    }

    var primarySubtitle: String {
        guard let quota = primaryQuota else {
            return "No live quota available"
        }
        if quota.freshness(at: now) == .stale {
            return "Last live quota is stale"
        }
        return quota.window == .session ? "5-hour window" : "Weekly window"
    }

    var currentSessionQuota: QuotaSnapshot? {
        quota(.session)
    }

    /// All unexpired windows in product order. Presentation may promote the
    /// fresher weekly window to the headline, but this order never changes.
    var usableQuotas: [QuotaSnapshot] {
        QuotaWindow.allCases.compactMap(quota)
    }

    var primaryQuota: QuotaSnapshot? {
        let session = quota(.session)
        let weekly = quota(.weekly)
        // A fresh window outranks a stale one; the session window wins ties
        // because it is the shorter-fused decision.
        switch (session, weekly) {
        case (let session?, let weekly?):
            if isStale(session) && !isStale(weekly) {
                return weekly
            }
            return session
        case (let session?, nil):
            return session
        case (nil, let weekly?):
            return weekly
        default:
            return nil
        }
    }

    var secondaryQuota: QuotaSnapshot? {
        guard let primary = primaryQuota else {
            return nil
        }
        let other = primary.window == .session ? quota(.weekly) : quota(.session)
        return other == primary ? nil : other
    }

    func quota(_ window: QuotaWindow) -> QuotaSnapshot? {
        summary.quota
            .filter { $0.window == window && $0.resetsAt > now }
            .max { $0.observedAt < $1.observedAt }
    }

    func quotaLineText(for snapshot: QuotaSnapshot) -> String {
        let percent = quotaText(for: snapshot)
        guard snapshot.window == .weekly else {
            return "\(percent) · \(resetDetail(for: snapshot))"
        }
        let relative = Self.relativeResetFormatter.string(from: now, to: snapshot.resetsAt) ?? "reset"
        return "\(percent) · Resets \(Self.weeklyDateFormatter.string(from: snapshot.resetsAt)) · \(relative)"
    }

    func resetDetail(for snapshot: QuotaSnapshot) -> String {
        let relative = Self.relativeResetFormatter.string(from: now, to: snapshot.resetsAt) ?? "reset"
        if snapshot.window == .weekly {
            return "Resets \(Self.weeklyDateFormatter.string(from: snapshot.resetsAt)) · \(relative)"
        }
        return "Resets \(relative)"
    }

    var sourcesMateriallyDiffer: Bool {
        Set(usableQuotas.map {
            "\($0.source.rawValue):\($0.freshness(at: now).rawValue):\(ageText(since: $0.observedAt))"
        }).count > 1
    }

    func sourceDetail(for snapshot: QuotaSnapshot) -> String? {
        if !sourcesMateriallyDiffer, snapshot != primaryQuota {
            return nil
        }

        let source = switch (snapshot.source, snapshot.freshness(at: now)) {
        case (.account, .fresh):
            "Account quota"
        case (.account, .stale):
            "Last known account quota"
        case (.local, .fresh):
            "This Mac only"
        case (.local, .stale):
            "Last known on this Mac"
        }
        let prefix = sourcesMateriallyDiffer ? "\(windowTitle(for: snapshot)): " : ""
        return "\(prefix)\(source) · updated \(ageText(since: snapshot.observedAt))"
    }

    func quotaText(for snapshot: QuotaSnapshot) -> String {
        String(format: "%.0f%% %@", quotaDisplayMode.percent(for: snapshot), quotaDisplayMode.label)
    }

    func isStale(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.freshness(at: now) == .stale
    }

    /// One consequence derived only from predictions describing the exact
    /// provider/window/source/reset cycle currently on screen.
    func paceDetail(from predictions: [QuotaLimitPrediction]) -> PaceDetail? {
        let matches = usableQuotas.compactMap { snapshot -> QuotaLimitPrediction? in
            predictions.first {
                predictionMatches($0, snapshot: snapshot)
            }
        }

        let risks = matches.compactMap { prediction -> (QuotaLimitPrediction, Date)? in
            guard case .atRisk(let projectedAt) = prediction.verdict else {
                return nil
            }
            return (prediction, projectedAt)
        }.sorted { $0.1 < $1.1 }

        if let (prediction, projectedAt) = risks.first {
            let time = Self.paceTimeFormatter.string(from: projectedAt)
            return PaceDetail(
                text: "At this pace, the \(windowTitle(for: prediction.window)) limit runs out around \(time)",
                telemetryDetail: telemetryDetail(for: prediction),
                isAtRisk: true,
                window: prediction.window
            )
        }

        guard usableQuotas.count == 2,
              matches.count == 2,
              matches.allSatisfy({
                  $0.verdict == .onTrack && $0.pace != nil
              })
        else {
            return nil
        }
        return PaceDetail(
            text: "Both limits on track",
            telemetryDetail: matches.map(telemetryDetail).joined(separator: "; "),
            isAtRisk: false,
            window: nil
        )
    }

    func accessibilitySummary(from predictions: [QuotaLimitPrediction]) -> String {
        let pace = paceDetail(from: predictions)
        var parts = [summary.provider.displayName]
        for snapshot in usableQuotas {
            parts.append(
                "\(windowTitle(for: snapshot.window)), \(quotaText(for: snapshot)), \(resetDetail(for: snapshot))"
            )
            if pace?.window == snapshot.window, let pace {
                parts.append("\(pace.text). \(pace.telemetryDetail)")
            }
        }
        if let pace, pace.window == nil {
            parts.append("\(pace.text). \(pace.telemetryDetail)")
        }
        parts += usableQuotas.compactMap(sourceDetail)
        return parts.joined(separator: ". ")
    }

    func windowTitle(for window: QuotaWindow) -> String {
        window == .session ? "5-hour" : "weekly"
    }

    private func windowTitle(for snapshot: QuotaSnapshot) -> String {
        snapshot.window == .session ? "5-hour" : "Weekly"
    }

    private func predictionMatches(
        _ prediction: QuotaLimitPrediction,
        snapshot: QuotaSnapshot
    ) -> Bool {
        prediction.provider == snapshot.provider
            && prediction.window == snapshot.window
            && prediction.source == snapshot.source
            && prediction.resetsAt == snapshot.resetsAt
            && prediction.observedAt <= now
            && now.timeIntervalSince(prediction.observedAt) <= 600
    }

    private func telemetryDetail(for prediction: QuotaLimitPrediction) -> String {
        let rate = prediction.burnRatePercentPerHour.map {
            String(format: "%.0f%%/hr", $0)
        } ?? "rate unavailable"
        return "\(windowTitle(for: prediction.window)): \(rate), \(durationText(prediction.lookback)) lookback"
    }

    private func ageText(since date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return "now"
        }
        if seconds < 3_600 {
            return "\(Int(seconds / 60))m ago"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3_600))h ago"
        }
        return "\(Int(seconds / 86_400))d ago"
    }

    private func durationText(_ duration: TimeInterval) -> String {
        if duration.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(duration / 3_600))h"
        }
        return "\(Int(duration / 60))m"
    }

    private static let weeklyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let relativeResetFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let paceTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

}
