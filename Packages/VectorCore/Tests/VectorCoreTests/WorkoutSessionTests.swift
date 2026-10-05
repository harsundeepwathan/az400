import XCTest
@testable import VectorCore

final class WorkoutSessionTests: XCTestCase {
    let catalog = ExerciseCatalog.standard
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    var template: WorkoutTemplate {
        WorkoutTemplate(name: "Lower A", exercises: [
            ExercisePrescription(exerciseID: "back-squat", sets: 3, repRange: .fixed(8)),
            ExercisePrescription(exerciseID: "leg-curl", sets: 2, repRange: RepRange(10, 12), restSeconds: 75)
        ])
    }

    func history(weight: Double) -> [WorkoutSession] {
        [WorkoutSession(name: "Lower A", startedAt: now.addingTimeInterval(-7 * 86_400), endedAt: now.addingTimeInterval(-7 * 86_400 + 3600),
                        exercises: [ExerciseLog(exerciseID: "back-squat",
                                                sets: (0..<3).map { _ in SetLog(weight: weight, reps: 8, isCompleted: true) },
                                                repRange: .fixed(8), restSeconds: 180)])]
    }

    func testStartPrefillsRecommendation() {
        let workout = ActiveWorkout.start(template: template, catalog: catalog, history: history(weight: 80), now: now)
        XCTAssertEqual(workout.session.exercises.count, 2)
        XCTAssertEqual(workout.session.exercises[0].sets.map(\.weight), [82.5, 82.5, 82.5])
        XCTAssertEqual(workout.session.exercises[0].sets.map(\.reps), [8, 8, 8])
        XCTAssertEqual(workout.session.exercises[1].restSeconds, 75)
        XCTAssertEqual(workout.focus, SetPosition(exercise: 0, set: 0))
    }

    func testCompletingSetAdvancesFocusAndReportsRest() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: history(weight: 80), now: now)
        let result = workout.complete(SetPosition(exercise: 0, set: 0), now: now)
        XCTAssertEqual(result?.restSeconds, 180)
        XCTAssertEqual(result?.nextFocus, SetPosition(exercise: 0, set: 1))
        XCTAssertEqual(result?.isPersonalRecord, true, "82.5 kg beats the previous best of 80 kg")
        XCTAssertNil(workout.complete(SetPosition(exercise: 0, set: 0), now: now), "Completing twice is a no-op")

        workout.complete(SetPosition(exercise: 0, set: 1), now: now)
        let last = workout.complete(SetPosition(exercise: 0, set: 2), now: now)
        XCTAssertEqual(last?.finishedExercise, true)
        XCTAssertEqual(last?.isPersonalRecord, false, "Same weight & reps as the set that just set the record")
        XCTAssertEqual(last?.nextFocus, SetPosition(exercise: 1, set: 0))
    }

    func testFocusWrapsToSkippedSets() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.complete(SetPosition(exercise: 1, set: 0), now: now)
        let result = workout.complete(SetPosition(exercise: 1, set: 1), now: now)
        XCTAssertEqual(result?.nextFocus, SetPosition(exercise: 0, set: 0))
    }

    func testEditingWeightPropagatesToUntouchedSets() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: history(weight: 80), now: now)
        workout.complete(SetPosition(exercise: 0, set: 0), now: now)
        workout.setWeight(85, at: SetPosition(exercise: 0, set: 1))
        XCTAssertEqual(workout.session.exercises[0].sets.map(\.weight), [82.5, 85, 85])
    }

    func testFinishedDropsIncompleteWork() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.setWeight(60, at: SetPosition(exercise: 0, set: 0))
        workout.complete(SetPosition(exercise: 0, set: 0), now: now)
        let session = workout.finished(at: now.addingTimeInterval(1800))
        XCTAssertEqual(session.exercises.count, 1)
        XCTAssertEqual(session.exercises[0].sets.count, 1)
        XCTAssertEqual(session.volume, 60 * 8)
        XCTAssertEqual(session.duration, 1800)
    }

    func testRemoveAndReplace() {
        var workout = ActiveWorkout.start(template: template, catalog: catalog, history: [], now: now)
        workout.addSet(toExercise: 0)
        XCTAssertEqual(workout.session.exercises[0].sets.count, 4)
        workout.removeSet(SetPosition(exercise: 0, set: 3))
        XCTAssertEqual(workout.session.exercises[0].sets.count, 3)

        workout.replaceExercise(at: 0, with: catalog["hack-squat"]!, recommendation: nil)
        XCTAssertEqual(workout.session.exercises[0].exerciseID, "hack-squat")
        XCTAssertEqual(workout.session.exercises[0].sets.count, 3)

        workout.focus = SetPosition(exercise: 1, set: 0)
        workout.removeExercise(at: 0)
        XCTAssertEqual(workout.focus, SetPosition(exercise: 0, set: 0))
    }

    func testRestTimer() {
        var timer = RestTimer(startedAt: now, duration: 90)
        XCTAssertEqual(timer.remaining(at: now.addingTimeInterval(30)), 60)
        timer.adjust(by: 15, now: now.addingTimeInterval(30))
        XCTAssertEqual(timer.remaining(at: now.addingTimeInterval(30)), 75)
        timer.adjust(by: -200, now: now.addingTimeInterval(30))
        XCTAssertTrue(timer.isFinished(at: now.addingTimeInterval(30)))
        XCTAssertEqual(timer.progress(at: now.addingTimeInterval(1000)), 1)
    }
}
