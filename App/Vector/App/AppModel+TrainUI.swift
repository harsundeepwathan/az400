import Foundation
import VectorCore

/// Read-only helpers for the Train tab and Exercise detail. They mirror what
/// `startWorkout` will pre-fill, so a number shown before a workout is the
/// number the workout opens with. Nothing here mutates state.
extension AppModel {
    /// Where a planned load comes from. Shown with the number so a free
    /// user's "last 80 kg" is never presented as a recommendation.
    enum PlannedLoadSource: Hashable {
        /// A target the athlete accepted or adjusted.
        case chosen
        /// Vector's progression recommendation (Pro, or the main lift on free).
        case recommended
        /// Free tier: last session's top weight.
        case lastSession
    }

    struct PlannedLoad: Hashable {
        var weight: Double
        var reps: Int
        var source: PlannedLoadSource
    }

    /// The load the next workout will open with for one prescription, using
    /// the same priority as `startWorkout`: chosen target, then (free tier,
    /// not the first exercise) last session, then the progression engine.
    /// Nil when there is no load to show yet (no history, or bodyweight).
    func plannedLoad(for item: ExercisePrescription, at index: Int) -> PlannedLoad? {
        if let target = target(for: item.exerciseID) {
            return target.weight > 0 ? PlannedLoad(weight: target.weight, reps: target.reps, source: .chosen) : nil
        }
        let past = history(for: item.exerciseID)
        if !isPro && index > 0 {
            guard let last = past.first, last.topWeight > 0 else { return nil }
            return PlannedLoad(weight: last.topWeight, reps: last.topSets.first?.reps ?? item.repRange.upper, source: .lastSession)
        }
        guard let exercise = catalog[item.exerciseID] else { return nil }
        let rec = progression.recommend(for: exercise, repRange: item.repRange, sets: item.sets, history: past, unit: unit)
        guard let weight = rec.weight, weight > 0 else { return nil }
        return PlannedLoad(weight: weight, reps: rec.reps, source: .recommended)
    }

    /// Whether the progression recommendation for this exercise is visible
    /// on the free tier (the next workout's main lift is a taste of Pro).
    func showsRecommendation(for exerciseID: String) -> Bool {
        isPro || nextWorkout?.exercises.first?.exerciseID == exerciseID
    }

    /// The program's display name without its " — 4 days" suffix.
    var programShortName: String? {
        program.map { $0.name.components(separatedBy: " — ").first ?? $0.name }
    }
}
