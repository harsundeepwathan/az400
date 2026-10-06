import XCTest
@testable import VectorCore

final class SyncMergeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func session(_ minutes: Double) -> WorkoutSession {
        let start = t0.addingTimeInterval(minutes * 60)
        return WorkoutSession(name: "S", startedAt: start, endedAt: start.addingTimeInterval(3600), exercises: [])
    }

    func food(_ name: String, kcal: Double, id: UUID = UUID()) -> FoodEntry {
        FoodEntry(id: id, date: t0, meal: .lunch, name: name, macros: Macros(calories: kcal, protein: 0, carbs: 0, fat: 0), source: .quickAdd)
    }

    func testOfflineWorkOnBothDevicesIsKept() {
        let shared = session(0)
        let phone = AppData(sessions: [shared, session(10)], foodEntries: [food("Oats", kcal: 300)], modifiedAt: t0.addingTimeInterval(100))
        let ipad = AppData(sessions: [shared, session(20)], foodEntries: [food("Rice", kcal: 260)], modifiedAt: t0.addingTimeInterval(50))
        let merged = SyncMerge.merge(local: phone, remote: ipad)
        XCTAssertEqual(merged.sessions.count, 3)
        XCTAssertEqual(merged.foodEntries.count, 2)
        XCTAssertEqual(merged.sessions.map(\.startedAt), merged.sessions.map(\.startedAt).sorted())
    }

    func testDeletionWinsOverStaleCopy() {
        let entry = food("Pizza", kcal: 800)
        let phone = AppData(foodEntries: [], deletedIDs: [Tombstone.food(entry.id)], modifiedAt: t0)
        let ipad = AppData(foodEntries: [entry], modifiedAt: t0.addingTimeInterval(500))
        let merged = SyncMerge.merge(local: phone, remote: ipad)
        XCTAssertTrue(merged.foodEntries.isEmpty, "A newer remote document must not resurrect a deleted entry")
        XCTAssertEqual(merged.deletedIDs, [Tombstone.food(entry.id)])
    }

    func testNewerEditWins() {
        let id = UUID()
        let phone = AppData(foodEntries: [food("Chicken", kcal: 300, id: id)], modifiedAt: t0.addingTimeInterval(10))
        let ipad = AppData(foodEntries: [food("Chicken", kcal: 450, id: id)], modifiedAt: t0.addingTimeInterval(99))
        XCTAssertEqual(SyncMerge.merge(local: phone, remote: ipad).foodEntries.first?.macros.calories, 450)
        XCTAssertEqual(SyncMerge.merge(local: ipad, remote: phone).foodEntries.first?.macros.calories, 450)
    }

    func testInProgressWorkoutStaysOnDevice() {
        let workout = ActiveWorkout.empty(history: [], now: t0)
        let phone = AppData(activeWorkout: workout, modifiedAt: t0)
        let ipad = AppData(modifiedAt: t0.addingTimeInterval(100))
        XCTAssertNotNil(SyncMerge.merge(local: phone, remote: ipad).activeWorkout)
        XCTAssertNil(SyncMerge.merge(local: ipad, remote: phone).activeWorkout)
    }

    func testMergeIsIdempotentAndUnionsSets() {
        let phone = AppData(scanDates: [t0], dismissedInsightIDs: ["a"], modifiedAt: t0)
        let ipad = AppData(scanDates: [t0, t0.addingTimeInterval(5)], dismissedInsightIDs: ["b"], modifiedAt: t0)
        let once = SyncMerge.merge(local: phone, remote: ipad)
        XCTAssertEqual(once.scanDates.count, 2)
        XCTAssertEqual(once.dismissedInsightIDs, ["a", "b"])
        XCTAssertEqual(SyncMerge.merge(local: once, remote: ipad), once)
    }

    func testOldDocumentsWithoutSyncFieldsStillDecode() throws {
        let legacy = #"{"schemaVersion":1,"customTemplates":[],"sessions":[],"foodEntries":[],"savedMeals":[],"bodyWeights":[],"scanDates":[],"dismissedInsightIDs":[],"tier":"free"}"#
        let data = try JSONFileStore.decoder.decode(AppData.self, from: Data(legacy.utf8))
        XCTAssertNil(data.deletedIDs)
        XCTAssertNil(data.modifiedAt)
    }
}
