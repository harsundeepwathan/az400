import XCTest
@testable import VectorCore

final class DailyHighlightTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// A Thursday, 18:00 UTC (the Monday used elsewhere in the tests, plus three days and nine hours).
    let now = Date(timeIntervalSince1970: 1_791_190_800 + 3 * 86_400 + 9 * 3600)

    var engine: DailyHighlightEngine { DailyHighlightEngine(calendar: calendar) }

    /// Midday, `daysAgo` days before `now`'s day.
    func day(_ daysAgo: Int, hour: Double = 12) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    }

    func session(_ daysAgo: Int, _ lifts: [(id: String, weight: Double, reps: [Int])]) -> WorkoutSession {
        let start = day(daysAgo)
        let logs = lifts.map { lift in
            ExerciseLog(exerciseID: lift.id,
                        sets: lift.reps.map { SetLog(weight: lift.weight, reps: $0, isCompleted: true, completedAt: start) },
                        repRange: RepRange(6, 10), restSeconds: 120)
        }
        return WorkoutSession(name: "Session", startedAt: start, endedAt: start.addingTimeInterval(3600), exercises: logs)
    }

    /// An old session so the history is long enough for comparisons.
    var history: WorkoutSession { session(40, [("plank", 0, [1])]) }

    func testNothingLoggedMeansNoHighlight() {
        XCTAssertTrue(engine.highlights(sessions: [], foodEntries: [], proteinTarget: 150, now: now).isEmpty)
    }

    func testNewUsersGetAMilestoneInsteadOfComparisons() {
        let sessions = [session(5, [("bench-press", 60, [8, 8, 8])]), session(2, [("bench-press", 60, [8, 8, 8])])]
        let result = engine.highlights(sessions: sessions, foodEntries: [], proteinTarget: 150, now: now)
        XCTAssertEqual(result.map(\.fact), [.milestone(workouts: 2)])
    }

    func testRepsCompareWithTheSamePointLastWeek() {
        // This week: Monday and Tuesday, 24 bench reps each (48).
        // Last week by Thursday 18:00: Monday 24 + Tuesday 16 (40). Last Friday's 24 is after that point.
        let sessions = [history,
                        session(3, [("bench-press", 80, [8, 8, 8])]), session(2, [("bench-press", 80, [8, 8, 8])]),
                        session(10, [("bench-press", 80, [8, 8, 8])]), session(9, [("bench-press", 80, [8, 8])]),
                        session(6, [("bench-press", 80, [8, 8, 8])])]
        let result = engine.highlights(sessions: sessions, foodEntries: [], proteinTarget: 150, now: now)
        XCTAssertTrue(result.contains { $0.fact == .liftReps(exerciseID: "bench-press", thisWeek: 48, lastWeek: 40) })
    }

    func testDipsAreNeverShown() {
        let sessions = [history,
                        session(3, [("back-squat", 80, [8, 8])]),
                        session(10, [("back-squat", 80, [8, 8, 8])])]
        let result = engine.highlights(sessions: sessions, foodEntries: [], proteinTarget: 150, now: now)
        XCTAssertFalse(result.contains { if case .liftReps = $0.fact { true } else { false } })
        XCTAssertFalse(result.contains { if case .weeklyVolume = $0.fact { true } else { false } })
    }

    func testLiftGainComparesWithThreeWeeksAgo() {
        let sessions = [history,
                        session(24, [("back-squat", 77.5, [8, 8, 8])]),
                        session(7, [("back-squat", 82.5, [8, 8, 8])])]
        let result = engine.highlights(sessions: sessions, foodEntries: [], proteinTarget: 150, now: now)
        XCTAssertTrue(result.contains {
            $0.fact == .liftGain(exerciseID: "back-squat", fromKilograms: 77.5, toKilograms: 82.5, weeks: 3)
        })
    }

    func testProteinDaysNeedFourOfTheLastSeven() {
        let food = (1...5).map { FoodEntry(date: day($0), meal: .lunch, name: "Meal",
                                           macros: Macros(calories: 2000, protein: 140, carbs: 200, fat: 60), source: .quickAdd) }
        let result = engine.highlights(sessions: [history], foodEntries: food, proteinTarget: 150, now: now)
        XCTAssertEqual(result.map(\.fact), [.proteinDays(onTarget: 5, of: 7)])
        let fewer = engine.highlights(sessions: [history], foodEntries: Array(food.prefix(3)), proteinTarget: 150, now: now)
        XCTAssertTrue(fewer.isEmpty, "Three days isn't a pattern worth calling out")
    }

    func testLeadRotatesDayToDayAndCapsAtThree() {
        let food = (1...6).map { FoodEntry(date: day($0), meal: .lunch, name: "Meal",
                                           macros: Macros(calories: 2000, protein: 150, carbs: 200, fat: 60), source: .quickAdd) }
        let sessions = [history,
                        session(24, [("back-squat", 77.5, [8, 8, 8])]),
                        session(3, [("bench-press", 80, [8, 8, 8]), ("back-squat", 82.5, [8, 8, 8])]),
                        session(10, [("bench-press", 80, [8, 8]), ("back-squat", 80, [8, 8, 8])])]
        let today = engine.highlights(sessions: sessions, foodEntries: food, proteinTarget: 150, now: now)
        let tomorrow = engine.highlights(sessions: sessions, foodEntries: food, proteinTarget: 150,
                                         now: now.addingTimeInterval(86_400))
        XCTAssertLessThanOrEqual(today.count, DailyHighlightEngine.maximum)
        XCTAssertGreaterThan(today.count, 1)
        XCTAssertNotEqual(today.first?.id, tomorrow.first?.id)
    }
}
