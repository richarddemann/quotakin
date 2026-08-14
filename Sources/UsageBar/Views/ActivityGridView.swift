import AppKit
import SwiftUI
import UsageCore

enum ActivityGridMetric {
    case tokens
    case cost
}

/// GitHub-style contribution grid: one cell per day, columns are weeks,
/// intensity quantized to five levels of the user's accent color.
struct ActivityGridView: View {
    let grid: DailyActivityGrid
    @Binding var selectedDay: DailyActivityGridDay?
    var tint: Color = .accentColor
    var calendar: Calendar = .current
    var metric: ActivityGridMetric = .tokens

    /// Width offered by the container, measured with a background probe.
    /// The grid trims to the newest whole weeks that fit this width.
    @State private var availableWidth: CGFloat = 0
    @State private var hoveredDay: DailyActivityGridDay?
    @State private var hoverLocation: CGPoint?
    @State private var hoverTask: Task<Void, Never>?

    private static let baseCellSize: CGFloat = 11
    private static let cellGap: CGFloat = 3

    /// Weekday labels sit in the document margin so the actual cell matrix can
    /// share the same leading and trailing guides as the surrounding sections.
    private static let gutterWidth: CGFloat = 28
    /// Horizontal distance between the left edges of adjacent week columns.
    private static var weekStride: CGFloat { baseCellSize + cellGap }

    var body: some View {
        // Trim to the newest weeks that fit, then lay out only those days —
        // GitHub keeps the freshest data visible and drops the oldest columns.
        let visibleDays = Self.visibleDays(
            from: grid.days,
            calendar: calendar,
            availableWidth: availableWidth
        )
        let layout = GridLayout(days: visibleDays, calendar: calendar)
        let cellSize = Self.expandedCellSize(availableWidth: availableWidth, weekCount: layout.weekCount)
        let weekStride = cellSize + Self.cellGap
        let gridWidth = CGFloat(layout.weekCount) * cellSize
            + CGFloat(max(0, layout.weekCount - 1)) * Self.cellGap
        let cellsHeight = 7 * cellSize + 6 * Self.cellGap
        let legendTopPadding: CGFloat = 4
        let contentHeight = 12 + (2 * Space.xxs) + cellsHeight + legendTopPadding + max(cellSize, 12)

        Color.clear
            // This flexible base owns layout. The fitted grid is an overlay so
            // its previous measured width can never become the ScrollView's
            // minimum content width during a window resize.
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    monthLabels(layout: layout, cellSize: cellSize, weekStride: weekStride)
                    ZStack(alignment: .topLeading) {
                        cells(layout: layout, cellSize: cellSize, weekStride: weekStride)
                        weekdayLabels(cellSize: cellSize)
                            .offset(x: -Self.gutterWidth)
                            .allowsHitTesting(false)
                    }
                    legend(cellSize: cellSize)
                        .padding(.top, legendTopPadding)
                }
                .frame(width: gridWidth, alignment: .leading)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: GridWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(GridWidthKey.self) { width in
                availableWidth = width
            }
            .onDisappear {
                hoverTask?.cancel()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(metric == .cost ? "Daily cost over the past year" : "Daily token activity over the past year")
    }

    /// Number of whole week columns that fit within `availableWidth`, clamped
    /// to `1...totalWeeks`. A non-positive width (not yet measured, or an
    /// unbounded container) shows every week.
    static func fittedWeekCount(availableWidth: CGFloat, totalWeeks: Int) -> Int {
        guard totalWeeks > 0 else { return 0 }
        guard availableWidth > 0 else { return totalWeeks }
        let fit = Int((availableWidth / weekStride).rounded(.down))
        return max(1, min(totalWeeks, fit))
    }

    /// Once whole weeks have been selected, distribute any remaining width
    /// evenly across their square cells instead of leaving a dead column on
    /// the trailing edge of a wide window.
    static func expandedCellSize(availableWidth: CGFloat, weekCount: Int) -> CGFloat {
        guard availableWidth > 0, weekCount > 0 else { return baseCellSize }
        let usable = availableWidth - CGFloat(max(0, weekCount - 1)) * cellGap
        return max(baseCellSize, usable / CGFloat(weekCount))
    }

    /// The newest slice of `days` whose week columns fit `availableWidth`.
    /// Oldest weeks are dropped on a week boundary so the retained slice starts
    /// on the locale's first weekday and re-lays out cleanly.
    static func visibleDays(
        from days: [DailyActivityGridDay],
        calendar: Calendar,
        availableWidth: CGFloat
    ) -> [DailyActivityGridDay] {
        let layout = GridLayout(days: days, calendar: calendar)
        let weeks = fittedWeekCount(availableWidth: availableWidth, totalWeeks: layout.weekCount)
        guard weeks < layout.weekCount else { return days }
        let firstVisibleWeek = layout.weekCount - weeks
        let startIndex = firstVisibleWeek * 7 - layout.leadingEmptyCells
        guard startIndex > 0, startIndex < days.count else { return days }
        return Array(days[startIndex...])
    }

    private func monthLabels(layout: GridLayout, cellSize: CGFloat, weekStride: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(
                    width: CGFloat(layout.weekCount) * cellSize
                        + CGFloat(max(0, layout.weekCount - 1)) * Self.cellGap,
                    height: 12
                )
            ForEach(layout.monthMarks, id: \.weekIndex) { mark in
                Text(mark.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(mark.weekIndex) * weekStride)
            }
        }
    }

    private func weekdayLabels(cellSize: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: Self.cellGap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row == 0 ? shortWeekday(1) : (row == 2 ? shortWeekday(3) : (row == 4 ? shortWeekday(5) : " ")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: cellSize, alignment: .trailing)
            }
        }
    }

    private func cells(layout: GridLayout, cellSize: CGFloat, weekStride: CGFloat) -> some View {
        let width = CGFloat(layout.weekCount) * cellSize
            + CGFloat(max(0, layout.weekCount - 1)) * Self.cellGap
        let height = 7 * cellSize + 6 * Self.cellGap

        return ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Self.cellGap) {
                ForEach(0..<layout.weekCount, id: \.self) { week in
                    VStack(spacing: Self.cellGap) {
                        ForEach(0..<7, id: \.self) { row in
                            cell(for: layout.day(week: week, row: row), size: cellSize)
                        }
                    }
                }
            }

            ActivityGridPointerTrackingView(
                onMoved: { location in
                    scheduleHover(
                        day: day(at: location, layout: layout, cellSize: cellSize, weekStride: weekStride),
                        location: location
                    )
                },
                onExited: {
                    hoverTask?.cancel()
                    hoverLocation = nil
                    hoveredDay = nil
                },
                onClicked: { location in
                    hoverTask?.cancel()
                    selectedDay = nil
                    hoverLocation = location
                    hoveredDay = day(at: location, layout: layout, cellSize: cellSize, weekStride: weekStride)
                }
            )
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Keep the detail surface out of the ZStack's size calculation. When
        // it lived inside the stack, its changing intrinsic height caused the
        // fixed-size grid to be re-centered and visibly jump on lower rows.
        .overlay(alignment: .topLeading) {
            if let day = hoveredDay, let anchor = hoverLocation {
                let x = tooltipX(anchorX: anchor.x, gridWidth: width)
                DayDetailTooltip(day: day, metric: metric)
                    .fixedSize()
                    // Follow the pointer in both axes. Alignment guides let the
                    // tooltip's intrinsic height place its bottom edge eight
                    // points above the cursor without affecting grid layout.
                    .alignmentGuide(.leading) { _ in -x }
                    .alignmentGuide(.top) { dimensions in
                        dimensions.height + 8 - anchor.y
                    }
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
    }

    private func scheduleHover(day: DailyActivityGridDay?, location: CGPoint) {
        if hoveredDay?.dayStart == day?.dayStart, day != nil {
            hoverLocation = location
            return
        }

        hoverTask?.cancel()
        hoveredDay = nil
        hoverLocation = nil
        guard let day else { return }

        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(325))
            guard !Task.isCancelled else { return }
            hoveredDay = day
            hoverLocation = location
        }
    }

    @ViewBuilder
    private func cell(for day: DailyActivityGridDay?, size: CGFloat) -> some View {
        if let day {
            if Self.isRecordedDay(day, today: Date(), calendar: calendar) {
                let level = intensityLevel(for: day)
                let isSelected = selectedDay?.dayStart == day.dayStart
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill(for: level))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 1.5)
                                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                        }
                    }
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                // Keep the rest of the calendar legible without presenting
                // future dates as recorded zero-usage days.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.035))
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        } else {
            // Complete the first and last week columns so the calendar reads
            // as one rectangular matrix rather than ending in partial rows.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(0.035))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    static func isRecordedDay(
        _ day: DailyActivityGridDay?,
        today: Date,
        calendar: Calendar
    ) -> Bool {
        guard let day else { return false }
        return day.dayStart <= calendar.startOfDay(for: today)
    }

    private func day(
        at location: CGPoint,
        layout: GridLayout,
        cellSize: CGFloat,
        weekStride: CGFloat
    ) -> DailyActivityGridDay? {
        guard location.x >= 0, location.y >= 0 else { return nil }
        let week = Int(location.x / weekStride)
        let row = Int(location.y / weekStride)
        guard week < layout.weekCount, row < 7 else { return nil }
        guard location.x.truncatingRemainder(dividingBy: weekStride) <= cellSize,
              location.y.truncatingRemainder(dividingBy: weekStride) <= cellSize else { return nil }
        guard let day = layout.day(week: week, row: row) else { return nil }
        return day.dayStart <= calendar.startOfDay(for: Date()) ? day : nil
    }

    private func tooltipX(anchorX: CGFloat, gridWidth: CGFloat) -> CGFloat {
        let tooltipWidth: CGFloat = 210
        return min(max(anchorX - tooltipWidth / 2, 0), max(0, gridWidth - tooltipWidth))
    }

    private func legend(cellSize: CGFloat) -> some View {
        HStack(spacing: Space.xs) {
            Spacer()
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.xxs) {
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fill(for: level))
                        .frame(width: cellSize, height: cellSize)
                }
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private func intensityLevel(for day: DailyActivityGridDay) -> Int {
        let value: Double
        let maximum: Double
        switch metric {
        case .tokens:
            value = Double(day.totalTokens)
            maximum = Double(grid.maxTotalTokens)
        case .cost:
            value = NSDecimalNumber(decimal: day.estimatedCost).doubleValue
            maximum = grid.days
                .map { NSDecimalNumber(decimal: $0.estimatedCost).doubleValue }
                .max() ?? 0
        }
        guard value > 0, maximum > 0 else {
            return 0
        }
        let fraction = value / maximum
        switch fraction {
        case ..<0.25: return 1
        case ..<0.5: return 2
        case ..<0.75: return 3
        default: return 4
        }
    }

    private func fill(for level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.08)
        case 1: tint.opacity(0.28)
        case 2: tint.opacity(0.50)
        case 3: tint.opacity(0.72)
        default: tint
        }
    }

    private func shortWeekday(_ offsetFromFirstWeekday: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = (calendar.firstWeekday - 1 + offsetFromFirstWeekday) % 7
        return String(symbols[index].prefix(2))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}

/// Reports the container width offered to the grid so it can fit the visible
/// week columns without overflowing.
private struct GridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Per-day breakdown shown when a grid cell is clicked.
private struct DayDetailTooltip: View {
    let day: DailyActivityGridDay
    let metric: ActivityGridMetric

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Self.dayFormatter.string(from: day.dayStart))
                .font(.headline)
            if metric == .cost, day.totalTokens > 0, day.unknownPricingSampleCount > 0, day.estimatedCost == 0 {
                Text("Cost unavailable")
                    .foregroundStyle(.secondary)
            } else if displayedValue(for: day) == 0 {
                Text("No activity")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(day.providerTotals.filter { providerEntryIsVisible($0) }, id: \.provider) { entry in
                    HStack(spacing: Space.xs) {
                        ProviderIconView(provider: entry.provider, size: 14)
                        Text(entry.provider.displayName)
                        Spacer(minLength: Space.l)
                        Text(formattedValue(for: entry))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Divider()
                HStack {
                    Text("Total")
                    Spacer(minLength: Space.l)
                    Text(formattedValue(for: day))
                        .monospacedDigit()
                }
                .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .frame(width: 210)
        .usageTooltipSurface()
    }

    private func displayedValue(for entry: DailyProviderTokenTotal) -> Decimal {
        metric == .cost ? entry.estimatedCost : Decimal(entry.totalTokens)
    }

    private func displayedValue(for day: DailyActivityGridDay) -> Decimal {
        metric == .cost ? day.estimatedCost : Decimal(day.totalTokens)
    }

    private func providerEntryIsVisible(_ entry: DailyProviderTokenTotal) -> Bool {
        displayedValue(for: entry) > 0
            || (metric == .cost && entry.totalTokens > 0 && entry.unknownPricingSampleCount > 0)
    }

    private func formattedValue(for entry: DailyProviderTokenTotal) -> String {
        if metric == .cost, entry.estimatedCost == 0, entry.unknownPricingSampleCount > 0 {
            return "—"
        }
        return metric == .cost ? entry.estimatedCost.usdString : entry.totalTokens.compactTokenString
    }

    private func formattedValue(for day: DailyActivityGridDay) -> String {
        metric == .cost ? day.estimatedCost.usdString : day.totalTokens.compactTokenString
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()
}

/// Maps a flat run of days onto week columns starting at the locale's first
/// weekday, with month labels where a month begins.
private struct GridLayout {
    struct MonthMark {
        let weekIndex: Int
        let label: String
    }

    private let days: [DailyActivityGridDay]
    let leadingEmptyCells: Int
    let weekCount: Int
    let monthMarks: [MonthMark]

    init(days: [DailyActivityGridDay], calendar: Calendar) {
        self.days = days
        guard let first = days.first else {
            leadingEmptyCells = 0
            weekCount = 0
            monthMarks = []
            return
        }
        let weekday = calendar.component(.weekday, from: first.dayStart)
        leadingEmptyCells = (weekday - calendar.firstWeekday + 7) % 7
        weekCount = Int(ceil(Double(days.count + leadingEmptyCells) / 7))

        var marks: [MonthMark] = []
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        var lastMonth = -1
        for (index, day) in days.enumerated() {
            let month = calendar.component(.month, from: day.dayStart)
            if month != lastMonth {
                let week = (index + leadingEmptyCells) / 7
                // Skip a label that would collide with the previous one.
                if marks.last.map({ week - $0.weekIndex >= 3 }) ?? true {
                    marks.append(MonthMark(weekIndex: week, label: formatter.string(from: day.dayStart)))
                }
                lastMonth = month
            }
        }
        monthMarks = marks
    }

    func day(week: Int, row: Int) -> DailyActivityGridDay? {
        let index = week * 7 + row - leadingEmptyCells
        guard index >= 0, index < days.count else {
            return nil
        }
        return days[index]
    }

}

/// One AppKit tracking surface for the entire grid. This avoids installing a
/// button, hover recognizer, and popover host for every day of the year.
private struct ActivityGridPointerTrackingView: NSViewRepresentable {
    let onMoved: (CGPoint) -> Void
    let onExited: () -> Void
    let onClicked: (CGPoint) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = onMoved
        view.onExited = onExited
        view.onClicked = onClicked
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMoved = onMoved
        view.onExited = onExited
        view.onClicked = onClicked
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint) -> Void)?
        var onExited: (() -> Void)?
        var onClicked: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self
            ))
            super.updateTrackingAreas()
        }

        override func mouseMoved(with event: NSEvent) { onMoved?(convert(event.locationInWindow, from: nil)) }
        override func mouseDragged(with event: NSEvent) { onMoved?(convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { onMoved?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onExited?() }
        override func mouseDown(with event: NSEvent) { onClicked?(convert(event.locationInWindow, from: nil)) }
    }
}
