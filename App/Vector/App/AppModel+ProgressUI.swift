import Foundation
import VectorCore

/// Small read helpers and one intent for the Nutrition and Progress screens.
extension AppModel {
    /// Puts a deleted food entry back (swipe-to-delete undo). The copy gets a
    /// new id, because the original id now has a sync tombstone and would be
    /// removed again on the next merge. Not tracked as a new log.
    func restoreFoodEntry(_ entry: FoodEntry) {
        var copy = entry
        copy.id = UUID()
        mutate { $0.foodEntries.append(copy) }
    }

    /// The `count` complete days before today, oldest first, with whether
    /// each was on the calorie target. Same rule as the weekly check-in
    /// (`CoachMetrics`): a day under 800 kcal counts as not fully logged,
    /// and on target means within ±10% of the calorie target.
    func calorieTargetDays(count: Int = 7) -> [DayTargetStrip.Day] {
        guard let targets = nutritionTargets, targets.calories > 0 else { return [] }
        let today = calendar.startOfDay(for: now())
        return (1...max(count, 1)).reversed().compactMap { offset -> DayTargetStrip.Day? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let calories = nutrition(on: day).consumed.calories
            let status: DayTargetStrip.Day.Status
            if calories < CoachMetrics.completeDayCalories {
                status = .notLogged
            } else if abs(calories - targets.calories) <= targets.calories * CoachMetrics.calorieTolerance {
                status = .onTarget
            } else {
                status = .offTarget
            }
            return DayTargetStrip.Day(date: day, status: status)
        }
    }

    /// Volume summed into calendar weeks, for the Strength field. The 1M
    /// range is bucketed by day in `AnalyticsEngine`; the field shows weeks so
    /// each bar is a training week.
    func weeklyVolume(range: TimeRange) -> [ChartPoint] {
        let points = analytics.volumeSeries(sessions, range: range, now: now())
        guard range.bucket == .day, range != .week else { return points }
        var totals: [Date: Double] = [:]
        var order: [Date] = []
        for point in points {
            let week = calendar.dateInterval(of: .weekOfYear, for: point.date)?.start ?? point.date
            if totals[week] == nil { order.append(week) }
            totals[week, default: 0] += point.value
        }
        return order.map { ChartPoint(date: $0, value: totals[$0] ?? 0) }
    }
}
