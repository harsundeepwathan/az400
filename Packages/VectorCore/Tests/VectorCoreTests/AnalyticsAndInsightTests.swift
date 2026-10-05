import XCTest
@testable import VectorCore

final class AnalyticsAndInsightTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    // Monday 5 October 2026, 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_190_800)

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    func session(_ daysAgo: Int, _ exercise: String, _ weight: Double, _ reps: [Int]) -> WorkoutSession {
        let start = now.addingTimeInterval(Double(-daysAgo) * 86_400)
        return WorkoutSession(name: "S", startedAt: start, endedAt: start.addingTimeInterval(3600), exercises: [
            ExerciseLog(exerciseID: exercise, sets: reps.map { SetLog(weight: weight, reps: $0, isCompleted: true) },
                        repRange: .fixed(8), restSeconds: 120)
        ])
    }

    func testPersonalRecordSweep() {
        let engine = AnalyticsEngine(calendar: calendar)
        let sessions = [
            session(20, "back-squat", 95, [5, 5]),   // baseline
            session(13, "back-squat", 100, [5, 4]),  // +5 kg
            session(6, "back-squat", 100, [6]),      // +1 rep at 100
            session(1, "back-squat", 90, [10])       // lighter, not a PR
        ]
        let prs = engine.personalRecords(sessions)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[1].kind, .weight)
        XCTAssertEqual(prs[1].improvementLabel(), "+5 kg")
        XCTAssertEqual(prs[0].kind, .reps)
        XCTAssertEqual(prs[0].improvementLabel(), "+1 rep")

        let latest = engine.personalRecords(for: sessions[2], history: sessions)
        XCTAssertEqual(latest.map(\.kind), [.reps])
    }

    func testSummaryComparesToPreviousWindow() {
        let engine = AnalyticsEngine(calendar: calendar)
        let sessions = [session(3, "bench-press", 80, [10, 10]), session(10, "bench-press", 80, [8, 8, 9])]
        let summary = engine.summary(sessions, range: .week, now: now)
        XCTAssertEqual(summary.workouts, 1)
        XCTAssertEqual(summary.volume, 1600)
        XCTAssertEqual(summary.volumeChange!, (1600.0 - 2000) / 2000, accuracy: 0.0001)
    }

    func testVolumeSeriesFillsEmptyBuckets() {
        let engine = AnalyticsEngine(calendar: calendar)
        let points = engine.volumeSeries([session(2, "bench-press", 50, [10])], range: .week, now: now)
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points.map(\.value).reduce(0, +), 500)
    }

    func testWeeklySetsCountSecondaryAsHalf() {
        let engine = AnalyticsEngine(calendar: calendar)
        let volumes = engine.weeklySetsPerMuscle([session(1, "bench-press", 60, [8, 8, 8, 8])], now: now)
        XCTAssertEqual(volumes.first { $0.muscle == .chest }?.sets, 4)
        XCTAssertEqual(volumes.first { $0.muscle == .triceps }?.sets, 2)
        XCTAssertEqual(volumes.first { $0.muscle == .chest }?.status, .low)
    }

    func testSampleDataProducesExplainableInsights() {
        let data = SampleData.appData(now: now, calendar: calendar)
        XCTAssertGreaterThan(data.sessions.count, 25)
        XCTAssertTrue(data.sessions.allSatisfy(\.isFinished))
        XCTAssertEqual(data.program?.nextWorkout?.name, "Lower A", "Rotation should land on Lower A for the demo")

        let context = CoachContext(sessions: data.sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: data.profile!, now: now)
        let insights = InsightEngine(calendar: calendar).insights(context)
        XCTAssertFalse(insights.isEmpty)
        XCTAssertTrue(insights.allSatisfy { !$0.evidence.isEmpty }, "Every insight must carry evidence")
        XCTAssertTrue(insights.contains { $0.id.hasPrefix("protein-streak") })

        let today = NutritionEngine(calendar: calendar).daily(data.foodEntries, on: now, targets: data.profile!.targets)
        XCTAssertGreaterThan(today.consumed.calories, 1000)
        XCTAssertLessThan(today.consumed.calories, 2300)
    }

    func testProteinShortfallInsight() {
        var profile = PlanGenerator().generate(from: SampleData.answers(), now: now).profile
        profile.targets = NutritionTargets(calories: 2300, protein: 150, carbs: 240, fat: 70)
        let entries = (1...5).map { offset in
            FoodEntry(date: now.addingTimeInterval(Double(-offset) * 86_400), meal: .lunch, name: "Meal",
                      macros: Macros(calories: 2000, protein: 104, carbs: 200, fat: 60), source: .quickAdd)
        }
        let context = CoachContext(sessions: [], foodEntries: entries, bodyWeights: [], program: nil, profile: profile, now: now)
        let insight = InsightEngine(calendar: calendar).insights(context).first { $0.id == "protein-shortfall" }
        XCTAssertEqual(insight?.message, "You've averaged only 104g protein against your 150g target this week.")
    }
}
