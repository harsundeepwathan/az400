import Foundation

// MARK: - Taxonomy

public enum MuscleGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case chest, back, shoulders, biceps, triceps, forearms, quads, hamstrings, glutes, calves, core

    public var displayName: String {
        switch self {
        case .chest: "Chest"
        case .back: "Back"
        case .shoulders: "Shoulders"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .glutes: "Glutes"
        case .calves: "Calves"
        case .core: "Core"
        }
    }

    /// Muscles surfaced in the weekly-sets analytics, in display order.
    public static let analyticsOrder: [MuscleGroup] = [
        .chest, .back, .shoulders, .quads, .hamstrings, .glutes, .biceps, .triceps
    ]

    public var isLowerBody: Bool { [.quads, .hamstrings, .glutes, .calves].contains(self) }

    /// Movement pattern assumed for a compound custom exercise.
    public var defaultPattern: MovementPattern {
        switch self {
        case .chest, .triceps: .horizontalPush
        case .back, .biceps, .forearms: .horizontalPull
        case .shoulders: .verticalPush
        case .quads, .calves: .squat
        case .hamstrings, .glutes: .hinge
        case .core: .core
        }
    }
}

public enum Equipment: String, Codable, CaseIterable, Hashable, Sendable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, other

    public var displayName: String { rawValue.capitalized }
}

public enum MovementPattern: String, Codable, CaseIterable, Hashable, Sendable {
    case squat, hinge, lunge, horizontalPush, verticalPush, horizontalPull, verticalPull
    case elbowFlexion, elbowExtension, isolationLower, isolationUpper, core

    public var displayName: String {
        switch self {
        case .squat: "Squat"
        case .hinge: "Hinge"
        case .lunge: "Lunge"
        case .horizontalPush: "Horizontal push"
        case .verticalPush: "Vertical push"
        case .horizontalPull: "Horizontal pull"
        case .verticalPull: "Vertical pull"
        case .elbowFlexion: "Elbow flexion"
        case .elbowExtension: "Elbow extension"
        case .isolationLower: "Lower isolation"
        case .isolationUpper: "Upper isolation"
        case .core: "Core"
        }
    }
}

// MARK: - Exercise

public struct Exercise: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var primaryMuscles: [MuscleGroup]
    public var secondaryMuscles: [MuscleGroup]
    public var equipment: Equipment
    public var pattern: MovementPattern
    public var instructions: [String]
    /// Default rest between working sets, in seconds.
    public var defaultRestSeconds: Int
    /// Smallest sensible load jump in kg (2.5 for barbell lifts, 2 for dumbbells, ...).
    public var loadIncrement: Double
    public var isCompound: Bool
    /// SF Symbol used as a lightweight illustration fallback.
    public var symbol: String
    /// Demonstration frames (start and end position), relative to `Exercise.imageBaseURL`.
    public var images: [String]
    public var level: String?

    /// Public-domain demonstration photos from free-exercise-db.
    public static let imageBaseURL = URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/")!

    public var imageURLs: [URL] { images.compactMap { URL(string: $0, relativeTo: Self.imageBaseURL)?.absoluteURL } }

    public init(
        id: String,
        name: String,
        primaryMuscles: [MuscleGroup],
        secondaryMuscles: [MuscleGroup] = [],
        equipment: Equipment,
        pattern: MovementPattern,
        instructions: [String] = [],
        defaultRestSeconds: Int = 120,
        loadIncrement: Double = 2.5,
        isCompound: Bool = true,
        symbol: String = "figure.strengthtraining.traditional",
        images: [String] = [],
        level: String? = nil
    ) {
        self.id = id
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.pattern = pattern
        self.instructions = instructions
        self.defaultRestSeconds = defaultRestSeconds
        self.loadIncrement = loadIncrement
        self.isCompound = isCompound
        self.symbol = symbol
        self.images = images
        self.level = level
    }

    public var isBodyweight: Bool { equipment == .bodyweight }
}

// MARK: - Templates & programs

public struct RepRange: Codable, Hashable, Sendable {
    public var lower: Int
    public var upper: Int

    public init(_ lower: Int, _ upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public static func fixed(_ reps: Int) -> RepRange { RepRange(reps, reps) }

    public var isFixed: Bool { lower == upper }

    public var label: String { isFixed ? "\(upper)" : "\(lower)–\(upper)" }
}

public struct ExercisePrescription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var exerciseID: String
    public var sets: Int
    public var repRange: RepRange
    /// Overrides `Exercise.defaultRestSeconds` when set.
    public var restSeconds: Int?

    public init(id: UUID = UUID(), exerciseID: String, sets: Int, repRange: RepRange, restSeconds: Int? = nil) {
        self.id = id
        self.exerciseID = exerciseID
        self.sets = sets
        self.repRange = repRange
        self.restSeconds = restSeconds
    }
}

public struct WorkoutTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var exercises: [ExercisePrescription]

    public init(id: UUID = UUID(), name: String, exercises: [ExercisePrescription]) {
        self.id = id
        self.name = name
        self.exercises = exercises
    }

    public var totalSets: Int { exercises.reduce(0) { $0 + $1.sets } }

    /// Rough duration: ~45 s per working set plus the prescribed rest,
    /// plus 5 minutes of set-up / warm-up. Rounded to the nearest minute.
    public func estimatedMinutes(catalog: ExerciseCatalog) -> Int {
        let seconds = exercises.reduce(300) { total, item in
            let rest = item.restSeconds ?? catalog[item.exerciseID]?.defaultRestSeconds ?? 120
            return total + item.sets * 45 + max(item.sets - 1, 0) * rest
        }
        return Int((Double(seconds) / 60).rounded())
    }

    /// Distinct primary muscles in prescription order, most-trained first.
    public func primaryMuscles(catalog: ExerciseCatalog) -> [MuscleGroup] {
        var counts: [MuscleGroup: Int] = [:]
        var order: [MuscleGroup] = []
        for item in exercises {
            for muscle in catalog[item.exerciseID]?.primaryMuscles ?? [] {
                if counts[muscle] == nil { order.append(muscle) }
                counts[muscle, default: 0] += item.sets
            }
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }
}

public struct TrainingProgram: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var daysPerWeek: Int
    public var workouts: [WorkoutTemplate]
    /// Index into `workouts` of the next session in the rotation.
    public var nextIndex: Int

    public init(id: UUID = UUID(), name: String, daysPerWeek: Int, workouts: [WorkoutTemplate], nextIndex: Int = 0) {
        self.id = id
        self.name = name
        self.daysPerWeek = daysPerWeek
        self.workouts = workouts
        self.nextIndex = nextIndex
    }

    public var subtitle: String { "\(daysPerWeek) days / week" }

    public var nextWorkout: WorkoutTemplate? {
        guard !workouts.isEmpty else { return nil }
        return workouts[nextIndex % workouts.count]
    }

    /// Workouts in rotation order starting from the next one.
    public var upcoming: [WorkoutTemplate] {
        guard !workouts.isEmpty else { return [] }
        return (0..<workouts.count).map { workouts[(nextIndex + $0) % workouts.count] }
    }

    public mutating func advance(past templateID: UUID) {
        guard let index = workouts.firstIndex(where: { $0.id == templateID }) else { return }
        nextIndex = (index + 1) % max(workouts.count, 1)
    }
}

// MARK: - Logged training

public enum SetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case warmup, working, drop, failure

    public var title: String {
        switch self {
        case .warmup: "Warm-up"
        case .working: "Working"
        case .drop: "Drop set"
        case .failure: "To failure"
        }
    }

    /// One-letter badge shown in place of the set number.
    public var badge: String? {
        switch self {
        case .warmup: "W"
        case .working: nil
        case .drop: "D"
        case .failure: "F"
        }
    }
}

public struct SetLog: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: SetKind
    /// Load in kilograms. Bodyweight movements store added load (0 for none).
    public var weight: Double
    public var reps: Int
    public var isCompleted: Bool
    public var completedAt: Date?
    /// Target the athlete was aiming for, used by the progression engine
    /// to judge success / failure.
    public var targetReps: Int?
    public var targetWeight: Double?
    /// Rate of perceived exertion, 6–10 in half steps. Nil when not logged.
    public var rpe: Double?

    public init(
        id: UUID = UUID(),
        kind: SetKind = .working,
        weight: Double,
        reps: Int,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        targetReps: Int? = nil,
        targetWeight: Double? = nil,
        rpe: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.weight = weight
        self.reps = reps
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.targetReps = targetReps
        self.targetWeight = targetWeight
        self.rpe = rpe
    }

    /// Reps in reserve implied by RPE (RPE 8 ≈ 2 reps left).
    public var rir: Int? { rpe.map { max(Int((10 - $0).rounded()), 0) } }

    public var volume: Double { weight * Double(reps) }
    public var countsTowardVolume: Bool { isCompleted && kind != .warmup }
}

public struct ExerciseLog: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var exerciseID: String
    public var sets: [SetLog]
    public var repRange: RepRange
    public var restSeconds: Int
    public var note: String
    /// Exercises sharing a group number are performed as a superset.
    public var supersetGroup: Int?

    public init(
        id: UUID = UUID(),
        exerciseID: String,
        sets: [SetLog],
        repRange: RepRange,
        restSeconds: Int,
        note: String = "",
        supersetGroup: Int? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.sets = sets
        self.repRange = repRange
        self.restSeconds = restSeconds
        self.note = note
        self.supersetGroup = supersetGroup
    }

    public var completedWorkingSets: [SetLog] { sets.filter(\.countsTowardVolume) }
    public var volume: Double { completedWorkingSets.reduce(0) { $0 + $1.volume } }
    public var isComplete: Bool { !sets.isEmpty && sets.allSatisfy(\.isCompleted) }

    /// Best estimated one-rep max across completed working sets.
    public var bestEstimatedOneRepMax: Double {
        completedWorkingSets.map { OneRepMax.estimate(weight: $0.weight, reps: $0.reps) }.max() ?? 0
    }

    public var heaviestSet: SetLog? {
        completedWorkingSets.max { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.reps < rhs.reps : lhs.weight < rhs.weight
        }
    }
}

public struct WorkoutSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var templateID: UUID?
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exercises: [ExerciseLog]

    public init(
        id: UUID = UUID(),
        templateID: UUID? = nil,
        name: String,
        startedAt: Date,
        endedAt: Date? = nil,
        exercises: [ExerciseLog]
    ) {
        self.id = id
        self.templateID = templateID
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exercises = exercises
    }

    public var isFinished: Bool { endedAt != nil }
    public var volume: Double { exercises.reduce(0) { $0 + $1.volume } }
    public var completedSetCount: Int { exercises.reduce(0) { $0 + $1.completedWorkingSets.count } }
    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    public func log(for exerciseID: String) -> ExerciseLog? {
        exercises.first { $0.exerciseID == exerciseID }
    }
}

public struct BodyWeightEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var kilograms: Double

    public init(id: UUID = UUID(), date: Date, kilograms: Double) {
        self.id = id
        self.date = date
        self.kilograms = kilograms
    }
}
