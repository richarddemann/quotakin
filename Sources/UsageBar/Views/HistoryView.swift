import AppKit
import Charts
import SwiftUI
import UsageCore

enum QuotaChartSegmenter {
    static func displayPoints(from points: [QuotaHistoryPoint]) -> [QuotaHistoryPoint] {
        Dictionary(grouping: points, by: \.resetsAt).values
            .flatMap { resetCycle in
                let preferredSource: QuotaSource = resetCycle.contains(where: { $0.source == .account })
                    ? .account
                    : .local
                return resetCycle.filter { $0.source == preferredSource }
            }
            .sorted { $0.observedAt < $1.observedAt }
    }

    static func segments(from points: [QuotaHistoryPoint]) -> [[QuotaHistoryPoint]] {
        let sortedPoints = points.sorted { $0.observedAt < $1.observedAt }
        guard let first = sortedPoints.first else { return [] }

        return sortedPoints.dropFirst().reduce(into: [[first]]) { segments, point in
            guard let previous = segments[segments.count - 1].last else {
                segments[segments.count - 1].append(point)
                return
            }
            if point.resetsAt != previous.resetsAt {
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }
    }
}

struct HistoryLayout {
    static let compactBreakpoint: CGFloat = 800

    let availableWidth: CGFloat

    var isCompact: Bool {
        availableWidth < Self.compactBreakpoint
    }

    var horizontalPadding: CGFloat {
        isCompact ? 22 : 30
    }

    var sectionSpacing: CGFloat {
        isCompact ? 30 : 34
    }

    var metricColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading),
            count: 2
        )
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var chartMetric: UsageChartMetric = .cost
    @State private var breakdownDimension: UsageBreakdownDimension = .model
    @State private var hoveredChartDate: Date?
    @State private var selectedActivityDay: DailyActivityGridDay?
    @State private var isShowingMetricExplanation = false

    private let contentWidth: CGFloat = 990

    var body: some View {
        GeometryReader { geometry in
            let layout = HistoryLayout(availableWidth: geometry.size.width)

            ScrollView {
                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    header
                    overview(layout: layout)
                    metricStrip(layout: layout)
                    activity
                    breakdown(layout: layout)
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 26)
                .padding(.bottom, 38)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Usage")
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .task {
            await model.reloadDashboardData()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Usage")
                .font(.system(size: 28, weight: .semibold))
            Text(rangeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func overview(layout: HistoryLayout) -> some View {
        if layout.isCompact {
            VStack(alignment: .leading, spacing: 30) {
                costSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
                usageChart
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(alignment: .top, spacing: 54) {
                costSummary
                    .frame(width: 318, alignment: .leading)
                usageChart
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var costSummary: some View {
        VStack(alignment: .leading, spacing: 25) {
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryHeadline)
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                HStack(spacing: 5) {
                    Text(primaryLabel)
                        .tracking(0.8)

                    Button {
                        isShowingMetricExplanation.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("About \(primaryLabel.lowercased())")
                    .accessibilityLabel("About \(primaryLabel.lowercased())")
                    .popover(isPresented: $isShowingMetricExplanation, arrowEdge: .bottom) {
                        Text(primaryDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 270, alignment: .leading)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 28) {
                ForEach(nonEmptyOverviews) { overview in
                    ProviderCostRow(
                        overview: overview,
                        totalCost: totalEstimatedCost,
                        totalTokens: totalTokens,
                        metric: chartMetric,
                        tint: tint(for: overview.provider)
                    )
                }
            }
        }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartIntervalTitle)
                        .font(.headline)
                    HStack(spacing: 12) {
                        ForEach(nonEmptyOverviews) { overview in
                            HStack(spacing: 5) {
                                ProviderIconView(provider: overview.provider, size: 11)
                                Text(overview.provider.displayName)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Metric", selection: $chartMetric) {
                    ForEach(UsageChartMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .usageSegmentedControl()
            }

            switch chartAvailability {
            case .noUsage:
                ContentUnavailableView(
                    "No usage in this range",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Usage appears here after transcript indexing completes.")
                )
                .frame(height: 196)
            case .costUnavailable:
                ContentUnavailableView(
                    "Cost unavailable",
                    systemImage: "dollarsign.circle",
                    description: Text("Tokens were indexed, but no matching model prices are available.")
                )
                .frame(height: 196)
            case .available:
                Chart {
                    ForEach(chartSeries) { series in
                        ForEach(series.points) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            yStart: .value("Baseline", 0),
                            yEnd: .value(chartMetric.title, point.value)
                        )
                        .foregroundStyle(by: .value("Provider", series.provider.displayName))
                        .opacity(0.12)
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(chartMetric.title, point.value)
                        )
                        .foregroundStyle(by: .value("Provider", series.provider.displayName))
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                        }
                    }

                }
                .chartForegroundStyleScale(providerColorScale)
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(chartAxisLabel(number))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: chartAxisDates) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(date))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            ChartPointerTrackingView(
                                onMoved: { location in
                                    guard
                                        let plotFrame = proxy.plotFrame.map({ geometry[$0] }),
                                        plotFrame.contains(location),
                                        let date: Date = proxy.value(atX: location.x - plotFrame.minX)
                                    else {
                                        hoveredChartDate = nil
                                        return
                                    }
                                    hoveredChartDate = nearestChartDate(to: date)
                                },
                                onExited: {
                                    hoveredChartDate = nil
                                }
                            )

                            if
                                let hoveredChartDate,
                                let plotAnchor = proxy.plotFrame,
                                let relativeX = proxy.position(forX: hoveredChartDate)
                            {
                                let plotFrame = geometry[plotAnchor]
                                let ruleX = plotFrame.minX + relativeX
                                let tooltipWidth: CGFloat = 154
                                let preferredTooltipX = ruleX + 10
                                let flippedTooltipX = ruleX - tooltipWidth - 10
                                let tooltipX = min(
                                    max(
                                        plotFrame.minX,
                                        preferredTooltipX + tooltipWidth <= plotFrame.maxX
                                            ? preferredTooltipX
                                            : flippedTooltipX
                                    ),
                                    plotFrame.maxX - tooltipWidth
                                )

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.58))
                                    .frame(width: 1, height: plotFrame.height)
                                    .offset(x: ruleX, y: plotFrame.minY)
                                    .allowsHitTesting(false)

                                ForEach(hoveredChartRows(at: hoveredChartDate)) { row in
                                    if let relativeY = proxy.position(forY: row.value) {
                                        Circle()
                                            .fill(tint(for: row.provider))
                                            .frame(width: 7, height: 7)
                                            .overlay {
                                                Circle()
                                                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                                            }
                                            .offset(
                                                x: ruleX - 3.5,
                                                y: plotFrame.minY + relativeY - 3.5
                                            )
                                            .allowsHitTesting(false)
                                    }
                                }

                                UsageChartTooltip(
                                    date: hoveredChartDate,
                                    rows: hoveredChartRows(at: hoveredChartDate),
                                    metric: chartMetric
                                )
                                .frame(width: tooltipWidth)
                                .offset(x: tooltipX, y: plotFrame.minY + 8)
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private func metricStrip(layout: HistoryLayout) -> some View {
        if layout.isCompact {
            LazyVGrid(columns: layout.metricColumns, alignment: .leading, spacing: 22) {
                ForEach(metrics) { metric in
                    UsageMetricView(metric: metric)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 3)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    UsageMetricView(metric: metric)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, index == 0 ? 0 : 16)
                        .padding(.trailing, index == metrics.count - 1 ? 0 : 16)
                    if index < metrics.count - 1 {
                        Divider()
                            .frame(height: 62)
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var activity: some View {
        if let grid = model.activityGrid, !grid.days.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity")
                        .font(.title3.weight(.semibold))
                    Text("\(activityMetricSubtitle) · \(activityYear)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ActivityGridView(
                    grid: grid,
                    selectedDay: $selectedActivityDay,
                    tint: .activityTint,
                    metric: chartMetric == .cost ? .cost : .tokens
                )
            }
        }
    }

    private func breakdown(layout: HistoryLayout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Breakdown")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Breakdown", selection: $breakdownDimension) {
                    ForEach(UsageBreakdownDimension.allCases) { dimension in
                        Text(dimension.title).tag(dimension)
                    }
                }
                .usageSegmentedControl()
            }

            VStack(spacing: 0) {
                if !layout.isCompact {
                    breakdownHeader
                    Divider()
                }
                ForEach(Array(breakdownRows.enumerated()), id: \.element.id) { index, row in
                    breakdownRow(row, isCompact: layout.isCompact)
                    if index < breakdownRows.count - 1 {
                        Divider()
                    }
                }
            }

            if totalUnknownPricingCount > 0 {
                Label(
                    totalUnknownPricingCount.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
                        + " samples have no matching price and are excluded from cost totals.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var breakdownHeader: some View {
        HStack(spacing: 12) {
            Text(breakdownDimension.columnTitle.uppercased())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("COST")
                .frame(width: 110, alignment: .trailing)
            Text("SHARE")
                .frame(width: 150, alignment: .trailing)
            Text("TOKENS")
                .frame(width: 118, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .tracking(0.7)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func breakdownRow(_ row: UsageBreakdownRow, isCompact: Bool) -> some View {
        if isCompact {
            compactBreakdownRow(row)
        } else {
            regularBreakdownRow(row)
        }
    }

    private func regularBreakdownRow(_ row: UsageBreakdownRow) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                if let provider = row.provider {
                    ProviderIconView(provider: provider, size: 14)
                } else {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.costText)
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)

            HStack(spacing: 10) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.secondary.opacity(0.13))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(row.tint.opacity(0.85))
                                .frame(width: geometry.size.width * row.share)
                        }
                }
                .frame(width: 78, height: 5)
                Text(row.share.percentString)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)

            Text(row.tokens.compactTokenString)
                .monospacedDigit()
                .frame(width: 118, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func compactBreakdownRow(_ row: UsageBreakdownRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if let provider = row.provider {
                    ProviderIconView(provider: provider, size: 14)
                } else {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text(row.costText)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            HStack {
                Text(row.share.percentString + " share")
                Spacer()
                Text(row.tokens.compactTokenString + " tokens")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                UsageRangeSelector(selection: $model.historyRange, ranges: displayedRanges)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                UsageRangeSelector(selection: $model.historyRange, ranges: displayedRanges)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refreshNow() }
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18, alignment: .center)
            }
            .accessibilityLabel(model.isRefreshing ? "Refreshing usage" : "Refresh")
            .disabled(model.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh usage (Command-R)")
        }
    }

    private var displayedRanges: [UsageHistoryRange] {
        [.twentyFourHours, .sevenDays, .thirtyDays, .ninetyDays]
    }

    private var activityYear: String {
        let year = model.activityGrid?.days.first.map { Calendar.current.component(.year, from: $0.dayStart) }
            ?? Calendar.current.component(.year, from: Date())
        return year.formatted(.number.grouping(.never))
    }

    private var activityMetricSubtitle: String {
        chartMetric == .cost ? "Daily raw token cost" : "Daily processed tokens"
    }

    private var nonEmptyOverviews: [ProviderUsageOverview] {
        model.dashboardOverviews
            .filter { $0.totalTokens > 0 }
            .sorted { $0.estimatedCost > $1.estimatedCost }
    }

    private var totalEstimatedCost: Decimal {
        nonEmptyOverviews.reduce(0) { $0 + $1.estimatedCost }
    }

    private var primaryHeadline: String {
        if chartMetric == .cost, totalEstimatedCost == 0, totalUnknownPricingCount > 0 {
            return "—"
        }
        return chartMetric == .cost ? totalEstimatedCost.usdString : totalTokens.compactTokenString
    }

    private var primaryLabel: String {
        chartMetric == .cost ? "RAW TOKEN COST" : "PROCESSED TOKENS"
    }

    private var primaryDescription: String {
        chartMetric == .cost
            ? "Estimated API value of your observed usage. Subscription charges may differ. \(pricingStatusDescription)"
            : "Observed usage reconstructed locally from Claude and Codex transcripts."
    }

    private var pricingStatusDescription: String {
        switch model.pricingCatalog.status {
        case .fresh:
            "Pricing refreshed \(pricingDateDescription)."
        case .cached:
            "Using cached pricing from \(pricingDateDescription)."
        case .fallback:
            "Using the limited bundled pricing catalogue."
        }
    }

    private var pricingDateDescription: String {
        guard let fetchedAt = model.pricingCatalog.fetchedAt else { return "recently" }
        return fetchedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var totalTokens: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.totalTokens }
    }

    private var totalCachedTokens: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.cachedInputTokens }
    }

    private var totalUncachedTokens: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.uncachedInputTokens }
    }

    private var totalCacheWrites: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.cacheCreationInputTokens }
    }

    private var totalOutputTokens: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.outputTokens }
    }

    private var totalReasoningTokens: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.reasoningOutputTokens }
    }

    private var totalCacheSavings: Decimal {
        nonEmptyOverviews.reduce(0) { $0 + $1.cacheSavings }
    }

    private var totalUnknownPricingCount: Int {
        nonEmptyOverviews.reduce(0) { $0 + $1.unknownPricingCount }
    }

    private var activeDayCount: Int {
        guard let series = model.historySeries else { return 0 }
        let calendar = Calendar.current
        let dates = series.providers.flatMap(\.buckets)
            .filter { $0.tokens.total > 0 }
            .map { calendar.startOfDay(for: $0.start) }
        return Set(dates).count
    }

    private var observedInputTokens: Int {
        totalUncachedTokens + totalCachedTokens + totalCacheWrites
    }

    private var metrics: [UsageMetricItem] {
        let cachedShare = observedInputTokens > 0 ? Double(totalCachedTokens) / Double(observedInputTokens) : 0
        let savingsRatio = totalEstimatedCost > 0
            ? NSDecimalNumber(decimal: totalCacheSavings / totalEstimatedCost).doubleValue
            : 0
        return [
            UsageMetricItem(
                label: "Processed",
                value: totalTokens.compactTokenString,
                detail: activeDayCount > 0 ? "\((totalTokens / activeDayCount).compactTokenString) / active day" : "No active days"
            ),
            UsageMetricItem(
                label: "Cached input",
                value: totalCachedTokens.compactTokenString,
                detail: cachedShare.wholePercentString + " of observed input"
            ),
            UsageMetricItem(
                label: "Uncached input",
                value: totalUncachedTokens.compactTokenString,
                detail: totalCacheWrites > 0 ? totalCacheWrites.compactTokenString + " cache writes" : "No cache writes"
            ),
            UsageMetricItem(
                label: "Output",
                value: totalOutputTokens.compactTokenString,
                detail: totalReasoningTokens.compactTokenString + " reasoning"
            ),
            UsageMetricItem(
                label: "Cache savings",
                value: totalCacheSavings.usdString,
                detail: savingsRatio.oneDecimalString + "× raw cost"
            )
        ]
    }

    private var chartSeries: [UsageChartSeries] {
        guard let history = model.historySeries else { return [] }
        return history.providers.map { providerHistory in
            UsageChartSeries(
                provider: providerHistory.provider,
                points: providerHistory.buckets.map { bucket in
                    UsageChartPoint(
                        date: bucket.start,
                        value: chartMetric == .cost
                            ? NSDecimalNumber(decimal: bucket.estimatedCost).doubleValue
                            : Double(bucket.tokens.total)
                    )
                }
            )
        }
    }

    private var chartAvailability: UsageChartAvailability {
        UsageChartAvailability.resolve(
            metric: chartMetric,
            totalTokens: totalTokens,
            hasNonZeroPoints: chartSeries.contains { series in
                series.points.contains { $0.value != 0 }
            },
            hasUnpricedSamples: totalUnknownPricingCount > 0
        )
    }

    private var breakdownRows: [UsageBreakdownRow] {
        switch breakdownDimension {
        case .model:
            let entries = nonEmptyOverviews.flatMap { overview in
                overview.modelRows.map { row in
                    UsageBreakdownAccumulator(
                        key: "\(overview.provider.rawValue):\(row.model)",
                        label: row.model,
                        detail: overview.provider.displayName,
                        provider: overview.provider,
                        tokens: row.tokens,
                        cost: row.estimatedCost,
                        unknownPricingCount: row.unknownPricingCount
                    )
                }
            }
            return makeBreakdownRows(entries)
        case .day:
            guard let series = model.historySeries else { return [] }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, MMM d"
            let calendar = Calendar.current
            var grouped: [Date: UsageBreakdownAccumulator] = [:]
            for provider in series.providers {
                for bucket in provider.buckets where bucket.tokens.total > 0 {
                    let day = calendar.startOfDay(for: bucket.start)
                    let current = grouped[day] ?? UsageBreakdownAccumulator(
                        key: day.formatted(.iso8601),
                        label: formatter.string(from: day),
                        detail: nil,
                        provider: provider.provider,
                        tokens: 0,
                        cost: 0,
                        unknownPricingCount: 0
                    )
                    grouped[day] = current.adding(
                        tokens: bucket.tokens.total,
                        cost: bucket.estimatedCost,
                        unknownPricingCount: bucket.unknownPricingSampleCount
                    )
                }
            }
            return makeBreakdownRows(grouped.values.sorted { $0.key > $1.key })
        }
    }

    private func makeBreakdownRows<S: Sequence>(_ entries: S) -> [UsageBreakdownRow]
    where S.Element == UsageBreakdownAccumulator {
        let values = Array(entries).filter { $0.tokens > 0 }
        let denominator = max(values.reduce(Decimal(0)) { $0 + $1.cost }, Decimal(1))
        return values
            .sorted { lhs, rhs in
                breakdownDimension == .day ? lhs.key > rhs.key : lhs.cost > rhs.cost
            }
            .map { entry in
                UsageBreakdownRow(
                    id: entry.key,
                    label: entry.label,
                    detail: entry.detail,
                    cost: entry.cost,
                    tokens: entry.tokens,
                    share: max(0, min(1, NSDecimalNumber(decimal: entry.cost / denominator).doubleValue)),
                    unknownPricingCount: entry.unknownPricingCount,
                    provider: breakdownDimension == .model ? entry.provider : nil,
                    tint: tint(for: entry.provider)
                )
            }
    }

    private var providerColorScale: KeyValuePairs<String, Color> {
        [
            Provider.codex.displayName: tint(for: .codex),
            Provider.claude.displayName: tint(for: .claude)
        ]
    }

    private func tint(for provider: Provider) -> Color {
        switch provider {
        case .codex: .codexTint
        case .claude: .claudeTint
        }
    }

    private var rangeDescription: String {
        guard let series = model.historySeries else { return model.historyRange.accessibleTitle }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: series.start) + " – " + formatter.string(from: series.end)
    }

    private var chartIntervalTitle: String {
        model.historyRange == .twentyFourHours ? "Hourly" : "Daily"
    }

    private var chartAxisDates: [Date] {
        guard let series = model.historySeries else { return [] }
        let midpoint = series.start.addingTimeInterval(series.end.timeIntervalSince(series.start) / 2)
        return [series.start, midpoint, series.end]
    }

    private func nearestChartDate(to date: Date) -> Date? {
        let dates = chartSeries.flatMap(\.points).map(\.date)
        return dates.min {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }
    }

    private func hoveredChartRows(at date: Date) -> [UsageChartHoverRow] {
        chartSeries.compactMap { series in
            guard let point = series.points.first(where: { $0.date == date }) else { return nil }
            return UsageChartHoverRow(provider: series.provider, value: point.value)
        }
        .sorted { left, right in
            if left.provider == right.provider { return false }
            return left.provider == .codex
        }
    }

    private func xAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = model.historyRange == .twentyFourHours ? "ha" : "MMM d"
        return formatter.string(from: date)
    }

    private func chartAxisLabel(_ value: Double) -> String {
        if chartMetric == .cost {
            return "$" + Int(value.rounded()).formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
        }
        return Int(value.rounded()).compactTokenString
    }
}

private struct ProviderCostRow: View {
    let overview: ProviderUsageOverview
    let totalCost: Decimal
    let totalTokens: Int
    let metric: UsageChartMetric
    let tint: Color

    private var share: Double {
        switch metric {
        case .cost:
            guard totalCost > 0 else { return 0 }
            return max(0, min(1, NSDecimalNumber(decimal: overview.estimatedCost / totalCost).doubleValue))
        case .tokens:
            guard totalTokens > 0 else { return 0 }
            return max(0, min(1, Double(overview.totalTokens) / Double(totalTokens)))
        }
    }

    private var primaryValue: String {
        if metric == .cost, overview.estimatedCost == 0, overview.unknownPricingCount > 0 {
            return "—"
        }
        return metric == .cost ? overview.estimatedCost.usdString : overview.totalTokens.compactTokenString
    }

    private var secondaryValue: String {
        switch metric {
        case .cost:
            share.percentString + " · " + overview.totalTokens.compactTokenString
        case .tokens:
            share.percentString + " of tokens"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    ProviderIconView(provider: overview.provider, size: 14)
                    Text(overview.provider.displayName)
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Text(primaryValue)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text(secondaryValue)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * share)
                    }
            }
            .frame(height: 5)
        }
    }
}

private struct UsageMetricView: View {
    let metric: UsageMetricItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(metric.value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
            Text(metric.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct UsageMetricItem: Identifiable {
    let label: String
    let value: String
    let detail: String
    var id: String { label }
}

private struct UsageChartSeries: Identifiable {
    let provider: Provider
    let points: [UsageChartPoint]
    var id: Provider { provider }
}

private struct UsageChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

private struct UsageChartHoverRow: Identifiable {
    let provider: Provider
    let value: Double
    var id: Provider { provider }
}

private struct UsageChartTooltip: View {
    let date: Date
    let rows: [UsageChartHoverRow]
    let metric: UsageChartMetric

    private var total: Double {
        rows.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(spacing: 7) {
                    ProviderIconView(provider: row.provider, size: 12)
                    Text(row.provider.displayName)
                    Spacer(minLength: 14)
                    Text(valueLabel(row.value))
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }

            Divider()

            HStack {
                Text("Total")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 18)
                Text(valueLabel(total))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .usageTooltipSurface()
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func valueLabel(_ value: Double) -> String {
        switch metric {
        case .cost:
            return Decimal(value).usdString
        case .tokens:
            return Int(value.rounded()).compactTokenString
        }
    }

}

private struct ChartPointerTrackingView: NSViewRepresentable {
    let onMoved: (CGPoint) -> Void
    let onExited: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = onMoved
        view.onExited = onExited
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMoved = onMoved
        nsView.onExited = onExited
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint) -> Void)?
        var onExited: (() -> Void)?
        private var pointerTrackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            if let pointerTrackingArea {
                removeTrackingArea(pointerTrackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            pointerTrackingArea = area
            super.updateTrackingAreas()
        }

        override func mouseMoved(with event: NSEvent) {
            onMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExited?()
        }

        override func mouseDown(with event: NSEvent) {
            onMoved?(convert(event.locationInWindow, from: nil))
        }
    }
}

private struct UsageBreakdownAccumulator {
    let key: String
    let label: String
    let detail: String?
    let provider: Provider
    let tokens: Int
    let cost: Decimal
    let unknownPricingCount: Int

    func adding(tokens: Int, cost: Decimal, unknownPricingCount: Int) -> UsageBreakdownAccumulator {
        UsageBreakdownAccumulator(
            key: key,
            label: label,
            detail: detail,
            provider: provider,
            tokens: self.tokens + tokens,
            cost: self.cost + cost,
            unknownPricingCount: self.unknownPricingCount + unknownPricingCount
        )
    }
}

private struct UsageBreakdownRow: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let cost: Decimal
    let tokens: Int
    let share: Double
    let unknownPricingCount: Int
    let provider: Provider?
    let tint: Color

    var costText: String {
        cost == 0 && unknownPricingCount > 0 ? "—" : cost.usdString
    }
}

enum UsageChartMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum UsageChartAvailability: Equatable {
    case available
    case noUsage
    case costUnavailable

    static func resolve(
        metric: UsageChartMetric,
        totalTokens: Int,
        hasNonZeroPoints: Bool,
        hasUnpricedSamples: Bool
    ) -> UsageChartAvailability {
        if hasNonZeroPoints { return .available }
        if totalTokens == 0 { return .noUsage }
        return metric == .cost && hasUnpricedSamples ? .costUnavailable : .available
    }
}

private enum UsageBreakdownDimension: String, CaseIterable, Identifiable {
    case model
    case day
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var columnTitle: String { rawValue }
}

private struct UsageRangeSelector: View {
    @Binding var selection: UsageHistoryRange
    let ranges: [UsageHistoryRange]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ranges) { range in
                UsageRangeButton(
                    range: range,
                    isSelected: selection == range,
                    action: { selection = range }
                )
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.025), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
        .transaction { transaction in
            // Range changes should feel immediate. In particular, avoid the
            // sweeping matched-geometry animation used by the earlier bar.
            transaction.animation = nil
        }
    }
}

private struct UsageRangeButton: View {
    let range: UsageHistoryRange
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(compactTitle)
                .font(.callout.weight(isSelected ? .medium : .regular))
                .monospacedDigit()
                .frame(minWidth: 38)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .contentShape(Capsule())
                .background {
                    Capsule()
                        .fill(Color.primary.opacity(isSelected ? 0.085 : (isHovered ? 0.035 : 0)))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(range.accessibleTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var compactTitle: String {
        switch range {
        case .fiveHours: "5H"
        case .twentyFourHours: "24H"
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        case .ninetyDays: "90D"
        }
    }
}

private extension View {
    func usageSegmentedControl() -> some View {
        pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .tint(Color(nsColor: .secondaryLabelColor))
            .fixedSize()
    }
}

extension Decimal {
    var usdString: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return "$" + (formatter.string(from: self as NSDecimalNumber) ?? "0.00")
    }
}

private extension Double {
    var wholePercentString: String {
        String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), self * 100)
    }

    var percentString: String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), self * 100)
    }

    var oneDecimalString: String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), self)
    }
}
