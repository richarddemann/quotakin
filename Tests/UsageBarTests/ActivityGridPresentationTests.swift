import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
func fittedWeekCountShowsEveryWeekWhenWidthIsUnmeasured() {
    // A non-positive width (not yet measured, or an unbounded container) must
    // fall back to showing all weeks rather than trimming to nothing.
    #expect(ActivityGridView.fittedWeekCount(availableWidth: 0, totalWeeks: 52) == 52)
    #expect(ActivityGridView.fittedWeekCount(availableWidth: -10, totalWeeks: 52) == 52)
}

@Test
func fittedWeekCountTrimsToWholeWeeksThatFit() {
    // Weekday labels live in the page margin, so the full width belongs to
    // whole week columns: 400 / 14 = 28.57 -> 28.
    #expect(ActivityGridView.fittedWeekCount(availableWidth: 400, totalWeeks: 52) == 28)
    // Wide enough for everything: never exceed the total.
    #expect(ActivityGridView.fittedWeekCount(availableWidth: 10_000, totalWeeks: 52) == 52)
    // Always keep at least one column, even when the width is tiny.
    #expect(ActivityGridView.fittedWeekCount(availableWidth: 20, totalWeeks: 52) == 1)
    #expect(ActivityGridView.fittedWeekCount(availableWidth: 500, totalWeeks: 0) == 0)
}

@Test
func activityCellsExpandToUseTheAvailableWidth() {
    let cellSize = ActivityGridView.expandedCellSize(availableWidth: 990, weekCount: 53)
    let occupiedWidth = 53 * cellSize + 52 * 3

    #expect(abs(occupiedWidth - 990) < 0.01)
    #expect(cellSize > 11)
}

@Test
func visibleDaysKeepsTheNewestDaysAndDropsTheOldest() {
    let calendar = Calendar(identifier: .gregorian)
    let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    // One year of consecutive days, oldest first / newest last.
    let days: [DailyActivityGridDay] = (0..<365).map { offset in
        DailyActivityGridDay(
            dayStart: calendar.date(byAdding: .day, value: offset, to: start)!,
            providerTotals: []
        )
    }

    let narrow = ActivityGridView.visibleDays(from: days, calendar: calendar, availableWidth: 400)

    // Trimming happened, the newest day is retained, and the oldest is dropped.
    #expect(narrow.count < days.count)
    #expect(narrow.last == days.last)
    #expect(narrow.first != days.first)
    #expect(narrow.first!.dayStart > days.first!.dayStart)

    // A generous width keeps every day untouched.
    let wide = ActivityGridView.visibleDays(from: days, calendar: calendar, availableWidth: 10_000)
    #expect(wide == days)
}

@Test
func activityGridOnlyPaintsRealDaysThroughToday() {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14))!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let recordedDay = DailyActivityGridDay(dayStart: today, providerTotals: [])
    let futureDay = DailyActivityGridDay(dayStart: tomorrow, providerTotals: [])

    #expect(ActivityGridView.isRecordedDay(recordedDay, today: today, calendar: calendar))
    #expect(!ActivityGridView.isRecordedDay(futureDay, today: today, calendar: calendar))
    #expect(!ActivityGridView.isRecordedDay(nil, today: today, calendar: calendar))
}
