import SwiftUI
import UsageCore

struct MenuBarMetricPickerPresentation {
    static func addableMetrics(
        selectedMetrics: [MenuBarMetric],
        disabledMetrics: [MenuBarMetric]
    ) -> [MenuBarMetric] {
        let selected = Set(selectedMetrics)
        return disabledMetrics.filter { !selected.contains($0) }
    }

    static func systemImage(for metric: MenuBarMetric) -> String {
        switch metric {
        case .sessionPercentage: "gauge.with.dots.needle.33percent"
        case .resetCountdown: "clock.arrow.circlepath"
        case .weeklyPercentage: "calendar.badge.clock"
        case .dailyTokens: "sun.max"
        case .weeklyTokens: "calendar.day.timeline.left"
        case .monthlyTokens: "calendar"
        case .estimatedMonthlyCost: "dollarsign.circle"
        }
    }

    static func detail(for metric: MenuBarMetric, quotaDisplayMode: QuotaDisplayMode) -> String {
        switch metric {
        case .sessionPercentage:
            "Current session quota (quotaDisplayMode.label)"
        case .resetCountdown:
            "Time until the current quota resets"
        case .weeklyPercentage:
            "Weekly quota (quotaDisplayMode.label)"
        case .dailyTokens:
            "Tokens processed today"
        case .weeklyTokens:
            "Tokens processed this week"
        case .monthlyTokens:
            "Tokens processed this month"
        case .estimatedMonthlyCost:
            "Estimated raw-token cost this month"
        }
    }
}

struct MenuBarMetricPicker: View {
    let selectedMetrics: [MenuBarMetric]
    let disabledMetrics: [MenuBarMetric]
    let quotaDisplayMode: QuotaDisplayMode
    let onSetMetric: (MenuBarMetric, Bool) -> Void
    let onMoveMetricUp: (MenuBarMetric) -> Void
    let onMoveMetricDown: (MenuBarMetric) -> Void

    @State private var isAddingMetric = false

    private var addableMetrics: [MenuBarMetric] {
        MenuBarMetricPickerPresentation.addableMetrics(
            selectedMetrics: selectedMetrics,
            disabledMetrics: disabledMetrics
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if selectedMetrics.isEmpty {
                Text("Provider icons only.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(selectedMetrics.enumerated()), id: \.element) { index, metric in
                    metricRow(metric, index: index)
                }
            }

            Button {
                isAddingMetric.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "plus")
                    Text("Add metric")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(addableMetrics.isEmpty)
            .controlSize(.small)
            .popover(isPresented: $isAddingMetric, arrowEdge: .bottom) {
                AddMetricPopover(
                    metrics: addableMetrics,
                    quotaDisplayMode: quotaDisplayMode
                ) { metric in
                    onSetMetric(metric, true)
                    isAddingMetric = false
                }
            }
        }
    }

    private func metricRow(_ metric: MenuBarMetric, index: Int) -> some View {
        HStack(spacing: Space.xs) {
            Text(metric.displayName(quotaDisplayMode: quotaDisplayMode))

            Spacer(minLength: Space.xs)

            Button {
                onMoveMetricUp(metric)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .accessibilityLabel("Move \(metric.displayName(quotaDisplayMode: quotaDisplayMode)) up")

            Button {
                onMoveMetricDown(metric)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == selectedMetrics.count - 1)
            .accessibilityLabel("Move \(metric.displayName(quotaDisplayMode: quotaDisplayMode)) down")

            Button {
                onSetMetric(metric, false)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(metric.displayName(quotaDisplayMode: quotaDisplayMode))")
        }
        .padding(.vertical, Space.xxs)
    }
}

private struct AddMetricPopover: View {
    let metrics: [MenuBarMetric]
    let quotaDisplayMode: QuotaDisplayMode
    let onSelect: (MenuBarMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Add a metric")
                    .font(.headline)
                Text("Choose what appears beside the provider icons.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.m)
            .padding(.bottom, Space.s)

            Divider()

            VStack(spacing: Space.xxs) {
                ForEach(metrics, id: \.self) { metric in
                    AddMetricOption(
                        metric: metric,
                        quotaDisplayMode: quotaDisplayMode,
                        onSelect: { onSelect(metric) }
                    )
                }
            }
            .padding(Space.xs)
        }
        .frame(width: 320)
    }
}

private struct AddMetricOption: View {
    let metric: MenuBarMetric
    let quotaDisplayMode: QuotaDisplayMode
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.s) {
                Image(systemName: MenuBarMetricPickerPresentation.systemImage(for: metric))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.control))

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.displayName(quotaDisplayMode: quotaDisplayMode))
                        .foregroundStyle(.primary)
                    Text(MenuBarMetricPickerPresentation.detail(
                        for: metric,
                        quotaDisplayMode: quotaDisplayMode
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 6)
            .background(
                isHovered ? Color.primary.opacity(0.065) : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
