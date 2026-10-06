import Foundation
import VectorCore

/// The digital coach: weekly review, today's single focus, decision memory
/// and the discomfort safety path. Every decision comes from VectorCore's
/// deterministic engines; nothing here asks an AI what to do.
extension AppModel {
    private var coachState: (review: WeeklyReview, today: TodayCoaching)? {
        guard let profile = data.profile else { return nil }
        let day = calendar.startOfDay(for: now())
        if let reviewCache, reviewCache.day == day { return (reviewCache.review, reviewCache.today) }
        let review = WeeklyCheckInEngine(calendar: calendar, catalog: catalog)
            .review(profile: profile, program: data.program, sessions: data.sessions, foodEntries: data.foodEntries,
                    bodyWeights: data.bodyWeights, decisions: coachDecisions, now: now())
        let today = TodayCoachEngine(catalog: catalog, calendar: calendar)
            .coaching(profile: profile, program: data.program, sessions: data.sessions, foodEntries: data.foodEntries,
                      bodyWeights: data.bodyWeights, review: review,
                      // The Weekly Check-In card sits on Today itself, so the coach card
                      // never repeats it: one decision on screen at a time.
                      checkInDue: false,
                      recommendations: recommendations, includesDecision: isPro, now: now())
        reviewCache = (day, review, today)
        return (review, today)
    }

    /// This week's review (training, nutrition, body weight, goal, one decision).
    var weeklyReview: WeeklyReview? { coachState?.review }

    /// What the Vector Coach card says today.
    var todayCoaching: TodayCoaching? { coachState?.today }

    var coachDecisions: [CoachDecision] { data.coachDecisions ?? [] }

    var discomfortNotes: [DiscomfortNote] { data.discomfortNotes ?? [] }

    /// Weekly, counted from the last decision or legacy calorie check-in.
    var weeklyCheckInDue: Bool {
        let last = [coachDecisions.last?.date, checkIns.last?.date].compactMap { $0 }.max()
        return WeeklyCheckInEngine(calendar: calendar).isDue(lastReview: last, now: now())
    }

    /// The check-in card appears when due and once there's something to review.
    var showsWeeklyCheckIn: Bool {
        guard weeklyCheckInDue, let review = weeklyReview else { return false }
        if case .learningBaseline = review.recommendation {
            return data.bodyWeights.count >= 2 || data.sessions.count >= 3
        }
        return true
    }

    /// Outcomes of past calorie changes, newest first.
    var decisionOutcomes: [DecisionOutcome] {
        let evaluator = OutcomeEvaluator(calendar: calendar)
        return coachDecisions
            .filter { $0.kind == .calorieAdjustment && $0.status == .applied && $0.calorieChange != 0 }
            .sorted { $0.date > $1.date }
            .map { evaluator.evaluate($0, bodyWeights: data.bodyWeights, now: now()) }
    }

    // MARK: Acting on the review

    /// Pro: accept the recommendation (a calorie change, or an on-track or
    /// adherence review acknowledged). Records the decision either way.
    func applyReview(_ review: WeeklyReview) {
        guard isPro, let decision = review.decision(status: .applied) else { return }
        mutate { data in
            if decision.kind == .calorieAdjustment, var profile = data.profile {
                profile.targets = profile.targets.withCalories(decision.newCalories)
                data.profile = profile
            }
            data.coachDecisions = (data.coachDecisions ?? []) + [decision]
        }
        trackDecision(decision, review: review)
        if decision.kind == .calorieAdjustment {
            track(.recommendationApplied, ["kind": "calorie_adjustment"])
            track(.calorieAdjustmentAccepted, ["change_kcal": .number(decision.calorieChange)])
            track(.adjustmentCreated, ["kind": "calories", "change_kcal": .number(decision.calorieChange),
                                       "confidence": .string(decision.confidence.analyticsName)])
            showToast("checkmark.circle.fill", "Targets updated", subtitle: "\(Format.integer(decision.newCalories)) kcal a day")
        }
    }

    /// Keep current targets. For a calorie recommendation this is a rejection,
    /// remembered so Vector can measure how often its advice is trusted.
    func keepCurrentTargets(_ review: WeeklyReview) {
        let decision = review.decision(status: isPro && isCalorieChange(review) ? .rejected : .applied)
            ?? CoachDecision(date: now(), kind: .noChange, status: .applied, goal: review.goal, previousCalories: review.targets.calories,
                             newCalories: review.targets.calories, reason: "Weekly review viewed.", evidence: [],
                             confidence: review.confidence, baselineKgPerWeek: review.body.trend?.kgPerWeek,
                             baselineCalorieAdherence: review.nutrition.calorieAdherence)
        var recorded = decision
        recorded.newCalories = recorded.previousCalories
        mutate({ $0.coachDecisions = ($0.coachDecisions ?? []) + [recorded] }, refreshInsights: false)
        trackDecision(recorded, review: review)
        if isPro, isCalorieChange(review) {
            track(.recommendationRejected, ["kind": "calorie_adjustment"])
            track(.calorieAdjustmentRejected, ["proposed_change_kcal": .number(decision.calorieChange)])
        }
    }

    private func isCalorieChange(_ review: WeeklyReview) -> Bool {
        if case .adjustCalories = review.recommendation { return true }
        return false
    }

    private func trackDecision(_ decision: CoachDecision, review: WeeklyReview) {
        track(.weeklyCheckInCompleted, ["decision": .string(decision.kind.rawValue), "status": .string(decision.status.rawValue),
                                        "confidence": .string(review.confidence.analyticsName), "pro": .bool(isPro)])
        if let outcome = review.previousOutcome, outcome.verdict != .measuring {
            track(.adjustmentOutcomeMeasured, ["verdict": .string(outcome.verdict.rawValue)])
        }
    }

    func trackReviewViewed(_ review: WeeklyReview) {
        track(.recommendationViewed, ["surface": "weekly_checkin", "decision": .string(review.recommendation.analyticsName),
                                      "confidence": .string(review.confidence.analyticsName), "pro": .bool(isPro)])
    }

    // MARK: Progression accept / reject

    func trackProgression(_ recommendation: ProgressionRecommendation, accepted: Bool) {
        track(accepted ? .trainingProgressionAccepted : .trainingProgressionRejected, ["action": .string(recommendation.action.rawValue)])
    }

    // MARK: Discomfort

    /// Records what, where and when. Stays on device and in the user's iCloud;
    /// never sent to the backend, analytics or the AI.
    func reportDiscomfort(exerciseID: String?, location: String, timing: DiscomfortNote.Timing) {
        let note = DiscomfortNote(date: now(), exerciseID: exerciseID, location: location, timing: timing)
        mutate({ $0.discomfortNotes = ($0.discomfortNotes ?? []) + [note] }, refreshInsights: false)
    }

    func deleteDiscomfortNote(_ note: DiscomfortNote) {
        mutate({ data in
            data.discomfortNotes?.removeAll { $0.id == note.id }
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.discomfort(note.id)])
        }, refreshInsights: false)
    }
}

extension CoachConfidence {
    var analyticsName: String {
        switch self {
        case .insufficient: "insufficient"
        case .low: "low"
        case .moderate: "moderate"
        case .high: "high"
        }
    }
}

extension CoachRecommendation {
    var analyticsName: String {
        switch self {
        case .learningBaseline: "learning_baseline"
        case .improveAdherence: "improve_adherence"
        case .onTrack: "on_track"
        case .adjustCalories: "adjust_calories"
        case .watch: "watch"
        }
    }
}
