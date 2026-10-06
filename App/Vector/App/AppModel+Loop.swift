import Foundation
import VectorCore

/// The closed loop: goal → training and nutrition → body weight and
/// performance → analysis → adjustment → today's recommendation.
extension AppModel {
    /// Today's answer to "what should I do?", from the user's own data only.
    var dailyBrief: DailyBrief? {
        guard let profile = data.profile else { return nil }
        let sessions = data.sessions
        let day = calendar.startOfDay(for: now())
        if let briefCache, briefCache.day == day { return briefCache.value }
        let context = CoachContext(sessions: sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: profile, now: now())
        let value = DailyBriefEngine(catalog: catalog, calendar: calendar).brief(context: context, recommendations: recommendations)
        briefCache = (day, value)
        return value
    }

    /// This week's calorie check-in, or nil when it isn't due (weekly) or was handled.
    var nutritionCheckIn: CheckInResult? {
        guard let profile = data.profile else { return nil }
        let entries = data.foodEntries
        let day = calendar.startOfDay(for: now())
        if let checkInCache, checkInCache.day == day { return checkInCache.value }
        let engine = AdaptiveNutritionEngine(calendar: calendar)
        let value: CheckInResult? = engine.isDue(lastCheckIn: data.checkIns?.last?.date, now: now())
            ? engine.evaluate(profile: profile, bodyWeights: data.bodyWeights, foodEntries: entries, now: now())
            : nil
        checkInCache = (day, value)
        return value
    }

    var checkIns: [NutritionCheckIn] { data.checkIns ?? [] }

    /// Accepts the recommendation: calories change, protein and fat stay, carbs absorb the difference.
    func applyCheckIn(_ checkIn: NutritionCheckIn) {
        var accepted = checkIn
        accepted.applied = true
        commit { data in
            if var profile = data.profile {
                profile.targets = AdaptiveNutritionEngine.targets(applying: checkIn, to: profile.targets)
                data.profile = profile
            }
            data.checkIns = (data.checkIns ?? []) + [accepted]
        }
        track(.nutritionCheckInApplied, ["applied": true, "change_kcal": .number(checkIn.change)])
        showToast("checkmark.circle.fill", "Targets updated", subtitle: "\(Format.integer(checkIn.recommendedCalories)) kcal a day")
    }

    /// Keeps current targets; the next check-in is in a week.
    func keepTargets(_ checkIn: NutritionCheckIn) {
        commit({ $0.checkIns = ($0.checkIns ?? []) + [checkIn] }, refreshInsights: false)
        track(.nutritionCheckInApplied, ["applied": false, "change_kcal": .number(checkIn.change)])
    }
}
