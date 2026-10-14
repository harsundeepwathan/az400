import XCTest
@testable import VectorCore

final class WarmupPlannerTests: XCTestCase {
    func testRampForAHeavySquat() {
        let sets = WarmupPlanner().warmups(forWorkingWeight: 100)
        XCTAssertEqual(sets.map(\.weight), [20, 50, 70, 85])
        XCTAssertEqual(sets.map(\.reps), [10, 8, 5, 3])
        XCTAssertTrue(sets.allSatisfy { $0.kind == .warmup && !$0.isCompleted })
    }

    func testLoadsRoundDownToThePlateStep() {
        let sets = WarmupPlanner().warmups(forWorkingWeight: 82.5)
        XCTAssertEqual(sets.map(\.weight), [20, 40, 57.5, 70])
    }

    func testLightLiftSkipsTheBarSetAndDuplicates() {
        // 30 kg: no bar-only set (below 2× bar); 50% = 15 kg is under the bar.
        let sets = WarmupPlanner().warmups(forWorkingWeight: 30)
        XCTAssertEqual(sets.map(\.weight), [20, 25])
    }

    func testNothingAtOrBelowTheBar() {
        XCTAssertTrue(WarmupPlanner().warmups(forWorkingWeight: 20).isEmpty)
        XCTAssertTrue(WarmupPlanner().warmups(forWorkingWeight: 0).isEmpty)
    }

    func testAddWarmupsInsertsOnceBeforeTheWorkingSets() {
        let exercise = ExerciseCatalog.standard.all[0]
        var workout = ActiveWorkout(session: WorkoutSession(name: "Lower A", startedAt: Date(), exercises: [
            ExerciseLog(exerciseID: exercise.id, sets: [SetLog(weight: 100, reps: 5), SetLog(weight: 100, reps: 5)],
                        repRange: RepRange(5, 8), restSeconds: 120)
        ]), focus: SetPosition(exercise: 0, set: 0), previousBests: [:])
        workout.addWarmups(toExercise: 0)
        XCTAssertEqual(workout.session.exercises[0].sets.map(\.kind), [.warmup, .warmup, .warmup, .warmup, .working, .working])
        workout.addWarmups(toExercise: 0)
        XCTAssertEqual(workout.session.exercises[0].sets.count, 6, "a second tap adds nothing")
        XCTAssertEqual(workout.focus, SetPosition(exercise: 0, set: 0), "focus moves to the first warm-up")
    }

    func testWeeklySeriesSumsEachMetricPerWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18))!
        let exercise = ExerciseCatalog.standard.all[0]
        func session(_ day: Int) -> WorkoutSession {
            let start = calendar.date(byAdding: .day, value: day, to: monday)!
            return WorkoutSession(name: "W", startedAt: start, endedAt: start.addingTimeInterval(45 * 60), exercises: [
                ExerciseLog(exerciseID: exercise.id,
                            sets: [SetLog(weight: 100, reps: 5, isCompleted: true), SetLog(weight: 100, reps: 5, isCompleted: true)],
                            repRange: RepRange(5, 8), restSeconds: 120)
            ])
        }
        let sessions = [session(0), session(2)]
        let engine = AnalyticsEngine(catalog: .standard, calendar: calendar)
        let now = calendar.date(byAdding: .day, value: 3, to: monday)!
        func lastWeek(_ metric: WeeklyMetric) -> Double? {
            engine.weeklySeries(sessions, metric: metric, range: .month, now: now).last?.value
        }
        XCTAssertEqual(lastWeek(.workouts), 2)
        XCTAssertEqual(lastWeek(.duration), 90)
        XCTAssertEqual(lastWeek(.volume), 2000)
        XCTAssertEqual(lastWeek(.sets), 4)
    }
}
