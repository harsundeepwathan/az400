import XCTest
@testable import VectorCore

final class PlanNutritionServiceTests: XCTestCase {
    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    func testFourDayPlanIsUpperLower() {
        let plan = PlanGenerator().generate(from: OnboardingAnswers(daysPerWeek: 4))
        XCTAssertEqual(plan.program.name, "Upper / Lower — 4 Days")
        XCTAssertEqual(plan.program.workouts.map(\.name), ["Lower A", "Upper A", "Lower B", "Upper B"])
        XCTAssertEqual(plan.program.workouts[0].exercises.count, 6)
        XCTAssertEqual(plan.program.workouts[1].exercises.count, 7)
        XCTAssertEqual(plan.program.workouts[0].exercises[0].exerciseID, "back-squat")
    }

    func testEquipmentConstraintsAreRespected() {
        for access in EquipmentAccess.allCases {
            for days in 2...6 {
                let plan = PlanGenerator().generate(from: OnboardingAnswers(daysPerWeek: days, equipment: access))
                for workout in plan.program.workouts {
                    XCTAssertFalse(workout.exercises.isEmpty, "\(access) \(days)d \(workout.name) is empty")
                    let ids = workout.exercises.map(\.exerciseID)
                    XCTAssertEqual(Set(ids).count, ids.count, "No duplicate exercises within a workout")
                    for id in ids {
                        XCTAssertTrue(access.available.contains(ExerciseCatalog.standard[id]!.equipment), "\(id) not allowed for \(access)")
                    }
                }
            }
        }
    }

    func testStrengthGoalUsesLowReps() {
        let plan = PlanGenerator().generate(from: OnboardingAnswers(goal: .getStronger))
        XCTAssertEqual(plan.program.workouts[0].exercises[0].repRange, .fixed(5))
    }

    func testNutritionTargetsAreCoherent() {
        let targets = NutritionEngine.targets(sex: .male, weightKg: 80, heightCm: 180, age: 30, trainingDays: 4, goal: .lose)
        XCTAssertEqual(targets.protein, 160)
        let fromMacros = targets.protein * 4 + targets.carbs * 4 + targets.fat * 9
        XCTAssertEqual(fromMacros, targets.calories, accuracy: 40)
        XCTAssertEqual(targets.calories.truncatingRemainder(dividingBy: 50), 0)
    }

    func testSubstitutionsPreferPatternAndEquipment() {
        let catalog = ExerciseCatalog.standard
        let alternatives = ExerciseSubstitutionEngine().alternatives(
            for: catalog["back-squat"]!, availableEquipment: EquipmentAccess.dumbbells.available, avoiding: ["goblet-squat"])
        XCTAssertFalse(alternatives.isEmpty)
        XCTAssertFalse(alternatives.contains { $0.id == "goblet-squat" })
        XCTAssertTrue(alternatives.allSatisfy { EquipmentAccess.dumbbells.available.contains($0.exercise.equipment) })
        XCTAssertEqual(alternatives.first?.exercise.pattern, .squat)
    }

    func testFreeScanQuota() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let policy = EntitlementPolicy(calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_791_190_800)
        XCTAssertEqual(policy.scansRemaining(tier: .free, scanDates: [now, now], now: now), 1)
        XCTAssertNil(policy.scansRemaining(tier: .pro, scanDates: [now], now: now))
        XCTAssertFalse(policy.canScan(tier: .free, scanDates: [now, now, now], now: now))
        XCTAssertTrue(policy.shouldShowUpgradeMoment(tier: .free, finishedWorkouts: 5, progressionOpportunities: 4,
                                                     isWorkoutActive: false, lastShown: nil, now: now))
        XCTAssertFalse(policy.shouldShowUpgradeMoment(tier: .free, finishedWorkouts: 5, progressionOpportunities: 4,
                                                      isWorkoutActive: true, lastShown: nil, now: now),
                       "Never pitch during a workout")
    }

    func testFoodSearchRanksPrefixMatches() {
        let results = FoodDatabase().search("chicken")
        XCTAssertEqual(results.first?.id, "chicken-breast")
        XCTAssertEqual(FoodDatabase().food(barcode: "5060469985054")?.id, "whey")
    }

    func testRemoteRecognizerDecodesAndMatches() throws {
        let json = """
        {"items":[{"name":"Grilled chicken","grams":180,"calories":297,"protein":55.8,"carbs":0,"fat":6.5,"confidence":0.9,"matchId":"chicken-breast","alternatives":["chicken thigh"]},
                  {"name":"Mystery sauce","grams":40,"calories":60,"protein":0,"carbs":8,"fat":3,"confidence":0.4}]}
        """
        let analysis = try RemoteMealRecognizer.decode(Data(json.utf8), database: FoodDatabase())
        XCTAssertEqual(analysis.items.count, 2)
        XCTAssertEqual(analysis.items[0].food.id, "chicken-breast")
        XCTAssertEqual(analysis.items[0].alternatives.first?.id, "chicken-thigh")
        XCTAssertEqual(analysis.items[1].macros.calories, 60, accuracy: 0.01)
        XCTAssertTrue(analysis.items[1].isLowConfidence)
        XCTAssertThrowsError(try RemoteMealRecognizer.decode(Data(#"{"items":[]}"#.utf8), database: FoodDatabase()))
    }

    func testDemoRecognizerMatchesSpec() async throws {
        let analysis = try await DemoMealRecognizer(latency: .zero).analyze(imageData: Data([1]))
        XCTAssertEqual(analysis.items.map { Int($0.macros.calories.rounded()) }, [297, 260, 70])
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONFileStore(url: url)
        XCTAssertNil(try store.load())
        let data = SampleData.appData(now: Date(timeIntervalSince1970: 1_791_190_800))
        try store.save(data)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.sessions.count, data.sessions.count)
        XCTAssertEqual(loaded.profile, data.profile)
        XCTAssertEqual(loaded.foodEntries.count, data.foodEntries.count)
    }

    func testFormatting() {
        XCTAssertEqual(Format.weight(82.5), "82.5 kg")
        XCTAssertEqual(Format.weight(80), "80 kg")
        XCTAssertEqual(Format.volume(8420), "8,420 kg")
        XCTAssertEqual(Format.signedPercent(0.084), "+8.4%")
        XCTAssertEqual(Format.signedPercent(-0.24), "\u{2212}24%")
        XCTAssertEqual(Format.clock(92), "1:32")
        XCTAssertEqual(Format.clock(18 * 60 + 42, alwaysShowHours: true), "00:18:42")
        XCTAssertEqual(Format.duration(58 * 60), "58 min")
        XCTAssertEqual(Format.compact(74_250), "74k")
    }
}
