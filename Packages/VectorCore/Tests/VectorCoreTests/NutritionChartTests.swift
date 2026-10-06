import XCTest
@testable import VectorCore

final class NutritionChartTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Monday 5 October 2026, 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_190_800)
    let targets = NutritionTargets(calories: 2300, protein: 150, carbs: 250, fat: 70)

    func day(_ daysAgo: Int, hour: Double = 12) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    }

    func food(_ daysAgo: Int, calories: Double, protein: Double, hour: Double = 12) -> FoodEntry {
        FoodEntry(date: day(daysAgo, hour: hour), meal: .lunch, name: "Meal",
                  macros: Macros(calories: calories, protein: protein, carbs: 100, fat: 30), source: .quickAdd)
    }

    func testDailySeriesSumsEntriesAndLeavesUnloggedDaysAsGaps() {
        let entries = [
            food(1, calories: 1200, protein: 80, hour: 8), food(1, calories: 1000, protein: 80, hour: 19), // 2,200 kcal, 160 g
            food(3, calories: 1800, protein: 100),
            food(6, calories: 2500, protein: 150),
            food(7, calories: 3000, protein: 200)   // before the 7-day window
        ]
        let engine = NutritionChartEngine(calendar: calendar)
        let series = engine.series(entries, targets: targets, range: .week, now: now)
        XCTAssertEqual(series.bucket, .day)
        XCTAssertEqual(series.buckets.map(\.date), [day(6, hour: 0), day(3, hour: 0), day(1, hour: 0)],
                       "days 0, 2, 4 and 5 are unlogged and absent, not zero")
        XCTAssertEqual(series.calories.map(\.value), [2500, 1800, 2200])
        XCTAssertEqual(series.protein.map(\.value), [150, 100, 160])
        XCTAssertFalse(series.calories.contains { $0.value == 0 })
        XCTAssertEqual(series.interval, DateInterval(start: day(6, hour: 0), end: day(-1, hour: 0)), "the axis still spans all 7 days")
        XCTAssertEqual(series.targets, targets)
    }

    func testThreeMonthsBucketsWeeklyAveragesOfLoggedDays() {
        // Week of Mon 28 Sep: two logged days. Week of Mon 21 Sep: none. Week of Mon 14 Sep: one.
        let entries = [food(7, calories: 2000, protein: 160), food(5, calories: 2400, protein: 100),
                       food(17, calories: 1900, protein: 155)]
        let engine = NutritionChartEngine(calendar: calendar)
        let series = engine.series(entries, targets: targets, range: .threeMonths, now: now)
        XCTAssertEqual(series.bucket, .weekOfYear)
        XCTAssertEqual(series.buckets.count, 2, "the empty week is a gap")
        let (earlier, later) = (series.buckets[0], series.buckets[1])
        XCTAssertEqual(earlier.date, day(21, hour: 0))
        XCTAssertEqual(earlier.loggedDays, 1)
        XCTAssertEqual(later.date, day(7, hour: 0))
        XCTAssertEqual(later.calories, 2200, "averaged over 2 logged days, not divided by 7")
        XCTAssertEqual(later.protein, 130)
        XCTAssertEqual(later.loggedDays, 2)
        XCTAssertEqual(later.proteinDaysHit, 1)
        XCTAssertLessThanOrEqual(series.interval.start, earlier.date)
        XCTAssertEqual(series.interval.start, calendar.dateInterval(of: .weekOfYear, for: series.interval.start)?.start,
                       "the axis starts on a week boundary")
    }

    func testMonthUsesDailyBuckets() {
        let entries = [food(20, calories: 2000, protein: 150), food(40, calories: 2000, protein: 150)]
        let series = NutritionChartEngine(calendar: calendar).series(entries, targets: targets, range: .month, now: now)
        XCTAssertEqual(series.bucket, .day)
        XCTAssertEqual(series.buckets.map(\.date), [day(20, hour: 0)])
        XCTAssertEqual(NutritionChartEngine.ranges, [.week, .month, .threeMonths])
    }

    func testEmptyLogIsEmptyNotZeroes() {
        let engine = NutritionChartEngine(calendar: calendar)
        let series = engine.series([], targets: targets, range: .month, now: now)
        XCTAssertTrue(series.isEmpty)
        let adherence = engine.proteinAdherence([], targets: targets, range: .month, now: now)
        XCTAssertEqual(adherence.daysLogged, 0)
        XCTAssertNil(adherence.rate, "no logged days means no rate, not 0%")
        XCTAssertEqual(adherence.streak, 0)
    }

    func testProteinAdherenceIsDaysHitOverDaysLoggedWithStreak() {
        // Hit = at least 95% of 150 g = 142.5 g.
        let entries = [
            food(1, calories: 2200, protein: 150),
            food(2, calories: 2200, protein: 143),
            food(3, calories: 2200, protein: 120),   // miss
            food(5, calories: 2200, protein: 160),   // day 4 unlogged: not counted at all
            food(0, calories: 500, protein: 40)      // today, in progress
        ]
        let engine = NutritionChartEngine(calendar: calendar)
        let adherence = engine.proteinAdherence(entries, targets: targets, range: .week, now: now)
        XCTAssertEqual(adherence.daysLogged, 4, "today is left out until it's hit")
        XCTAssertEqual(adherence.daysHit, 3)
        XCTAssertEqual(adherence.rate ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(adherence.streak, 2, "yesterday and the day before; the miss three days ago ends it")

        let hitToday = entries + [food(0, calories: 800, protein: 120, hour: 13)]
        let updated = engine.proteinAdherence(hitToday, targets: targets, range: .week, now: now)
        XCTAssertEqual(updated.daysLogged, 5)
        XCTAssertEqual(updated.daysHit, 4)
        XCTAssertEqual(updated.streak, 3)
    }

    func testStreakBreaksOnAnUnloggedDay() {
        let entries = [food(1, calories: 2200, protein: 150), food(3, calories: 2200, protein: 150)]
        let adherence = NutritionChartEngine(calendar: calendar).proteinAdherence(entries, targets: targets, range: .week, now: now)
        XCTAssertEqual(adherence.streak, 1)
        XCTAssertEqual(adherence.daysHit, 2)
        XCTAssertEqual(adherence.daysLogged, 2)
    }
}
