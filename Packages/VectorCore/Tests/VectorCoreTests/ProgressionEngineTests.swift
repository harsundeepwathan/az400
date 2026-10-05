import XCTest
@testable import VectorCore

final class ProgressionEngineTests: XCTestCase {
    let engine = ProgressionEngine()
    let squat = ExerciseCatalog.standard["back-squat"]!
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    func performance(daysAgo: Int, weight: Double, reps: [Int], exercise: String = "back-squat") -> ExercisePerformance {
        let log = ExerciseLog(exerciseID: exercise,
                              sets: reps.map { SetLog(weight: weight, reps: $0, isCompleted: true) },
                              repRange: .fixed(8), restSeconds: 180)
        return ExercisePerformance(date: start.addingTimeInterval(Double(-daysAgo) * 86_400), sessionID: UUID(), log: log)
    }

    func testNoHistoryAsksForBaseline() {
        let rec = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [])
        XCTAssertEqual(rec.action, .establishBaseline)
        XCTAssertNil(rec.weight)
        XCTAssertEqual(rec.reps, 8)
    }

    func testAllSetsAtTopAddsLoad() {
        let history = [performance(daysAgo: 7, weight: 80, reps: [8, 8, 8])]
        let rec = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: history)
        XCTAssertEqual(rec.action, .increaseLoad)
        XCTAssertEqual(rec.weight, 82.5)
        XCTAssertEqual(rec.reps, 8)
        XCTAssertEqual(rec.reason, "You completed 80 kg × 8 across all 3 sets.")
        XCTAssertTrue(rec.evidence.contains(Evidence("Last session", "80 × 8, 8, 8")))
    }

    func testTwiceInARowIsMentioned() {
        let history = [performance(daysAgo: 7, weight: 80, reps: [8, 8, 8]), performance(daysAgo: 14, weight: 80, reps: [8, 8, 8])]
        let rec = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: history)
        XCTAssertEqual(rec.reason, "You completed 80 kg × 8 across all 3 sets twice in a row.")
    }

    func testDoubleProgressionResetsToBottomOfRange() {
        let history = [performance(daysAgo: 3, weight: 60, reps: [12, 12, 12])]
        let rec = engine.recommend(for: squat, repRange: RepRange(8, 12), sets: 3, history: history)
        XCTAssertEqual(rec.weight, 62.5)
        XCTAssertEqual(rec.reps, 8)
    }

    func testInsideRangeAddsReps() {
        let history = [performance(daysAgo: 3, weight: 60, reps: [10, 9, 9])]
        let rec = engine.recommend(for: squat, repRange: RepRange(8, 12), sets: 3, history: history)
        XCTAssertEqual(rec.action, .increaseReps)
        XCTAssertEqual(rec.weight, 60)
        XCTAssertEqual(rec.reps, 10)
    }

    func testSingleMissRepeatsLoad() {
        let history = [performance(daysAgo: 3, weight: 80, reps: [8, 7, 6])]
        let rec = engine.recommend(for: squat, repRange: RepRange(7, 8), sets: 3, history: history)
        XCTAssertEqual(rec.action, .repeatLoad)
        XCTAssertEqual(rec.weight, 80)
    }

    func testRepeatedMissReducesLoad() {
        let history = [performance(daysAgo: 3, weight: 80, reps: [8, 6, 5]), performance(daysAgo: 10, weight: 80, reps: [7, 6, 6])]
        let rec = engine.recommend(for: squat, repRange: RepRange(7, 8), sets: 3, history: history)
        XCTAssertEqual(rec.action, .reduceLoad)
        XCTAssertEqual(rec.weight, 77.5)
    }

    func testThreeSessionDeclineSuggestsDeload() {
        let history = [
            performance(daysAgo: 2, weight: 80, reps: [5, 5, 5]),
            performance(daysAgo: 9, weight: 80, reps: [6, 6, 6]),
            performance(daysAgo: 16, weight: 80, reps: [8, 8, 8])
        ]
        let rec = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: history)
        XCTAssertEqual(rec.action, .deload)
        XCTAssertEqual(rec.weight, 72.5)
    }

    func testBodyweightWithoutIncrementAddsReps() {
        let plank = ExerciseCatalog.standard["hanging-leg-raise"]!
        let log = ExerciseLog(exerciseID: plank.id, sets: [12, 12, 12].map { SetLog(weight: 0, reps: $0, isCompleted: true) },
                              repRange: RepRange(10, 12), restSeconds: 60)
        let rec = engine.recommend(for: plank, repRange: RepRange(10, 12), sets: 3,
                                   history: [ExercisePerformance(date: start, sessionID: UUID(), log: log)])
        XCTAssertEqual(rec.action, .increaseReps)
        XCTAssertEqual(rec.reps, 13)
    }

    func testOneRepMax() {
        XCTAssertEqual(OneRepMax.estimate(weight: 100, reps: 1), 100)
        XCTAssertEqual(OneRepMax.estimate(weight: 100, reps: 5), 100 * (1 + 5.0 / 30), accuracy: 0.001)
        XCTAssertEqual(OneRepMax.estimate(weight: 100, reps: 20), OneRepMax.estimate(weight: 100, reps: 12))
        XCTAssertEqual(OneRepMax.estimate(weight: 0, reps: 5), 0)
    }
}
