import XCTest
@testable import VectorCore

final class WorkoutImportTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    var importer: WorkoutImporter { WorkoutImporter(catalog: .standard, timeZone: utc) }

    let hevy = #"""
    "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
    "Push A","30 Jan 2024, 07:31","30 Jan 2024, 08:40","","Bench Press (Barbell)","","felt strong, ""easy""","0","warmup","40","10","","",""
    "Push A","30 Jan 2024, 07:31","30 Jan 2024, 08:40","","Bench Press (Barbell)","","felt strong, ""easy""","1","normal","80","8","","","8.5"
    "Push A","30 Jan 2024, 07:31","30 Jan 2024, 08:40","","Bench Press (Barbell)","","","2","failure","80","6","","",""
    "Push A","30 Jan 2024, 07:31","30 Jan 2024, 08:40","","Wobbly Ninja Curl (Dumbbell)","","","0","normal","12","12","","",""
    "Legs","1 Feb 2024, 18:00","1 Feb 2024, 19:05","","Squat (Barbell)","","","0","normal","100","5","","",""
    "Legs","1 Feb 2024, 18:00","1 Feb 2024, 19:05","","Plank","","","0","normal","","0","","60",""
    """#

    func testHevyExportBecomesSessionsWithSetTypesNotesAndRPE() throws {
        let result = try importer.importCSV(hevy)
        XCTAssertEqual(result.source, .hevy)
        XCTAssertEqual(result.sessions.map(\.name), ["Legs", "Push A"], "newest first")
        let push = result.sessions[1]
        XCTAssertEqual(push.duration, 69 * 60)
        XCTAssertEqual(push.exercises.count, 2)
        let bench = push.exercises[0]
        XCTAssertEqual(bench.sets.map(\.kind), [.warmup, .working, .failure])
        XCTAssertEqual(bench.sets.map(\.weight), [40, 80, 80])
        XCTAssertEqual(bench.sets[1].rpe, 8.5)
        XCTAssertEqual(bench.note, #"felt strong, "easy""#)
        XCTAssertTrue(bench.sets.allSatisfy(\.isCompleted))
        XCTAssertFalse(ExerciseCatalog.standard[bench.exerciseID]?.isCustom ?? true, "bench matched to the catalog")
        XCTAssertEqual(result.skippedRows, 1, "the timed plank with 0 reps is skipped")
    }

    func testUnknownExercisesBecomeCustomWithGuessedMuscleAndEquipment() throws {
        let result = try importer.importCSV(hevy)
        let custom = try XCTUnwrap(result.newExercises.first { $0.name == "Wobbly Ninja Curl (Dumbbell)" })
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(custom.equipment, .dumbbell)
        XCTAssertEqual(custom.primaryMuscles, [.biceps])
        XCTAssertEqual(result.sessions[1].exercises[1].exerciseID, custom.id)
    }

    func testStrongExportWithPoundsSemicolonsAndRestRows() throws {
        let strong = #"""
        Date;Workout Name;Duration;Exercise Name;Set Order;Weight;Reps;Distance;Seconds;Notes;Workout Notes;RPE
        2024-03-04 06:15:00;Upper;1h 5m;Bench Press (Barbell);W;95;10;0;0;;;
        2024-03-04 06:15:00;Upper;1h 5m;Bench Press (Barbell);1;185;5;0;0;;;9
        2024-03-04 06:15:00;Upper;1h 5m;Bench Press (Barbell);Rest Timer;0;0;0;120;;;
        2024-03-04 06:15:00;Upper;1h 5m;Bent Over Row (Barbell);1;135;8;0;0;;;
        """#
        let result = try importer.importCSV(strong, strongUnit: .pounds)
        XCTAssertEqual(result.source, .strong)
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.duration, 65 * 60)
        XCTAssertEqual(session.exercises.count, 2)
        XCTAssertEqual(session.exercises[0].sets.map(\.kind), [.warmup, .working])
        XCTAssertEqual(session.exercises[0].sets[1].weight, WeightUnit.pounds.toKilograms(185), accuracy: 0.001)
        XCTAssertEqual(session.exercises[0].sets[1].rpe, 9)
    }

    func testUnknownFilesAreRejected() {
        XCTAssertThrowsError(try importer.importCSV("name,age\nSam,30\n")) { error in
            XCTAssertEqual(error as? WorkoutImporter.ImportError, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try importer.importCSV(hevy.components(separatedBy: "\n")[0])) { error in
            XCTAssertEqual(error as? WorkoutImporter.ImportError, .noWorkouts)
        }
    }

    func testExportRoundTripsThroughTheImporter() throws {
        let imported = try importer.importCSV(hevy)
        let catalog = ExerciseCatalog.standard.adding(imported.newExercises)
        let csv = WorkoutExporter(catalog: catalog, timeZone: utc).csv(imported.sessions)
        let again = try WorkoutImporter(catalog: catalog, timeZone: utc).importCSV(csv)
        XCTAssertEqual(again.sessions.map(\.name), imported.sessions.map(\.name))
        XCTAssertEqual(again.sessions.flatMap { $0.exercises.flatMap { $0.sets.map(\.weight) } },
                       imported.sessions.flatMap { $0.exercises.flatMap { $0.sets.map(\.weight) } })
        XCTAssertTrue(again.newExercises.isEmpty, "every name matches the catalog it was exported from")
    }

    func testMatcherHandlesEquipmentSuffixesAndPlurals() {
        let matcher = ExerciseMatcher(catalog: .standard)
        XCTAssertNotNil(matcher.match("Squat (Barbell)"))
        XCTAssertNil(matcher.match("Underwater Basket Weaving"))
        XCTAssertEqual(ExerciseMatcher.guessEquipment("Lat Pulldown - Cable"), .cable)
        XCTAssertEqual(ExerciseMatcher.guessMuscle("Seated Calf Raises"), .calves)
    }

    func testPlateCalculator() {
        let kg = PlateCalculator.kilograms
        XCTAssertEqual(kg.load(for: 100), .init(perSide: [25, 15], total: 100, isApproximate: false))
        XCTAssertEqual(kg.load(for: 82.5), .init(perSide: [25, 5, 1.25], total: 82.5, isApproximate: false))
        XCTAssertEqual(kg.load(for: 20), .init(perSide: [], total: 20, isApproximate: false))
        XCTAssertEqual(kg.load(for: 21), .init(perSide: [], total: 20, isApproximate: true))
        XCTAssertEqual(PlateCalculator.pounds.load(for: 225).perSide, [45, 45])
    }
}
