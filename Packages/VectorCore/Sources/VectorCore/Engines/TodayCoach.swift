import Foundation

// Today's single coaching message, in-session set feedback, and the fixed
// safety path for discomfort. All deterministic; none of it goes to the AI.

// MARK: - Safety

public enum SafetyGuidance {
    /// Shown whenever a user reports pain or discomfort. Fixed text: Vector
    /// never diagnoses, and this is never generated or rephrased by AI.
    public static let pain = "Pain during an exercise shouldn't be ignored. Consider stopping or modifying movements that reproduce the pain. If pain persists, is severe, follows an injury, or concerns you, seek assessment from an appropriately qualified healthcare professional."

    public static let scope = "Vector is a training and nutrition coach. It isn't a doctor, physiotherapist or dietitian, and it can't diagnose injuries."
}

/// A user's own record of discomfort. Vector stores what, where and when,
/// and nothing else: no severity scoring, no diagnosis, no AI.
public struct DiscomfortNote: Identifiable, Codable, Hashable, Sendable {
    public enum Timing: String, Codable, CaseIterable, Sendable {
        case duringSet, afterSession, nextDay

        public var title: String {
            switch self {
            case .duringSet: "During the set"
            case .afterSession: "After the session"
            case .nextDay: "The next day"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var exerciseID: String?
    /// Free text chosen by the user, e.g. "Left shoulder".
    public var location: String
    public var timing: Timing

    public init(id: UUID = UUID(), date: Date, exerciseID: String?, location: String, timing: Timing) {
        self.id = id
        self.date = date
        self.exerciseID = exerciseID
        self.location = String(location.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        self.timing = timing
    }
}

// MARK: - Set feedback

public struct SetFeedback: Hashable, Sendable {
    public enum Result: String, Hashable, Sendable { case achieved, above, below }

    public var result: Result
    public var text: String

    /// Feedback for a completed working set against its target, plus the
    /// next set's target when there is one.
    public static func evaluate(_ set: SetLog, next: SetLog?, restSeconds: Int?, unit: WeightUnit) -> SetFeedback? {
        guard set.isCompleted, set.kind != .warmup, let target = set.targetReps else { return nil }
        let targetWeight = set.targetWeight ?? set.weight
        let result: Result
        if set.weight + 1e-9 < targetWeight || set.reps < target {
            result = .below
        } else if set.reps > target || set.weight > targetWeight + 1e-9 {
            result = .above
        } else {
            result = .achieved
        }
        let headline = switch result {
        case .achieved: "Target achieved."
        case .above: "Above target."
        case .below: "Below target (\(set.reps) of \(target)). That's fine: log it honestly."
        }
        var parts = [headline]
        if let next, !next.isCompleted {
            let reps = next.targetReps ?? next.reps
            let weight = next.targetWeight ?? next.weight
            parts.append(weight > 0 ? "Next: \(Format.weight(weight, unit: unit)) × \(reps)." : "Next: \(reps) reps.")
        }
        if let restSeconds, restSeconds > 0, next.map({ !$0.isCompleted }) ?? false {
            parts.append("Rest \(Format.duration(TimeInterval(restSeconds))).")
        }
        return SetFeedback(result: result, text: parts.joined(separator: " "))
    }
}

// MARK: - Protein

public struct ProteinNudge: Hashable, Sendable {
    public var remaining: Double
    public var mealsLeft: Int
    public var perMealLow: Double
    public var perMealHigh: Double

    public var text: String {
        let range = perMealLow == perMealHigh ? Format.grams(perMealLow) : "\(Int(perMealLow))–\(Format.grams(perMealHigh))"
        return mealsLeft <= 1
            ? "You need \(Format.grams(remaining)) more protein today. Aim for about \(range) with your next meal."
            : "You need \(Format.grams(remaining)) more protein today. Aim for about \(range) with each of your next \(mealsLeft) meals."
    }

    /// Splits what's left across the meals likely left today.
    public static func make(remaining: Double, now: Date, calendar: Calendar = .current) -> ProteinNudge? {
        guard remaining >= 10 else { return nil }
        let hour = calendar.component(.hour, from: now)
        let mealsLeft = hour < 11 ? 3 : (hour < 16 ? 2 : 1)
        let perMeal = remaining / Double(mealsLeft)
        let low = max((perMeal / 5).rounded(.down) * 5, 5)
        let high = max((perMeal / 5).rounded(.up) * 5, low)
        return ProteinNudge(remaining: remaining.rounded(), mealsLeft: mealsLeft, perMealLow: low, perMealHigh: high)
    }
}

// MARK: - Today coach

/// What the Vector Coach card shows today: one focus, never a list of advice.
public struct TodayCoaching: Hashable, Sendable {
    public enum Focus: Hashable, Sendable {
        /// The weekly check-in is ready with a decision to review.
        case checkInReady
        /// The main lift has a load change waiting today.
        case progression(ProgressionRecommendation)
        /// Not enough data yet; shows the checklist.
        case learningBaseline([BaselineItem])
        /// Nothing needs to change.
        case onTrack
    }

    public var focus: Focus
    public var headline: String
    public var detail: String?
    public var accountability: [String]
    public var protein: ProteinNudge?
}

public struct TodayCoachEngine: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
    }

    public func coaching(profile: UserProfile, program: TrainingProgram?, sessions: [WorkoutSession], foodEntries: [FoodEntry],
                         bodyWeights: [BodyWeightEntry], review: WeeklyReview, checkInDue: Bool,
                         recommendations: [ProgressionRecommendation], includesDecision: Bool = true, now: Date) -> TodayCoaching {
        let unit = profile.unit
        let metrics = CoachMetrics(calendar: calendar)
        let plannedPerWeek = max(program?.daysPerWeek ?? profile.daysPerWeek, 1)

        // Accountability: facts about the week, never guilt.
        var accountability: [String] = []
        let week = metrics.thisWeek(sessions, plannedPerWeek: plannedPerWeek, now: now)
        let left = max(week.planned - week.completed, 0)
        if left == 0 {
            accountability.append("All \(week.planned) planned workouts done this week.")
        } else if left <= week.daysLeft + 1 {
            accountability.append("\(left) of \(week.planned) workouts left this week.")
        } else {
            accountability.append("\(week.completed) of \(week.planned) workouts done this week. Any session you fit in still counts.")
        }
        if case .learningBaseline(let items) = review.recommendation,
           let weighIns = items.first(where: { $0.label == "weigh-ins" && !$0.isComplete }) {
            let more = weighIns.needed - weighIns.done
            accountability.append("\(more) more weigh-in\(more == 1 ? "" : "s") before Vector can judge your weight trend.")
        }

        let today = NutritionEngine(calendar: calendar).daily(foodEntries, on: now, targets: profile.targets)
        let protein = ProteinNudge.make(remaining: profile.targets.protein - today.consumed.protein, now: now, calendar: calendar)

        // 1. A decision waiting in the check-in comes first.
        if checkInDue {
            switch review.recommendation {
            case .adjustCalories(let from, let to, _) where includesDecision:
                return TodayCoaching(focus: .checkInReady, headline: "Your weekly check-in is ready.",
                                     detail: "Vector recommends changing your calorie target from \(Format.integer(from)) to \(Format.integer(to)) kcal.",
                                     accountability: accountability, protein: protein)
            case .adjustCalories, .improveAdherence, .onTrack, .watch:
                return TodayCoaching(focus: .checkInReady, headline: "Your weekly check-in is ready.",
                                     detail: "Review your week: training, nutrition and weight in one place.",
                                     accountability: accountability, protein: protein)
            case .learningBaseline:
                break
            }
        }

        // 2. Today's main lift changes load.
        let trainedToday = sessions.contains { $0.isFinished && calendar.isDate($0.startedAt, inSameDayAs: now) }
        if !trainedToday, let main = program?.nextWorkout?.exercises.first,
           let rec = recommendations.first(where: { $0.exerciseID == main.exerciseID }),
           [.increaseLoad, .reduceLoad, .deload].contains(rec.action), let weight = rec.weight, let exercise = catalog[main.exerciseID] {
            let verb = rec.action == .increaseLoad ? "Increase" : "Reduce"
            return TodayCoaching(focus: .progression(rec), headline: "\(verb) \(exercise.name) to \(Format.weight(weight, unit: unit)) × \(rec.reps) today.",
                                 detail: rec.reason, accountability: accountability, protein: protein)
        }

        // 3. Still learning.
        if case .learningBaseline(let items) = review.recommendation {
            return TodayCoaching(focus: .learningBaseline(items), headline: "Vector is learning your baseline.",
                                 detail: "Keep logging. Recommendations start once there's enough data to be confident.",
                                 accountability: accountability, protein: protein)
        }

        // 4. Nothing to change is a valid answer.
        return TodayCoaching(focus: .onTrack, headline: "Everything is on track.",
                             detail: "Follow today's plan. No changes needed.", accountability: accountability, protein: protein)
    }
}
