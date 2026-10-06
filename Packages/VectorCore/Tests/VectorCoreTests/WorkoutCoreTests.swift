import XCTest
@testable import VectorCore

final class WorkoutCoreTests: XCTestCase {
    let catalog = ExerciseCatalog.standard
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    var template: WorkoutTemplate {
        WorkoutTemplate(name: "Upper", exercises: [
            ExercisePrescription(exerciseID: "bench-press", sets: 2, repRange: .fixed(8)),
            ExercisePrescription(exerciseID: "barbell-row", sets: 2, repRange: .fixed(8)),
            ExercisePrescription(exerciseID: "lateral-raise", sets: 2, repRange: RepRange(12, 15))
        ])
    }

    // MARK: Rest

    func testRestPreferencesOverrideTemplateRest() {
        let workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], restPreferences: ["bench-press": 150], now: now)
        XCTAssertEqual(workout.exercises[0].restSeconds, 150)
        XCTAssertEqual(workout.exercises[1].restSeconds, catalog["barbell-row"]!.defaultRestSeconds)
    }

    func testWarmupSetsDoNotStartRest() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.setKind(.warmup, at: SetPosition(exercise: 0, set: 0))
        XCTAssertEqual(workout.complete(SetPosition(exercise: 0, set: 0), now: now)?.restSeconds, 0)
        XCTAssertGreaterThan(workout.complete(SetPosition(exercise: 0, set: 1), now: now)?.restSeconds ?? 0, 0)
    }

    // MARK: Supersets

    func testSupersetAlternatesWithoutRestUntilRoundEnds() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.toggleSuperset(withNext: 0)
        XCTAssertNotNil(workout.exercises[0].supersetGroup)
        XCTAssertEqual(workout.exercises[0].supersetGroup, workout.exercises[1].supersetGroup)

        let first = workout.complete(SetPosition(exercise: 0, set: 0), now: now)
        XCTAssertEqual(first?.restSeconds, 0, "Go straight to the paired exercise")
        XCTAssertEqual(first?.nextFocus, SetPosition(exercise: 1, set: 0))

        let second = workout.complete(SetPosition(exercise: 1, set: 0), now: now)
        XCTAssertEqual(second?.restSeconds, workout.exercises[1].restSeconds, "Rest after the round")
        XCTAssertEqual(second?.nextFocus, SetPosition(exercise: 0, set: 1))

        workout.complete(SetPosition(exercise: 0, set: 1), now: now)
        let last = workout.complete(SetPosition(exercise: 1, set: 1), now: now)
        XCTAssertEqual(last?.nextFocus, SetPosition(exercise: 2, set: 0), "Superset done, move on")
    }

    func testTogglingSupersetTwiceUnlinksAndRemovalCleansUp() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.toggleSuperset(withNext: 0)
        workout.toggleSuperset(withNext: 0)
        XCTAssertNil(workout.exercises[0].supersetGroup)
        XCTAssertNil(workout.exercises[1].supersetGroup)

        workout.toggleSuperset(withNext: 1)
        workout.removeExercise(at: 2)
        XCTAssertNil(workout.exercises[1].supersetGroup, "A single exercise isn't a superset")
    }

    // MARK: RPE, notes, kinds

    func testRPEIsClampedToHalfSteps() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        let position = SetPosition(exercise: 0, set: 0)
        workout.setRPE(8.3, at: position)
        XCTAssertEqual(workout.exercises[0].sets[0].rpe, 8.5)
        XCTAssertEqual(workout.exercises[0].sets[0].rir, 2)
        workout.setRPE(12, at: position)
        XCTAssertEqual(workout.exercises[0].sets[0].rpe, 10)
        workout.setRPE(nil, at: position)
        XCTAssertNil(workout.exercises[0].sets[0].rpe)

        workout.setNote("Elbows tucked", forExercise: 0)
        workout.setKind(.drop, at: SetPosition(exercise: 0, set: 1))
        workout.complete(position, now: now)
        workout.complete(SetPosition(exercise: 0, set: 1), now: now)
        let saved = workout.finished(at: now)
        XCTAssertEqual(saved.exercises[0].note, "Elbows tucked")
        XCTAssertEqual(saved.exercises[0].sets[1].kind, .drop)
        XCTAssertEqual(saved.exercises[0].completedWorkingSets.count, 2, "Drop sets count toward volume")
    }

    func testMaximalRPEAtTopOfRangeRepeatsLoadOnce() {
        let squat = catalog["back-squat"]!
        func perf(_ daysAgo: Int, rpe: Double?) -> ExercisePerformance {
            let sets = [8, 8, 8].map { SetLog(weight: 100, reps: $0, isCompleted: true, rpe: rpe) }
            return ExercisePerformance(date: now.addingTimeInterval(Double(-daysAgo) * 86_400), sessionID: UUID(),
                                       log: ExerciseLog(exerciseID: "back-squat", sets: sets, repRange: .fixed(8), restSeconds: 180))
        }
        let engine = ProgressionEngine()
        let grind = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [perf(3, rpe: 10)])
        XCTAssertEqual(grind.action, .repeatLoad)
        XCTAssertEqual(grind.weight, 100)
        XCTAssertTrue(grind.reason.contains("RPE 10"), grind.reason)
        XCTAssertTrue(grind.evidence.contains(Evidence("Hardest set", "RPE 10")))

        let owned = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [perf(3, rpe: 8)])
        XCTAssertEqual(owned.action, .increaseLoad)
        XCTAssertEqual(owned.reason, "You completed 100 kg × 8 across all 3 sets at RPE 8.")

        let twice = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [perf(3, rpe: 10), perf(10, rpe: 10)])
        XCTAssertEqual(twice.action, .increaseLoad, "Hit twice in a row: progress even at RPE 10")
    }

    // MARK: Library

    func testCustomExercisesJoinCatalog() {
        let custom = Exercise.custom(name: "  Landmine press ", primaryMuscle: .shoulders, equipment: .barbell, isCompound: true)
        XCTAssertTrue(custom.isCustom)
        XCTAssertFalse(custom.isCurated)
        XCTAssertEqual(custom.name, "Landmine press")
        XCTAssertEqual(custom.pattern, .verticalPush)
        let extended = catalog.adding([custom])
        XCTAssertEqual(extended[custom.id]?.name, "Landmine press")
        XCTAssertEqual(extended.all.count, catalog.all.count + 1)
        XCTAssertEqual(extended.search("landmine p").first?.id, custom.id)
    }

    func testRecentExercisesNewestFirstWithoutDuplicates() {
        func session(_ daysAgo: Int, _ ids: [String]) -> WorkoutSession {
            let start = now.addingTimeInterval(Double(-daysAgo) * 86_400)
            return WorkoutSession(name: "S", startedAt: start, endedAt: start.addingTimeInterval(3600),
                                  exercises: ids.map { ExerciseLog(exerciseID: $0, sets: [SetLog(weight: 50, reps: 8, isCompleted: true)],
                                                                   repRange: .fixed(8), restSeconds: 90) })
        }
        let ids = AnalyticsEngine().recentExerciseIDs([session(5, ["back-squat", "leg-curl"]), session(1, ["bench-press", "back-squat"])])
        XCTAssertEqual(ids, ["bench-press", "back-squat", "leg-curl"])
    }

    func testAppDataWithoutNewFieldsDecodes() throws {
        let data = AppData()
        var json = try JSONSerialization.jsonObject(with: JSONFileStore.encoder.encode(data)) as! [String: Any]
        for key in ["customExercises", "favoriteExerciseIDs", "favoriteFoods", "restPreferences", "checkIns"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONFileStore.decoder.decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.restPreferences)
        XCTAssertNil(decoded.checkIns)
    }
}
