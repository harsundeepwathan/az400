import Foundation

public struct SetPosition: Hashable, Codable, Sendable {
    public var exercise: Int
    public var set: Int

    public init(exercise: Int, set: Int) {
        self.exercise = exercise
        self.set = set
    }
}

/// Result of completing a set. The UI uses it to drive haptics, the rest
/// timer and focus movement without re-deriving any of it.
public struct SetCompletion: Hashable, Sendable {
    public var position: SetPosition
    public var restSeconds: Int
    public var nextFocus: SetPosition?
    public var finishedExercise: Bool
    public var finishedWorkout: Bool
    /// True when this set beats the athlete's previous best weight / reps.
    public var isPersonalRecord: Bool
}

/// The in-progress workout as a pure value type. Every gym-floor action
/// (complete a set, edit load, add a set, swap an exercise) is a mutating
/// method, which keeps the logic unit-testable and lets the app persist the
/// whole thing after each change so a crash never loses a set.
public struct ActiveWorkout: Codable, Hashable, Sendable {
    public var session: WorkoutSession
    public var focus: SetPosition?
    /// Previous best (weight, reps) per exercise, captured at start for live PR detection.
    public var previousBests: [String: PreviousBest]

    public struct PreviousBest: Codable, Hashable, Sendable {
        public var weight: Double
        public var reps: Int
    }

    public init(session: WorkoutSession, focus: SetPosition?, previousBests: [String: PreviousBest]) {
        self.session = session
        self.focus = focus
        self.previousBests = previousBests
    }

    // MARK: Start

    /// Builds a workout from a template, pre-filling every set with the
    /// progression recommendation so most sets need a single tap.
    public static func start(
        template: WorkoutTemplate,
        catalog: ExerciseCatalog,
        history: [WorkoutSession],
        overrides: [String: ProgressionRecommendation] = [:],
        unit: WeightUnit = .kilograms,
        now: Date = Date()
    ) -> ActiveWorkout {
        let engine = ProgressionEngine()
        let logs: [ExerciseLog] = template.exercises.compactMap { item in
            guard let exercise = catalog[item.exerciseID] else { return nil }
            let past = engine.history(for: item.exerciseID, in: history)
            let rec = overrides[item.exerciseID]
                ?? engine.recommend(for: exercise, repRange: item.repRange, sets: item.sets, history: past, unit: unit)
            let weight = rec.weight ?? 0
            let sets = (0..<max(item.sets, 1)).map { _ in
                SetLog(weight: weight, reps: rec.reps, targetReps: rec.reps, targetWeight: rec.weight)
            }
            return ExerciseLog(exerciseID: item.exerciseID, sets: sets, repRange: item.repRange,
                               restSeconds: item.restSeconds ?? exercise.defaultRestSeconds)
        }
        let session = WorkoutSession(templateID: template.id, name: template.name, startedAt: now, exercises: logs)
        return ActiveWorkout(
            session: session,
            focus: logs.isEmpty ? nil : SetPosition(exercise: 0, set: 0),
            previousBests: bests(from: history)
        )
    }

    /// An empty session for ad-hoc training.
    public static func empty(name: String = "Workout", history: [WorkoutSession], now: Date = Date()) -> ActiveWorkout {
        ActiveWorkout(session: WorkoutSession(name: name, startedAt: now, exercises: []), focus: nil,
                      previousBests: bests(from: history))
    }

    static func bests(from history: [WorkoutSession]) -> [String: PreviousBest] {
        var result: [String: PreviousBest] = [:]
        for session in history where session.isFinished {
            for log in session.exercises {
                guard let top = log.heaviestSet else { continue }
                if let current = result[log.exerciseID],
                   current.weight > top.weight || (current.weight == top.weight && current.reps >= top.reps) {
                    continue
                }
                result[log.exerciseID] = PreviousBest(weight: top.weight, reps: top.reps)
            }
        }
        return result
    }

    // MARK: Derived

    public var exercises: [ExerciseLog] { session.exercises }

    public var currentExerciseIndex: Int {
        focus?.exercise ?? session.exercises.firstIndex { !$0.isComplete } ?? max(session.exercises.count - 1, 0)
    }

    public var completedSets: Int { session.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count } }
    public var totalSets: Int { session.exercises.reduce(0) { $0 + $1.sets.count } }
    public var progress: Double { totalSets == 0 ? 0 : Double(completedSets) / Double(totalSets) }
    public var isComplete: Bool { !session.exercises.isEmpty && session.exercises.allSatisfy(\.isComplete) }

    func isValid(_ position: SetPosition) -> Bool {
        session.exercises.indices.contains(position.exercise)
            && session.exercises[position.exercise].sets.indices.contains(position.set)
    }

    /// The next incomplete set after `position`, preferring the same exercise.
    func nextIncomplete(after position: SetPosition) -> SetPosition? {
        let exercises = session.exercises
        let current = exercises[position.exercise]
        if let set = current.sets.indices.first(where: { $0 > position.set && !current.sets[$0].isCompleted })
            ?? current.sets.indices.first(where: { !current.sets[$0].isCompleted }) {
            return SetPosition(exercise: position.exercise, set: set)
        }
        let order = Array(exercises.indices.dropFirst(position.exercise + 1)) + Array(exercises.indices.prefix(position.exercise))
        for index in order {
            if let set = exercises[index].sets.firstIndex(where: { !$0.isCompleted }) {
                return SetPosition(exercise: index, set: set)
            }
        }
        return nil
    }

    // MARK: Mutations

    @discardableResult
    public mutating func complete(_ position: SetPosition, now: Date = Date()) -> SetCompletion? {
        guard isValid(position) else { return nil }
        var set = session.exercises[position.exercise].sets[position.set]
        guard !set.isCompleted else { return nil }
        set.isCompleted = true
        set.completedAt = now
        session.exercises[position.exercise].sets[position.set] = set

        let exerciseID = session.exercises[position.exercise].exerciseID
        var isPR = false
        if set.kind != .warmup, set.reps > 0, set.weight > 0 || previousBests[exerciseID] != nil {
            if let best = previousBests[exerciseID] {
                isPR = set.weight > best.weight || (set.weight == best.weight && set.reps > best.reps)
            }
            if isPR || previousBests[exerciseID] == nil {
                previousBests[exerciseID] = PreviousBest(weight: set.weight, reps: set.reps)
            }
        }

        let next = nextIncomplete(after: position)
        focus = next
        let log = session.exercises[position.exercise]
        return SetCompletion(
            position: position,
            restSeconds: log.restSeconds,
            nextFocus: next,
            finishedExercise: log.isComplete,
            finishedWorkout: next == nil,
            isPersonalRecord: isPR
        )
    }

    public mutating func uncomplete(_ position: SetPosition) {
        guard isValid(position) else { return }
        session.exercises[position.exercise].sets[position.set].isCompleted = false
        session.exercises[position.exercise].sets[position.set].completedAt = nil
        focus = position
    }

    /// Changing the load of a set also updates later, untouched sets that
    /// shared the old load, matching how lifters actually adjust mid-exercise.
    public mutating func setWeight(_ weight: Double, at position: SetPosition) {
        guard isValid(position) else { return }
        let clamped = max(0, min(weight, 1000))
        let old = session.exercises[position.exercise].sets[position.set].weight
        session.exercises[position.exercise].sets[position.set].weight = clamped
        for index in session.exercises[position.exercise].sets.indices where index > position.set {
            let set = session.exercises[position.exercise].sets[index]
            if !set.isCompleted, set.weight == old {
                session.exercises[position.exercise].sets[index].weight = clamped
            }
        }
    }

    public mutating func setReps(_ reps: Int, at position: SetPosition) {
        guard isValid(position) else { return }
        session.exercises[position.exercise].sets[position.set].reps = max(0, min(reps, 999))
    }

    public mutating func addSet(toExercise index: Int) {
        guard session.exercises.indices.contains(index) else { return }
        let template = session.exercises[index].sets.last
        session.exercises[index].sets.append(SetLog(
            weight: template?.weight ?? 0,
            reps: template?.reps ?? session.exercises[index].repRange.upper,
            targetReps: template?.targetReps,
            targetWeight: template?.targetWeight
        ))
        if focus == nil { focus = SetPosition(exercise: index, set: session.exercises[index].sets.count - 1) }
    }

    public mutating func removeSet(_ position: SetPosition) {
        guard isValid(position), session.exercises[position.exercise].sets.count > 1 else { return }
        session.exercises[position.exercise].sets.remove(at: position.set)
        guard let focus, focus.exercise == position.exercise else { return }
        if focus.set > position.set {
            self.focus = SetPosition(exercise: focus.exercise, set: focus.set - 1)
        } else if focus.set == position.set {
            let anchor = SetPosition(exercise: position.exercise, set: min(position.set, session.exercises[position.exercise].sets.count - 1))
            self.focus = session.exercises[anchor.exercise].sets[anchor.set].isCompleted ? nextIncomplete(after: anchor) : anchor
        }
    }

    public mutating func toggleWarmup(_ position: SetPosition) {
        guard isValid(position) else { return }
        let kind = session.exercises[position.exercise].sets[position.set].kind
        session.exercises[position.exercise].sets[position.set].kind = kind == .warmup ? .working : .warmup
    }

    public mutating func addExercise(_ exercise: Exercise, sets: Int = 3, repRange: RepRange = RepRange(8, 12),
                                     recommendation: ProgressionRecommendation? = nil) {
        let weight = recommendation?.weight ?? 0
        let reps = recommendation?.reps ?? repRange.upper
        let log = ExerciseLog(
            exerciseID: exercise.id,
            sets: (0..<max(sets, 1)).map { _ in SetLog(weight: weight, reps: reps, targetReps: reps, targetWeight: recommendation?.weight) },
            repRange: repRange,
            restSeconds: exercise.defaultRestSeconds
        )
        session.exercises.append(log)
        if focus == nil { focus = SetPosition(exercise: session.exercises.count - 1, set: 0) }
    }

    /// Swaps an exercise in place. Completed sets are kept only if the
    /// replacement is the same exercise; otherwise the slot restarts with the
    /// replacement's recommendation.
    public mutating func replaceExercise(at index: Int, with exercise: Exercise, recommendation: ProgressionRecommendation?) {
        guard session.exercises.indices.contains(index) else { return }
        let old = session.exercises[index]
        let weight = recommendation?.weight ?? 0
        let reps = recommendation?.reps ?? old.repRange.upper
        session.exercises[index] = ExerciseLog(
            exerciseID: exercise.id,
            sets: old.sets.map { _ in SetLog(weight: weight, reps: reps, targetReps: reps, targetWeight: recommendation?.weight) },
            repRange: old.repRange,
            restSeconds: exercise.defaultRestSeconds
        )
        if focus?.exercise == index { focus = SetPosition(exercise: index, set: 0) }
    }

    public mutating func removeExercise(at index: Int) {
        guard session.exercises.indices.contains(index) else { return }
        session.exercises.remove(at: index)
        if session.exercises.isEmpty {
            focus = nil
        } else if let focus {
            if focus.exercise == index {
                self.focus = nextIncomplete(after: SetPosition(exercise: min(index, session.exercises.count - 1), set: 0))
            } else if focus.exercise > index {
                self.focus = SetPosition(exercise: focus.exercise - 1, set: focus.set)
            }
        }
    }

    public mutating func moveExercise(from source: Int, to destination: Int) {
        guard session.exercises.indices.contains(source), session.exercises.indices.contains(destination) else { return }
        let item = session.exercises.remove(at: source)
        session.exercises.insert(item, at: destination)
        let exercises = session.exercises
        focus = exercises.indices.lazy.compactMap { index in
            exercises[index].sets.firstIndex { !$0.isCompleted }.map { SetPosition(exercise: index, set: $0) }
        }.first
    }

    public mutating func setRest(_ seconds: Int, forExercise index: Int) {
        guard session.exercises.indices.contains(index) else { return }
        session.exercises[index].restSeconds = max(0, min(seconds, 600))
    }

    /// The session to save: only completed sets survive, and exercises with
    /// nothing completed are dropped.
    public func finished(at date: Date = Date()) -> WorkoutSession {
        var result = session
        result.endedAt = date
        result.exercises = session.exercises.compactMap { log in
            var log = log
            log.sets = log.sets.filter(\.isCompleted)
            return log.sets.isEmpty ? nil : log
        }
        return result
    }
}
