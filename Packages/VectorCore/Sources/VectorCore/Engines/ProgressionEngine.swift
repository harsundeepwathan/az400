import Foundation

/// A single fact that backs up a recommendation. Every AI-flavoured surface
/// in the app shows these so advice is never unexplained.
public struct Evidence: Hashable, Codable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public struct ProgressionRecommendation: Identifiable, Hashable, Sendable {
    public enum Action: String, Hashable, Sendable {
        /// No history yet. The user picks a starting load.
        case establishBaseline
        case increaseLoad
        case increaseReps
        case repeatLoad
        case reduceLoad
        case deload

        public var title: String {
            switch self {
            case .establishBaseline: "Find your working weight"
            case .increaseLoad: "Increase load"
            case .increaseReps: "Add reps"
            case .repeatLoad: "Repeat and own it"
            case .reduceLoad: "Reset slightly"
            case .deload: "Deload"
            }
        }

        public var isProgression: Bool { self == .increaseLoad || self == .increaseReps }
    }

    public var exerciseID: String
    public var id: String { exerciseID }
    public var action: Action
    /// Nil when there is no history to base a load on.
    public var weight: Double?
    public var reps: Int
    public var sets: Int
    public var reason: String
    public var evidence: [Evidence]

    public init(exerciseID: String, action: Action, weight: Double?, reps: Int, sets: Int, reason: String, evidence: [Evidence]) {
        self.exerciseID = exerciseID
        self.action = action
        self.weight = weight
        self.reps = reps
        self.sets = sets
        self.reason = reason
        self.evidence = evidence
    }
}

/// One logged appearance of an exercise in a finished session.
public struct ExercisePerformance: Hashable, Sendable {
    public var date: Date
    public var sessionID: UUID
    public var log: ExerciseLog

    public init(date: Date, sessionID: UUID, log: ExerciseLog) {
        self.date = date
        self.sessionID = sessionID
        self.log = log
    }

    public var workingSets: [SetLog] { log.completedWorkingSets }
    public var topWeight: Double { workingSets.map(\.weight).max() ?? 0 }
    public var estimatedOneRepMax: Double { log.bestEstimatedOneRepMax }
    public var volume: Double { log.volume }

    /// Sets performed at the session's top working weight.
    public var topSets: [SetLog] { workingSets.filter { $0.weight == topWeight } }

    /// "80 × 8, 8, 7" style summary.
    public func summary(unit: WeightUnit = .kilograms) -> String {
        guard !workingSets.isEmpty else { return "No completed sets" }
        let reps = topSets.map { "\($0.reps)" }.joined(separator: ", ")
        if topWeight == 0 { return "\(reps) reps" }
        return "\(Format.weight(topWeight, unit: unit, includeUnit: false)) × \(reps)"
    }
}

public struct ProgressionEngine: Sendable {
    public init() {}

    /// Finished performances of an exercise, newest first.
    public func history(for exerciseID: String, in sessions: [WorkoutSession]) -> [ExercisePerformance] {
        sessions
            .filter(\.isFinished)
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { session in
                guard let log = session.log(for: exerciseID), !log.completedWorkingSets.isEmpty else { return nil }
                return ExercisePerformance(date: session.startedAt, sessionID: session.id, log: log)
            }
    }

    public func recommend(
        for exercise: Exercise,
        repRange: RepRange,
        sets: Int,
        history: [ExercisePerformance],
        unit: WeightUnit = .kilograms
    ) -> ProgressionRecommendation {
        let fmt = { (kg: Double) in Format.weight(kg, unit: unit) }

        guard let last = history.first else {
            return ProgressionRecommendation(
                exerciseID: exercise.id,
                action: .establishBaseline,
                weight: nil,
                reps: repRange.upper,
                sets: sets,
                reason: "First time logging \(exercise.name). Pick a load you could lift for about \(repRange.upper + 2) reps. We'll progress from there.",
                evidence: [Evidence("Target", "\(sets) × \(repRange.label) reps")]
            )
        }

        var evidence: [Evidence] = [Evidence("Last session", last.summary(unit: unit))]
        if last.estimatedOneRepMax > 0 {
            evidence.append(Evidence("Estimated 1RM", Format.estimate(last.estimatedOneRepMax, unit: unit)))
        }
        if let trend = volumeTrend(history) {
            evidence.append(Evidence("Volume trend", "\(Format.signedPercent(trend)) over \(min(history.count, 3)) sessions"))
        }

        let weight = last.topWeight
        let topSets = last.topSets
        let hitTop = topSets.count >= sets && topSets.prefix(sets).allSatisfy { $0.reps >= repRange.upper }
        let missed = topSets.contains { $0.reps < repRange.lower }
        let successCount = topSets.filter { $0.reps >= repRange.lower }.count
        evidence.append(Evidence("Successful sets", "\(successCount)/\(max(topSets.count, sets))"))

        // 1. Sustained decline: three sessions of falling estimated 1RM.
        if history.count >= 3 {
            let recent = history.prefix(3).map(\.estimatedOneRepMax)
            if recent[0] < recent[1], recent[1] < recent[2], recent[2] > 0, (recent[2] - recent[0]) / recent[2] >= 0.05 {
                let deloadWeight = LoadRounding.round(weight * 0.9, step: exercise.loadIncrement)
                let path = recent.reversed().map { Format.estimate($0, unit: unit, includeUnit: false) }.joined(separator: " → ")
                return ProgressionRecommendation(
                    exerciseID: exercise.id,
                    action: .deload,
                    weight: deloadWeight,
                    reps: repRange.lower,
                    sets: sets,
                    reason: "Estimated 1RM has fallen three sessions in a row (\(path) \(unit.symbol)). A lighter week lets fatigue clear so you can push again.",
                    evidence: evidence
                )
            }
        }

        // Logged effort, when the athlete records it, refines the decision.
        let topRPE = topSets.compactMap(\.rpe).max()
        if let topRPE {
            evidence.append(Evidence("Hardest set", "RPE \(Format.rpe(topRPE))"))
        }

        // 2. Hit the top of the range on every set: add load.
        if hitTop {
            let twice = history.count >= 2 && Self.hitTop(history[1], weight: weight, sets: sets, range: repRange)
            let setsText = sets == 1 ? "your set" : "all \(sets) sets"
            let suffix = twice ? " twice in a row" : ""
            // A grinder at true failure isn't owned yet. Repeat once before adding load.
            if let topRPE, topRPE >= Self.maximalEffortRPE, !twice, exercise.loadIncrement > 0 {
                return ProgressionRecommendation(
                    exerciseID: exercise.id,
                    action: .repeatLoad,
                    weight: weight,
                    reps: repRange.upper,
                    sets: sets,
                    reason: "You hit \(fmt(weight)) × \(repRange.upper) on \(setsText), but at RPE \(Format.rpe(topRPE)) with nothing left. Repeat it once with a rep in reserve, then add load.",
                    evidence: evidence
                )
            }
            if exercise.loadIncrement > 0 {
                return ProgressionRecommendation(
                    exerciseID: exercise.id,
                    action: .increaseLoad,
                    weight: weight + exercise.loadIncrement,
                    reps: repRange.isFixed ? repRange.upper : repRange.lower,
                    sets: sets,
                    reason: "You completed \(fmt(weight)) × \(repRange.upper) across \(setsText)\(suffix)" + (topRPE.map { " at RPE \(Format.rpe($0))" } ?? "") + ".",
                    evidence: evidence
                )
            }
            return ProgressionRecommendation(
                exerciseID: exercise.id,
                action: .increaseReps,
                weight: weight,
                reps: repRange.upper + 1,
                sets: sets,
                reason: "You hit \(repRange.upper) reps on \(setsText)\(suffix). Push for \(repRange.upper + 1).",
                evidence: evidence
            )
        }

        // 3. Missed the bottom of the range.
        if missed {
            let missedAgain = history.count >= 2
                && history[1].topWeight == weight
                && history[1].topSets.contains { $0.reps < repRange.lower }
            let repsText = topSets.map { "\($0.reps)" }.joined(separator: ", ")
            if missedAgain, exercise.loadIncrement > 0 {
                return ProgressionRecommendation(
                    exerciseID: exercise.id,
                    action: .reduceLoad,
                    weight: max(weight - exercise.loadIncrement, 0),
                    reps: repRange.upper,
                    sets: sets,
                    reason: "\(fmt(weight)) fell short of \(repRange.lower) reps in two sessions in a row. Drop one step and build back up with clean reps.",
                    evidence: evidence
                )
            }
            return ProgressionRecommendation(
                exerciseID: exercise.id,
                action: .repeatLoad,
                weight: weight,
                reps: repRange.lower,
                sets: sets,
                reason: "Last time you got \(repsText) at \(fmt(weight)). Repeat the weight and aim for \(repRange.lower) on every set.",
                evidence: evidence
            )
        }

        // 4. Inside the range: earn the next rep before adding load.
        let lowest = topSets.map(\.reps).min() ?? repRange.lower
        let nextReps = min(max(lowest + 1, repRange.lower), repRange.upper)
        return ProgressionRecommendation(
            exerciseID: exercise.id,
            action: .increaseReps,
            weight: weight,
            reps: nextReps,
            sets: sets,
            reason: "All sets landed in your \(repRange.label) range at \(fmt(weight)). Add a rep before adding load.",
            evidence: evidence
        )
    }

    /// RPE at or above which a set is treated as maximal (no reps in reserve).
    public static let maximalEffortRPE = 9.5

    static func hitTop(_ performance: ExercisePerformance, weight: Double, sets: Int, range: RepRange) -> Bool {
        let top = performance.workingSets.filter { $0.weight == weight }
        return top.count >= sets && top.prefix(sets).allSatisfy { $0.reps >= range.upper }
    }

    /// Fractional change in volume from the oldest to newest of the last three sessions.
    public func volumeTrend(_ history: [ExercisePerformance]) -> Double? {
        let recent = Array(history.prefix(3))
        guard recent.count >= 2, let oldest = recent.last, oldest.volume > 0 else { return nil }
        return (recent[0].volume - oldest.volume) / oldest.volume
    }
}
