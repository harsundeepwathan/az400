import XCTest
@testable import VectorCore

final class ClosedLoopTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// A Monday, 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_190_800)

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    func profile(goal: TrainingGoal, calories: Double) -> UserProfile {
        var profile = PlanGenerator().generate(from: SampleData.answers(), now: now).profile
        profile.goal = goal
        profile.targets = NutritionTargets(calories: calories, protein: 160, carbs: 250, fat: 70)
        return profile
    }

    func day(_ daysAgo: Int, hour: Double = 12) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    }

    func food(days: ClosedRange<Int>, calories: Double, protein: Double = 150) -> [FoodEntry] {
        days.map { FoodEntry(date: day($0), meal: .lunch, name: "Day", macros: Macros(calories: calories, protein: protein, carbs: 200, fat: 70), source: .quickAdd) }
    }

    /// Daily weigh-ins over the last two weeks changing by `weeklyChange` kg per week.
    func weights(start: Double, weeklyChange: Double, days: ClosedRange<Int> = 1...14) -> [BodyWeightEntry] {
        days.map { BodyWeightEntry(date: day($0, hour: 7), kilograms: start + weeklyChange * Double(14 - $0) / 7) }
    }

    // MARK: Adaptive nutrition

    func testStableWeightOnFatLossGoalReducesCaloriesWithCap() throws {
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        let result = engine.evaluate(profile: profile(goal: .loseFat, calories: 2500),
                                     bodyWeights: weights(start: 80, weeklyChange: 0),
                                     foodEntries: food(days: 1...14, calories: 2500), now: now)
        guard case let .ready(checkIn, reason, evidence) = result else { return XCTFail("Expected a recommendation") }
        XCTAssertEqual(checkIn.estimatedExpenditure, 2500, accuracy: 1)
        XCTAssertEqual(checkIn.recommendedCalories, 2250, "Ideal is ~2,060 but changes are capped at 250 kcal")
        XCTAssertTrue(reason.contains("Reduce your target by 250 kcal to 2,250 kcal"), reason)
        XCTAssertTrue(reason.contains("capped"), reason)
        XCTAssertTrue(evidence.contains { $0.label == "Estimated expenditure" })
    }

    func testLosingWeightOnMaintenanceRaisesCalories() throws {
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        let result = engine.evaluate(profile: profile(goal: .maintain, calories: 2200),
                                     bodyWeights: weights(start: 80, weeklyChange: -0.35),
                                     foodEntries: food(days: 1...14, calories: 2200), now: now)
        guard case let .ready(checkIn, _, _) = result else { return XCTFail("Expected a recommendation") }
        XCTAssertLessThan(checkIn.weeklyChangeKg, -0.15)
        XCTAssertGreaterThan(checkIn.estimatedExpenditure, 2300, "Losing weight at 2,200 kcal means expenditure is higher")
        XCTAssertGreaterThan(checkIn.recommendedCalories, 2200)
        XCTAssertLessThanOrEqual(checkIn.recommendedCalories, 2450)
    }

    func testOnTargetMeansNoChange() throws {
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        let result = engine.evaluate(profile: profile(goal: .maintain, calories: 2400),
                                     bodyWeights: weights(start: 75, weeklyChange: 0),
                                     foodEntries: food(days: 1...14, calories: 2400), now: now)
        guard case let .ready(checkIn, reason, _) = result else { return XCTFail("Expected a recommendation") }
        XCTAssertEqual(checkIn.recommendedCalories, 2400)
        XCTAssertTrue(reason.hasSuffix("No change needed."), reason)
    }

    func testInsufficientDataSaysWhatIsMissing() {
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        let result = engine.evaluate(profile: profile(goal: .loseFat, calories: 2500),
                                     bodyWeights: weights(start: 80, weeklyChange: 0, days: 1...3),
                                     foodEntries: food(days: 1...5, calories: 2500) + food(days: 6...8, calories: 400), now: now)
        guard case let .needsMoreData(missing, _) = result else { return XCTFail("Expected insufficient data") }
        XCTAssertEqual(missing, "Your first check-in needs 5 more fully logged days and 3 more weigh-ins.",
                       "Partial days under 800 kcal don't count")
    }

    func testApplyingCheckInKeepsProteinAndFat() {
        let checkIn = NutritionCheckIn(date: now, windowDays: 14, trendStartKg: 80, trendEndKg: 80, weeklyChangeKg: 0,
                                       averageIntake: 2500, loggedDays: 14, estimatedExpenditure: 2500,
                                       previousCalories: 2500, recommendedCalories: 2250)
        let updated = AdaptiveNutritionEngine.targets(applying: checkIn, to: NutritionTargets(calories: 2500, protein: 160, carbs: 302, fat: 70))
        XCTAssertEqual(updated.calories, 2250)
        XCTAssertEqual(updated.protein, 160)
        XCTAssertEqual(updated.fat, 70)
        XCTAssertEqual(updated.carbs, 245)
    }

    func testCheckInIsWeekly() {
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        XCTAssertTrue(engine.isDue(lastCheckIn: nil, now: now))
        XCTAssertFalse(engine.isDue(lastCheckIn: now.addingTimeInterval(-3 * 86_400), now: now))
        XCTAssertTrue(engine.isDue(lastCheckIn: now.addingTimeInterval(-7 * 86_400), now: now))
    }

    // MARK: Daily brief

    func testDailyBriefUsesOnlyRealData() {
        let empty = CoachContext(sessions: [], foodEntries: [], bodyWeights: [], program: nil,
                                 profile: profile(goal: .buildMuscle, calories: 2600), now: now)
        let brief = DailyBriefEngine(calendar: calendar).brief(context: empty, recommendations: [])
        XCTAssertEqual(brief.headline, "Rest day.")
        XCTAssertTrue(brief.lines.isEmpty, "No data means no invented advice")
    }

    func testDailyBriefFromSampleData() {
        let data = SampleData.appData(now: now, calendar: calendar)
        let context = CoachContext(sessions: data.sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: data.profile!, now: now)
        let recs = data.program!.nextWorkout!.exercises.compactMap { item -> ProgressionRecommendation? in
            guard let exercise = ExerciseCatalog.standard[item.exerciseID] else { return nil }
            let engine = ProgressionEngine()
            return engine.recommend(for: exercise, repRange: item.repRange, sets: item.sets,
                                    history: engine.history(for: item.exerciseID, in: data.sessions))
        }
        let brief = DailyBriefEngine(calendar: calendar).brief(context: context, recommendations: recs)
        XCTAssertEqual(brief.headline, "Lower A today.")
        let training = brief.lines.first { $0.kind == .training }
        XCTAssertNotNil(training)
        XCTAssertTrue(training!.text.hasPrefix("Start back squat at"), training!.text)
        XCTAssertTrue(brief.lines.allSatisfy { !$0.evidence.isEmpty }, "Every line carries evidence")
        XCTAssertTrue(brief.lines.contains { $0.kind == .bodyWeight })
    }

    // MARK: Goals

    func testGoalsDriveProteinAndRate() {
        XCTAssertEqual(TrainingGoal.selectable.count, 5)
        XCTAssertFalse(TrainingGoal.selectable.contains(.improveFitness))
        XCTAssertEqual(TrainingGoal.recomposition.nutritionGoal, .maintain)
        XCTAssertLessThan(TrainingGoal.loseFat.targetWeeklyRate, 0)

        var answers = SampleData.answers()
        answers.goal = .recomposition
        answers.nutritionGoal = .maintain
        answers.weightKg = 80
        answers.dietaryPreferences = [.vegetarian]
        let plan = PlanGenerator().generate(from: answers, now: now)
        XCTAssertEqual(plan.targets.protein, 160, "Recomposition uses 2.0 g/kg")
        XCTAssertEqual(plan.profile.dietaryPreferences, [.vegetarian])
    }

    func testProteinSuggestionsRespectDietaryPreferences() {
        XCTAssertEqual(DietaryPreference.proteinExamples(for: []), "Greek yogurt or a shake")
        XCTAssertEqual(DietaryPreference.proteinExamples(for: [.vegan]), "tofu, tempeh or a plant protein shake")
        XCTAssertEqual(DietaryPreference.proteinExamples(for: [.vegetarian, .dairyFree]), "eggs, tofu or a plant protein shake")
        XCTAssertEqual(DietaryPreference.proteinExamples(for: [.pescatarian]), "Greek yogurt, fish or a shake")
        XCTAssertEqual(DietaryPreference.proteinExamples(for: [.dairyFree]), "chicken, eggs or a plant protein shake")

        var profile = self.profile(goal: .buildMuscle, calories: 2500)
        profile.dietaryPreferences = [.vegan]
        let entries = food(days: 1...5, calories: 2000, protein: 90)
        let context = CoachContext(sessions: [], foodEntries: entries, bodyWeights: [], program: nil, profile: profile, now: now)
        let insight = InsightEngine(calendar: calendar).insights(context).first { $0.id == "protein-shortfall" }
        XCTAssertTrue(insight?.suggestion?.contains("tofu") ?? false, insight?.suggestion ?? "no insight")
    }

    func testOldProfilesAndAnswersStillDecode() throws {
        let json = """
        {"name":"A","goal":"improveFitness","experience":"beginner","daysPerWeek":3,"equipment":"fullGym","nutritionGoal":"maintain",
         "sex":"male","age":30,"heightCm":180,"weightKg":80,"targetWeightKg":80,"unit":"kilograms"}
        """
        let answers = try JSONDecoder().decode(OnboardingAnswers.self, from: Data(json.utf8))
        XCTAssertEqual(answers.goal, .improveFitness)
        XCTAssertEqual(answers.dietaryPreferences, [])
    }
}
