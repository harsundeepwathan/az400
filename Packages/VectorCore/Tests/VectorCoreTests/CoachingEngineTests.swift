import XCTest
@testable import VectorCore

final class CoachingEngineTests: XCTestCase {
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

    func food(days: ClosedRange<Int>, calories: Double, protein: Double = 160) -> [FoodEntry] {
        days.map { FoodEntry(date: day($0), meal: .lunch, name: "Day", macros: Macros(calories: calories, protein: protein, carbs: 200, fat: 70), source: .quickAdd) }
    }

    /// Daily weigh-ins changing linearly by `weeklyChange` kg per week, ending at `end` kg yesterday.
    func weights(end: Double, weeklyChange: Double, days: ClosedRange<Int> = 1...21) -> [BodyWeightEntry] {
        days.map { BodyWeightEntry(date: day($0, hour: 7), kilograms: end - weeklyChange * Double($0 - 1) / 7) }
    }

    func review(_ profile: UserProfile, weights: [BodyWeightEntry], food: [FoodEntry], decisions: [CoachDecision] = [],
                at date: Date? = nil) -> WeeklyReview {
        WeeklyCheckInEngine(calendar: calendar).review(profile: profile, program: nil, sessions: [], foodEntries: food,
                                                       bodyWeights: weights, decisions: decisions, now: date ?? now)
    }

    // MARK: Goal bands and metrics

    func testGoalBandsMatchTheBrief() {
        let bulk = TrainingGoal.buildMuscle.band.kilograms(at: 80)
        XCTAssertEqual(bulk.lowerBound, 0.12, accuracy: 0.001)
        XCTAssertEqual(bulk.upperBound, 0.32, accuracy: 0.001)
        XCTAssertTrue(TrainingGoal.loseFat.band.contains(-0.005))
        XCTAssertFalse(TrainingGoal.loseFat.band.contains(-0.012), "Losing over 1%/week is outside the band")
        XCTAssertTrue(TrainingGoal.maintain.band.contains(0))
    }

    func testAdherenceCountsUnloggedDaysAgainstAndExcludesToday() {
        let targets = NutritionTargets(calories: 2500, protein: 160, carbs: 250, fat: 70)
        let entries = food(days: 1...4, calories: 2500) + food(days: 5...5, calories: 3200) + food(days: 0...0, calories: 2500)
        let adherence = CoachMetrics(calendar: calendar).nutritionAdherence(entries, targets: targets, days: 7, now: now)
        XCTAssertEqual(adherence.loggedDays, 5)
        XCTAssertEqual(adherence.calorieDaysOnTarget, 4)
        XCTAssertEqual(adherence.calorieAdherence, 4.0 / 7, accuracy: 0.001)
        XCTAssertEqual(adherence.proteinDaysOnTarget, 5)
    }

    func testTrainingAdherenceAndWeekCount() {
        var sessions: [WorkoutSession] = []
        for daysAgo in [0, 2, 9] {
            var session = WorkoutSession(name: "A", startedAt: day(daysAgo, hour: 8), exercises: [])
            session.endedAt = day(daysAgo, hour: 9)
            sessions.append(session)
        }
        let metrics = CoachMetrics(calendar: calendar)
        let adherence = metrics.trainingAdherence(sessions, plannedPerWeek: 4, days: 7, now: now)
        XCTAssertEqual(adherence.planned, 4)
        XCTAssertEqual(adherence.completed, 2)
        let week = metrics.thisWeek(sessions, plannedPerWeek: 4, now: now)
        XCTAssertEqual(week.completed, 1, "Only today's session is in this Monday-started week")
        XCTAssertEqual(week.daysLeft, 6)
    }

    // MARK: Weekly decisions

    func testLeanBulkInsideRangeIsOnTrackWithNoChange() {
        let result = review(profile(goal: .buildMuscle, calories: 2800), weights: weights(end: 80, weeklyChange: 0.25),
                            food: food(days: 1...21, calories: 2800))
        XCTAssertEqual(result.goalStatus, .within)
        XCTAssertEqual(result.confidence, .high)
        guard case .onTrack(let reason) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertTrue(reason.contains("No changes recommended"), reason)
        let decision = result.decision(status: .applied)
        XCTAssertEqual(decision?.kind, .noChange)
        XCTAssertEqual(decision?.newCalories, 2800)
    }

    func testPoorAdherenceNeverChangesCalories() {
        let onTarget = food(days: 1...10, calories: 2800)
        let over = food(days: 11...21, calories: 3600)
        let result = review(profile(goal: .buildMuscle, calories: 2800), weights: weights(end: 80, weeklyChange: 0.6),
                            food: onTarget + over)
        guard case .improveAdherence(let reason) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertTrue(reason.contains("48%"), reason)
        XCTAssertEqual(result.decision(status: .applied)?.newCalories, 2800)
    }

    func testStalledBulkWithGoodAdherenceAddsCaloriesInSafeSteps() {
        let result = review(profile(goal: .buildMuscle, calories: 2600), weights: weights(end: 80, weeklyChange: 0),
                            food: food(days: 1...21, calories: 2600))
        XCTAssertEqual(result.goalStatus, .below)
        guard case .adjustCalories(let from, let to, let reason) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertEqual(from, 2600)
        XCTAssertGreaterThanOrEqual(to - from, 100)
        XCTAssertLessThanOrEqual(to - from, 250)
        XCTAssertEqual(to.truncatingRemainder(dividingBy: 50), 0)
        XCTAssertTrue(reason.contains("100% calorie adherence"), reason)
        XCTAssertTrue(reason.contains("Increase your target"), reason)

        let rejected = result.decision(status: .rejected)
        XCTAssertEqual(rejected?.kind, .calorieAdjustment)
        XCTAssertEqual(rejected?.newCalories, 2600, "Keeping current targets records no change")
        XCTAssertEqual(result.decision(status: .applied)?.newCalories, to)
        XCTAssertEqual(result.decision(status: .applied)?.baselineKgPerWeek ?? 1, 0, accuracy: 0.01)
    }

    func testFatLossTooFastRaisesCalories() {
        let result = review(profile(goal: .loseFat, calories: 1900), weights: weights(end: 80, weeklyChange: -1.2),
                            food: food(days: 1...21, calories: 1900))
        XCTAssertEqual(result.goalStatus, .below)
        guard case .adjustCalories(_, let to, _) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertGreaterThan(to, 1900)
    }

    func testNeverRecommendsBelowTheFloor() {
        let result = review(profile(goal: .loseFat, calories: 1200), weights: weights(end: 60, weeklyChange: 0),
                            food: food(days: 1...21, calories: 1200))
        guard case .improveAdherence(let reason) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertTrue(reason.contains("qualified professional"), reason)
    }

    func testShortTrendOutsideRangeWaitsAWeek() {
        let result = review(profile(goal: .buildMuscle, calories: 2600), weights: weights(end: 80, weeklyChange: 0, days: 1...15),
                            food: food(days: 1...15, calories: 2600))
        XCTAssertEqual(result.confidence, .moderate)
        guard case .watch(let reason) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertTrue(reason.contains("one more week"), reason)
    }

    func testInsufficientDataListsWhatsMissing() {
        let result = review(profile(goal: .buildMuscle, calories: 2600), weights: weights(end: 80, weeklyChange: 0, days: 1...3),
                            food: food(days: 1...4, calories: 2600))
        XCTAssertEqual(result.confidence, .low)
        guard case .learningBaseline(let items) = result.recommendation else { return XCTFail("\(result.recommendation)") }
        XCTAssertEqual(items.first { $0.label == "weigh-ins" }?.done, 3)
        XCTAssertEqual(items.first { $0.label == "nutrition days" }?.done, 4)
        XCTAssertNil(result.decision(status: .applied), "Nothing to record while learning")
    }

    func testCheckInIsWeekly() {
        let engine = WeeklyCheckInEngine(calendar: calendar)
        XCTAssertTrue(engine.isDue(lastReview: nil, now: now))
        XCTAssertFalse(engine.isDue(lastReview: day(3), now: now))
        XCTAssertTrue(engine.isDue(lastReview: day(7, hour: 9), now: now))
    }

    // MARK: Outcomes

    func testOutcomeOfAppliedChange() {
        let decision = CoachDecision(date: day(21), kind: .calorieAdjustment, status: .applied, goal: .buildMuscle, previousCalories: 2600,
                                     newCalories: 2800, reason: "", evidence: [], confidence: .high, baselineKgPerWeek: 0,
                                     baselineCalorieAdherence: 1)
        let evaluator = OutcomeEvaluator(calendar: calendar)
        let working = evaluator.evaluate(decision, bodyWeights: weights(end: 80, weeklyChange: 0.25, days: 1...20), now: now)
        XCTAssertEqual(working.verdict, .effective)
        XCTAssertTrue(working.summary.contains("+200 kcal"), working.summary)

        let flat = evaluator.evaluate(decision, bodyWeights: weights(end: 80, weeklyChange: 0, days: 1...20), now: now)
        XCTAssertEqual(flat.verdict, .notEffective)

        let early = evaluator.evaluate(decision, bodyWeights: weights(end: 80, weeklyChange: 0.25, days: 1...20), now: day(14))
        XCTAssertEqual(early.verdict, .measuring)

        let kept = CoachDecision(date: day(7), kind: .noChange, status: .applied, goal: .buildMuscle, previousCalories: 2800,
                                 newCalories: 2800, reason: "", evidence: [], confidence: .high, baselineKgPerWeek: 0.2, baselineCalorieAdherence: 1)
        let latest = evaluator.latestOutcome(decisions: [decision, kept], bodyWeights: weights(end: 80, weeklyChange: 0.25), now: now)
        XCTAssertEqual(latest?.decision.id, decision.id, "Only calorie changes are evaluated")
    }

    // MARK: Progression v2

    func perf(_ daysAgo: Int, weight: Double = 100, reps: [Int], rpe: Double?) -> ExercisePerformance {
        let sets = reps.map { SetLog(weight: weight, reps: $0, isCompleted: true, rpe: rpe) }
        return ExercisePerformance(date: now.addingTimeInterval(Double(-daysAgo) * 86_400), sessionID: UUID(),
                                   log: ExerciseLog(exerciseID: "back-squat", sets: sets, repRange: .fixed(8), restSeconds: 180))
    }

    func testRPENineAtTopRepeatsBeforeAddingLoad() {
        let squat = ExerciseCatalog.standard["back-squat"]!
        let engine = ProgressionEngine()
        let hard = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [perf(3, reps: [8, 8, 8], rpe: 9)])
        XCTAssertEqual(hard.action, .repeatLoad)
        let easy = engine.recommend(for: squat, repRange: .fixed(8), sets: 3, history: [perf(3, reps: [8, 8, 8], rpe: 8.5)])
        XCTAssertEqual(easy.action, .increaseLoad)
    }

    func testFallingRepsAtMaximalEffortReduceLoad() {
        let squat = ExerciseCatalog.standard["back-squat"]!
        let history = [perf(2, reps: [7, 6, 6], rpe: 10), perf(5, reps: [7, 7, 6], rpe: 9.5), perf(9, reps: [7, 7, 7], rpe: 9)]
        let rec = ProgressionEngine().recommend(for: squat, repRange: RepRange(6, 8), sets: 3, history: history)
        XCTAssertEqual(rec.action, .reduceLoad)
        XCTAssertEqual(rec.weight, 97.5)
        XCTAssertTrue(rec.reason.contains("21 → 20 → 19"), rec.reason)
    }

    // MARK: Today, set feedback, safety

    func testSetFeedback() {
        var set = SetLog(weight: 80, reps: 8, isCompleted: true)
        set.targetReps = 8
        set.targetWeight = 80
        var next = SetLog(weight: 82.5, reps: 6, isCompleted: false)
        next.targetReps = 6
        next.targetWeight = 82.5
        let achieved = SetFeedback.evaluate(set, next: next, restSeconds: 120, unit: .kilograms)
        XCTAssertEqual(achieved?.result, .achieved)
        XCTAssertEqual(achieved?.text.hasPrefix("Target achieved. Next: 82.5 kg × 6."), true, achieved?.text ?? "")
        set.reps = 6
        XCTAssertEqual(SetFeedback.evaluate(set, next: nil, restSeconds: nil, unit: .kilograms)?.result, .below)
        set.reps = 10
        XCTAssertEqual(SetFeedback.evaluate(set, next: nil, restSeconds: nil, unit: .kilograms)?.text, "Above target.")
        set.kind = .warmup
        XCTAssertNil(SetFeedback.evaluate(set, next: nil, restSeconds: nil, unit: .kilograms))
    }

    func testProteinNudgeSplitsAcrossRemainingMeals() {
        let evening = ProteinNudge.make(remaining: 32, now: day(0, hour: 18), calendar: calendar)
        XCTAssertEqual(evening?.mealsLeft, 1)
        XCTAssertEqual(evening?.text, "You need 32g more protein today. Aim for about 30–35g with your next meal.")
        let morning = ProteinNudge.make(remaining: 120, now: day(0, hour: 8), calendar: calendar)
        XCTAssertEqual(morning?.mealsLeft, 3)
        XCTAssertEqual(morning?.perMealLow, 40)
        XCTAssertNil(ProteinNudge.make(remaining: 5, now: now, calendar: calendar))
    }

    func testTodayCoachSaysOnTrackOrLearning() {
        let p = profile(goal: .buildMuscle, calories: 2800)
        let onTrack = review(p, weights: weights(end: 80, weeklyChange: 0.25), food: food(days: 1...21, calories: 2800))
        let engine = TodayCoachEngine(calendar: calendar)
        let today = engine.coaching(profile: p, program: nil, sessions: [], foodEntries: [], bodyWeights: [], review: onTrack,
                                    checkInDue: false, recommendations: [], now: now)
        XCTAssertEqual(today.focus, .onTrack)
        XCTAssertEqual(today.headline, "Everything is on track.")

        let learning = review(p, weights: weights(end: 80, weeklyChange: 0, days: 1...3), food: [])
        let early = engine.coaching(profile: p, program: nil, sessions: [], foodEntries: [], bodyWeights: [], review: learning,
                                    checkInDue: true, recommendations: [], now: now)
        XCTAssertEqual(early.headline, "Vector is learning your baseline.")
        XCTAssertTrue(early.accountability.contains("5 more weigh-ins before Vector can judge your weight trend."), "\(early.accountability)")

        let due = engine.coaching(profile: p, program: nil, sessions: [], foodEntries: [], bodyWeights: [], review: onTrack,
                                  checkInDue: true, recommendations: [], now: now)
        XCTAssertEqual(due.focus, .checkInReady)
    }

    func testDiscomfortNotesAndSafetyText() {
        XCTAssertTrue(SafetyGuidance.pain.hasPrefix("Pain during an exercise shouldn't be ignored."))
        XCTAssertTrue(SafetyGuidance.pain.contains("appropriately qualified healthcare professional"))
        let note = DiscomfortNote(date: now, exerciseID: "bench-press", location: "  Left shoulder  ", timing: .duringSet)
        XCTAssertEqual(note.location, "Left shoulder")
    }

    // MARK: Persistence and sync

    func testDecisionsAndNotesDecodeFromOldDataAndMerge() throws {
        let old = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(AppData()))
        XCTAssertNil(old.coachDecisions)

        let a = CoachDecision(date: day(14), kind: .noChange, status: .applied, goal: .maintain, previousCalories: 2400, newCalories: 2400,
                              reason: "On track", evidence: [], confidence: .high, baselineKgPerWeek: 0, baselineCalorieAdherence: 0.9)
        let b = CoachDecision(date: day(7), kind: .calorieAdjustment, status: .rejected, goal: .maintain, previousCalories: 2400,
                              newCalories: 2400, reason: "", evidence: [], confidence: .moderate, baselineKgPerWeek: 0.3, baselineCalorieAdherence: 0.85)
        let note = DiscomfortNote(date: day(2), exerciseID: nil, location: "Knee", timing: .nextDay)
        var local = AppData(modifiedAt: day(1), coachDecisions: [a])
        let remote = AppData(modifiedAt: day(0), coachDecisions: [b], discomfortNotes: [note])
        var merged = SyncMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.coachDecisions?.map(\.id), [a.id, b.id])
        XCTAssertEqual(merged.discomfortNotes?.count, 1)

        local.deletedIDs = Tombstone.all(in: merged)
        merged = SyncMerge.merge(local: local, remote: remote)
        XCTAssertNil(merged.coachDecisions, "Reset removes decisions everywhere")
        XCTAssertNil(merged.discomfortNotes)

        let roundTrip = try JSONDecoder().decode(CoachDecision.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(roundTrip, a)
    }
}
