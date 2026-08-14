import Foundation

public struct MenuBarTextSegment: Equatable, Sendable {
    public let provider: Provider
    public let text: String

    public init(provider: Provider, text: String) {
        self.provider = provider
        self.text = text
    }
}

public struct MenuBarFormatter: Sendable {
    private let pricingCatalog: PricingCatalog
    private let calendar: Calendar

    public init(
        pricingCatalog: PricingCatalog = .bundled,
        calendar: Calendar = .current
    ) {
        self.pricingCatalog = pricingCatalog
        self.calendar = calendar
    }

    public func label(
        summaries: [ProviderSummary],
        preferences: UserPreferences,
        now: Date = Date()
    ) -> String {
        segments(summaries: summaries, preferences: preferences, now: now)
            .map(\.text)
            .joined(separator: "  •  ")
    }

    public func segments(
        summaries: [ProviderSummary],
        preferences: UserPreferences,
        now: Date = Date()
    ) -> [MenuBarTextSegment] {
        guard !preferences.providers.isEmpty, !preferences.menuBarMetrics.isEmpty else {
            return []
        }

        let summariesByProvider = Dictionary(uniqueKeysWithValues: summaries.map { ($0.provider, $0) })

        let activeSegments: [MenuBarTextSegment] = preferences.providers.compactMap { provider in
            guard let summary = summariesByProvider[provider] else {
                return nil
            }

            let text = text(
                for: summary,
                metrics: preferences.menuBarMetrics,
                quotaDisplayMode: preferences.quotaDisplayMode,
                now: now
            )
            guard !text.isEmpty else {
                return nil
            }

            return MenuBarTextSegment(provider: provider, text: text)
        }

        if !activeSegments.isEmpty {
            return activeSegments
        }

        return preferences.providers.compactMap { provider in
            guard let summary = summariesByProvider[provider] else {
                return nil
            }
            let text = statusText(for: summary)
            guard !text.isEmpty else {
                return nil
            }
            return MenuBarTextSegment(provider: provider, text: text)
        }
    }

    public func iconProviders(preferences: UserPreferences) -> [Provider] {
        guard preferences.menuBarMetrics.isEmpty else {
            return []
        }
        return preferences.providers
    }

    private func text(
        for summary: ProviderSummary,
        metrics: [MenuBarMetric],
        quotaDisplayMode: QuotaDisplayMode,
        now: Date
    ) -> String {
        switch summary.state {
        case .unavailable:
            break
        case .sourceChanged:
            return ""
        case .fresh, .stale:
            break
        }

        let modules = formattedModules(
            summary: summary,
            metrics: metrics,
            quotaDisplayMode: quotaDisplayMode,
            now: now
        )

        guard !modules.isEmpty else {
            guard let observedUsage = observedUsageText(for: summary) else {
                if metrics.containsQuotaMetric {
                    return "\(summary.provider.menuBarDisplayName) \(quotaUnavailableText(for: summary))"
                }
                return ""
            }
            return "\(summary.provider.menuBarDisplayName) \(observedUsage)"
        }

        var displayModules = modules
        if summary.state == .stale {
            displayModules.append("· \(formatStaleSuffix(for: summary, now: now))")
        }

        return ([summary.provider.menuBarDisplayName] + displayModules).joined(separator: " ")
    }

    private func statusText(for summary: ProviderSummary) -> String {
        switch summary.state {
        case .unavailable:
            "\(summary.provider.menuBarDisplayName) \(quotaUnavailableText(for: summary))"
        case .sourceChanged:
            "\(summary.provider.menuBarDisplayName) updating"
        case .fresh, .stale:
            "\(summary.provider.menuBarDisplayName) no quota"
        }
    }

    private func quotaUnavailableText(for summary: ProviderSummary) -> String {
        if summary.tokens.isEmpty && summary.quota.isEmpty {
            return "no data"
        }
        return "no quota"
    }

    private func observedUsageText(for summary: ProviderSummary) -> String? {
        let total = summary.tokens.reduce(0) { $0 + $1.totalTokens }
        guard total > 0 else {
            return nil
        }
        return formatCompactNumber(total)
    }

    private func formattedModules(
        summary: ProviderSummary,
        metrics: [MenuBarMetric],
        quotaDisplayMode: QuotaDisplayMode,
        now: Date
    ) -> [String] {
        let orderedMetrics = metricsForMenuBarDisplay(metrics)
        var modules: [String] = []
        var skipWeeklyPercentage = false

        for metric in orderedMetrics {
            if metric == .sessionPercentage,
               metrics.contains(.weeklyPercentage),
               let session = quota(summary: summary, window: .session, now: now),
               let weekly = quota(summary: summary, window: .weekly, now: now) {
                modules.append(
                    "\(formatNumber(quotaDisplayMode.percent(for: session), maximumFractionDigits: 0))/\(formatNumber(quotaDisplayMode.percent(for: weekly), maximumFractionDigits: 0))% \(quotaDisplayMode.label)"
                )
                skipWeeklyPercentage = true
                continue
            }

            if metric == .weeklyPercentage, skipWeeklyPercentage {
                continue
            }

            if let formatted = formatted(
                metric: metric,
                summary: summary,
                metrics: metrics,
                quotaDisplayMode: quotaDisplayMode,
                now: now
            ) {
                modules.append(formatted)
            }
        }

        return modules
    }

    private func formatted(
        metric: MenuBarMetric,
        summary: ProviderSummary,
        metrics: [MenuBarMetric],
        quotaDisplayMode: QuotaDisplayMode,
        now: Date
    ) -> String? {
        switch metric {
        case .sessionPercentage:
            return quota(summary: summary, window: .session, now: now).map { formatQuota($0, mode: quotaDisplayMode) }
        case .resetCountdown:
            return quota(summary: summary, window: resetWindow(for: metrics), now: now)
                .map { formatCountdown(from: now, to: $0.resetsAt) }
        case .weeklyPercentage:
            return quota(summary: summary, window: .weekly, now: now).map { formatQuota($0, mode: quotaDisplayMode) }
        case .dailyTokens:
            return formatTokenTotal(summary, since: calendar.startOfDay(for: now), suffix: "today")
        case .weeklyTokens:
            return formatTokenTotal(summary, since: startOfWeek(for: now), suffix: "week")
                .map { "· \($0)" }
        case .monthlyTokens:
            return formatTokenTotal(summary, since: startOfMonth(for: now), suffix: "month")
                .map { "· \($0)" }
        case .estimatedMonthlyCost:
            return formatEstimatedMonthlyCost(summary, since: startOfMonth(for: now))
        }
    }

    private func resetWindow(for metrics: [MenuBarMetric]) -> QuotaWindow {
        if metrics.contains(.weeklyPercentage), !metrics.contains(.sessionPercentage) {
            return .weekly
        }
        return .session
    }

    private func metricsForMenuBarDisplay(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        guard metrics.contains(.resetCountdown), metrics.count > 2 else {
            return metrics
        }
        return metrics.filter { $0 != .resetCountdown } + [.resetCountdown]
    }

    private func quota(summary: ProviderSummary, window: QuotaWindow, now: Date) -> QuotaSnapshot? {
        summary.quota
            .filter { $0.window == window && $0.isCurrent(at: now) }
            .sorted { first, second in
                if first.observedAt == second.observedAt {
                    return first.resetsAt > second.resetsAt
                }
                return first.observedAt > second.observedAt
            }
            .first
    }

    private func formatTokenTotal(_ summary: ProviderSummary, since start: Date, suffix: String) -> String? {
        let total = summary.tokens
            .filter { $0.observedAt >= start }
            .reduce(0) { $0 + $1.totalTokens }

        guard total > 0 else {
            return nil
        }

        return "\(formatCompactNumber(total)) \(suffix)"
    }

    private func formatEstimatedMonthlyCost(_ summary: ProviderSummary, since start: Date) -> String? {
        let estimates = summary.tokens
            .filter { $0.observedAt >= start }
            .map { pricingCatalog.costEstimate(for: $0) }
        guard estimates.allSatisfy({ $0.amountUSD != nil }) else { return nil }
        let total = estimates.compactMap(\.amountUSD).reduce(Decimal(0), +)

        guard total > 0 else {
            return nil
        }

        return "\(formatCurrency(total))/mo"
    }

    private func formatPercent(_ percent: Double) -> String {
        "\(formatNumber(percent, maximumFractionDigits: 1))%"
    }

    private func formatQuota(_ snapshot: QuotaSnapshot, mode: QuotaDisplayMode) -> String {
        "\(formatPercent(mode.percent(for: snapshot))) \(mode.label)"
    }

    private func formatCountdown(from now: Date, to resetsAt: Date) -> String {
        let remainingSeconds = resetsAt.timeIntervalSince(now)
        guard remainingSeconds > 0 else {
            return "reset"
        }

        let totalMinutes = max(1, Int(remainingSeconds / 60))
        guard totalMinutes >= 60 else {
            return "\(totalMinutes)m"
        }

        let days = totalMinutes / (24 * 60)
        if days > 0 {
            let hours = (totalMinutes % (24 * 60)) / 60
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 2 {
            return "\(hours)h"
        }
        return "\(hours)h \(String(format: "%02d", minutes))m"
    }

    private func formatStaleSuffix(for summary: ProviderSummary, now: Date) -> String {
        guard let observedAt = latestObservedAt(for: summary) else {
            return "stale"
        }

        let ageSeconds = now.timeIntervalSince(observedAt)
        guard ageSeconds > 0 else {
            return "stale"
        }

        return "stale \(formatDuration(ageSeconds))"
    }

    private func latestObservedAt(for summary: ProviderSummary) -> Date? {
        summary.quota.map(\.observedAt).max()
            ?? summary.tokens.map(\.observedAt).max()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(seconds / 60))
        guard totalMinutes >= 60 else {
            return "\(totalMinutes)m"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard minutes > 0 else {
            return "\(hours)h"
        }

        return "\(hours)h \(String(format: "%02d", minutes))m"
    }

    private func formatCompactNumber(_ value: Int) -> String {
        let doubleValue = Double(value)

        if value >= 1_000_000 {
            return "\(formatNumber(doubleValue / 1_000_000, maximumFractionDigits: 2))M"
        }
        if value >= 1_000 {
            let roundedThousands = (doubleValue / 1_000 * 10).rounded() / 10
            if roundedThousands >= 1_000 {
                return "\(formatNumber(doubleValue / 1_000_000, maximumFractionDigits: 2))M"
            }
            return "\(formatNumber(roundedThousands, maximumFractionDigits: 1))K"
        }
        return "\(value)"
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        return String(format: "$%.2f", number.doubleValue)
    }

    private func formatNumber(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func startOfWeek(for date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    private func startOfMonth(for date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }
}

private extension Provider {
    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var menuBarDisplayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }
}

private extension Array where Element == MenuBarMetric {
    var containsQuotaMetric: Bool {
        contains(.sessionPercentage)
            || contains(.weeklyPercentage)
            || contains(.resetCountdown)
    }
}
