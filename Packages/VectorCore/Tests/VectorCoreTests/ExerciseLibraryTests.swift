import XCTest
@testable import VectorCore

final class ExerciseLibraryTests: XCTestCase {
    let catalog = ExerciseCatalog.standard

    func testBundledLibraryLoads() {
        XCTAssertGreaterThan(catalog.all.count, 500)
        let ids = catalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Exercise ids must be unique")
        XCTAssertEqual(Set(catalog.all.map { $0.name.lowercased() }).count, catalog.all.count, "No duplicate names")
    }

    func testCuratedExercisesKeepIdsAndGainImages() {
        let squat = catalog["back-squat"]
        XCTAssertNotNil(squat)
        XCTAssertEqual(squat?.images.count, 2)
        XCTAssertEqual(squat?.imageURLs.first?.absoluteString,
                       "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Squat/0.jpg")
        let withImages = catalog.all.filter { $0.isCurated && !$0.images.isEmpty }.count
        XCTAssertGreaterThanOrEqual(withImages, 45)
    }

    func testImportedExercisesAreWellFormed() {
        for exercise in catalog.all where !exercise.isCurated {
            XCTAssertFalse(exercise.primaryMuscles.isEmpty, exercise.name)
            XCTAssertFalse(exercise.instructions.isEmpty, exercise.name)
            XCTAssertLessThanOrEqual(exercise.images.count, 2, exercise.name)
            XCTAssertFalse(exercise.primaryMuscles.contains(where: exercise.secondaryMuscles.contains), exercise.name)
        }
    }

    func testNearlyAllExercisesHaveDemonstrations() {
        let withImages = catalog.all.filter { !$0.images.isEmpty }.count
        XCTAssertGreaterThan(Double(withImages) / Double(catalog.all.count), 0.95)
    }

    func testSearchRanksCuratedAndPrefixMatches() {
        XCTAssertEqual(catalog.search("bench").first?.id, "bench-press")
        XCTAssertEqual(catalog.search("romanian").first?.id, "romanian-deadlift")
        XCTAssertTrue(catalog.search("zottman").contains { $0.name.contains("Zottman") })
    }

    func testSubstitutionsDrawOnTheWholeLibrary() {
        let alternatives = ExerciseSubstitutionEngine(catalog: catalog)
            .alternatives(for: catalog["bench-press"]!, availableEquipment: [.dumbbell], limit: 8)
        XCTAssertEqual(alternatives.count, 8)
        XCTAssertTrue(alternatives.allSatisfy { $0.exercise.equipment == .dumbbell })
    }
}
