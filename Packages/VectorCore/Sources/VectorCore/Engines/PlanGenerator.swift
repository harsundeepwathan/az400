import Foundation

public struct OnboardingAnswers: Codable, Hashable, Sendable {
    public var name: String
    public var goal: TrainingGoal
    public var experience: ExperienceLevel
    public var daysPerWeek: Int
    public var equipment: EquipmentAccess
    public var nutritionGoal: NutritionGoal
    public var sex: BiologicalSex
    public var age: Int
    public var heightCm: Double
    public var weightKg: Double
    public var targetWeightKg: Double
    public var unit: WeightUnit
    public var dietaryPreferences: Set<DietaryPreference>

    public init(
        name: String = "",
        goal: TrainingGoal = .buildMuscle,
        experience: ExperienceLevel = .intermediate,
        daysPerWeek: Int = 4,
        equipment: EquipmentAccess = .fullGym,
        nutritionGoal: NutritionGoal = .maintain,
        sex: BiologicalSex = .unspecified,
        age: Int = 30,
        heightCm: Double = 175,
        weightKg: Double = 75,
        targetWeightKg: Double = 75,
        unit: WeightUnit = .kilograms,
        dietaryPreferences: Set<DietaryPreference> = []
    ) {
        self.name = name
        self.goal = goal
        self.experience = experience
        self.daysPerWeek = daysPerWeek
        self.equipment = equipment
        self.nutritionGoal = nutritionGoal
        self.sex = sex
        self.age = age
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.targetWeightKg = targetWeightKg
        self.unit = unit
        self.dietaryPreferences = dietaryPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case name, goal, experience, daysPerWeek, equipment, nutritionGoal, sex, age, heightCm, weightKg, targetWeightKg, unit, dietaryPreferences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            goal: try c.decode(TrainingGoal.self, forKey: .goal),
            experience: try c.decode(ExperienceLevel.self, forKey: .experience),
            daysPerWeek: try c.decode(Int.self, forKey: .daysPerWeek),
            equipment: try c.decode(EquipmentAccess.self, forKey: .equipment),
            nutritionGoal: try c.decode(NutritionGoal.self, forKey: .nutritionGoal),
            sex: try c.decode(BiologicalSex.self, forKey: .sex),
            age: try c.decode(Int.self, forKey: .age),
            heightCm: try c.decode(Double.self, forKey: .heightCm),
            weightKg: try c.decode(Double.self, forKey: .weightKg),
            targetWeightKg: try c.decode(Double.self, forKey: .targetWeightKg),
            unit: try c.decode(WeightUnit.self, forKey: .unit),
            dietaryPreferences: try c.decodeIfPresent(Set<DietaryPreference>.self, forKey: .dietaryPreferences) ?? []
        )
    }
}

public struct GeneratedPlan: Hashable, Sendable {
    public var program: TrainingProgram
    public var targets: NutritionTargets
    /// Plain-language reasons shown on the "Your plan is ready" screen.
    public var rationale: [String]
    public var profile: UserProfile
}

public struct PlanGenerator: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
    }

    enum Role { case primary, secondary, accessory }

    struct Slot {
        var role: Role
        var candidates: [String]
        init(_ role: Role, _ candidates: [String]) {
            self.role = role
            self.candidates = candidates
        }
    }

    struct Day {
        var name: String
        var slots: [Slot]
    }

    public func generate(from answers: OnboardingAnswers, now: Date = Date()) -> GeneratedPlan {
        let days = min(max(answers.daysPerWeek, 2), 6)
        let (programName, layout) = Self.layout(days: days)
        let available = answers.equipment.available
        let workouts = layout.map { day in
            WorkoutTemplate(name: day.name, exercises: build(day, available: available, answers: answers))
        }
        let program = TrainingProgram(name: programName, daysPerWeek: days, workouts: workouts)

        let targets = NutritionEngine.targets(
            sex: answers.sex,
            weightKg: answers.weightKg,
            heightCm: answers.heightCm,
            age: answers.age,
            trainingDays: days,
            goal: answers.nutritionGoal,
            proteinPerKg: answers.goal.proteinPerKg
        )

        var rationale = [
            "\(programName) fits \(days) sessions a week with each muscle trained about twice.",
            "Rep ranges are tuned for \(answers.goal.title.lowercased())."
        ]
        if answers.equipment != .fullGym {
            rationale.append("Exercises are matched to \(answers.equipment.title.lowercased()).")
        }
        rationale.append("Protein is set at \(Format.integer(targets.protein)) g, about \(Format.number1(targets.protein / answers.weightKg)) g per kg of body weight.")

        let profile = UserProfile(
            name: answers.name.trimmingCharacters(in: .whitespaces),
            goal: answers.goal,
            experience: answers.experience,
            daysPerWeek: days,
            equipment: answers.equipment,
            nutritionGoal: answers.nutritionGoal,
            sex: answers.sex,
            birthYear: calendar.component(.year, from: now) - answers.age,
            heightCm: answers.heightCm,
            weightKg: answers.weightKg,
            targetWeightKg: answers.targetWeightKg,
            unit: answers.unit,
            targets: targets,
            dietaryPreferences: answers.dietaryPreferences
        )
        return GeneratedPlan(program: program, targets: targets, rationale: rationale, profile: profile)
    }

    private func build(_ day: Day, available: Set<Equipment>, answers: OnboardingAnswers) -> [ExercisePrescription] {
        var used = Set<String>()
        return day.slots.compactMap { slot in
            guard let id = slot.candidates.first(where: { id in
                guard let exercise = catalog[id] else { return false }
                return available.contains(exercise.equipment) && !used.contains(id)
            }) else { return nil }
            used.insert(id)
            let exercise = catalog[id]!
            let (sets, reps) = Self.prescription(role: slot.role, goal: answers.goal, experience: answers.experience,
                                                 bodyweight: exercise.isBodyweight && exercise.loadIncrement == 0)
            return ExercisePrescription(exerciseID: id, sets: sets, repRange: reps)
        }
    }

    static func prescription(role: Role, goal: TrainingGoal, experience: ExperienceLevel, bodyweight: Bool) -> (Int, RepRange) {
        let primarySets = experience == .advanced ? 4 : 3
        if bodyweight {
            return (role == .primary ? primarySets : 3, RepRange(10, 20))
        }
        switch (goal, role) {
        case (.getStronger, .primary): return (primarySets, .fixed(5))
        case (.getStronger, .secondary): return (3, RepRange(6, 8))
        case (.getStronger, .accessory): return (3, RepRange(8, 12))
        case (.loseFat, .primary): return (primarySets, RepRange(5, 8))
        case (.improveFitness, .primary): return (3, RepRange(8, 12))
        case (.improveFitness, _): return (3, RepRange(12, 15))
        case (_, .primary): return (primarySets, .fixed(8))
        case (_, .secondary): return (3, RepRange(8, 10))
        case (_, .accessory): return (3, RepRange(10, 12))
        }
    }

    // MARK: Layouts

    private static let squat = ["back-squat", "hack-squat", "goblet-squat", "bulgarian-split-squat", "bodyweight-squat"]
    private static let squatB = ["front-squat", "hack-squat", "leg-press", "goblet-squat", "bodyweight-squat"]
    private static let hinge = ["romanian-deadlift", "db-romanian-deadlift", "kb-swing", "glute-bridge"]
    private static let deadlift = ["deadlift", "romanian-deadlift", "db-romanian-deadlift", "kb-swing", "glute-bridge"]
    private static let singleLeg = ["leg-press", "bulgarian-split-squat", "walking-lunge", "reverse-lunge"]
    private static let lunge = ["walking-lunge", "bulgarian-split-squat", "reverse-lunge"]
    private static let hamCurl = ["leg-curl", "nordic-curl", "db-romanian-deadlift", "glute-bridge"]
    private static let glute = ["hip-thrust", "glute-bridge"]
    private static let quadIso = ["leg-extension", "goblet-squat", "reverse-lunge"]
    private static let calf = ["standing-calf-raise", "single-leg-calf-raise"]
    private static let core = ["hanging-leg-raise", "cable-crunch", "plank"]
    private static let press = ["bench-press", "db-bench-press", "machine-chest-press", "push-up"]
    private static let incline = ["incline-db-press", "db-bench-press", "machine-chest-press", "push-up"]
    private static let row = ["barbell-row", "chest-supported-row", "seated-cable-row", "inverted-row", "band-row"]
    private static let rowB = ["seated-cable-row", "chest-supported-row", "inverted-row", "band-row"]
    private static let overhead = ["overhead-press", "db-shoulder-press", "pike-push-up"]
    private static let overheadB = ["db-shoulder-press", "overhead-press", "pike-push-up"]
    private static let vertical = ["lat-pulldown", "pull-up", "band-pulldown"]
    private static let verticalB = ["pull-up", "lat-pulldown", "band-pulldown"]
    private static let lateral = ["lateral-raise", "cable-lateral-raise"]
    private static let rearDelt = ["face-pull", "lateral-raise", "band-row"]
    private static let fly = ["cable-fly", "push-up"]
    private static let curl = ["ez-bar-curl", "db-curl", "cable-curl", "band-curl"]
    private static let curlB = ["db-curl", "cable-curl", "band-curl"]
    private static let triceps = ["triceps-pushdown", "overhead-triceps-extension", "diamond-push-up"]
    private static let tricepsB = ["overhead-triceps-extension", "triceps-pushdown", "diamond-push-up"]

    static func layout(days: Int) -> (String, [Day]) {
        let lowerA = Day(name: "Lower A", slots: [Slot(.primary, squat), Slot(.secondary, hinge), Slot(.accessory, singleLeg),
                                                  Slot(.accessory, hamCurl), Slot(.accessory, calf), Slot(.accessory, core)])
        let upperA = Day(name: "Upper A", slots: [Slot(.primary, press), Slot(.secondary, row), Slot(.secondary, overhead),
                                                  Slot(.accessory, vertical), Slot(.accessory, lateral), Slot(.accessory, curl),
                                                  Slot(.accessory, triceps)])
        let lowerB = Day(name: "Lower B", slots: [Slot(.primary, deadlift), Slot(.secondary, squatB), Slot(.accessory, glute),
                                                  Slot(.accessory, lunge), Slot(.accessory, quadIso), Slot(.accessory, calf)])
        let upperB = Day(name: "Upper B", slots: [Slot(.primary, incline), Slot(.secondary, verticalB), Slot(.secondary, rowB),
                                                  Slot(.accessory, overheadB), Slot(.accessory, fly), Slot(.accessory, rearDelt),
                                                  Slot(.accessory, tricepsB)])
        let fullA = Day(name: "Full Body A", slots: [Slot(.primary, squat), Slot(.primary, press), Slot(.secondary, row),
                                                     Slot(.accessory, hamCurl), Slot(.accessory, lateral), Slot(.accessory, core)])
        let fullB = Day(name: "Full Body B", slots: [Slot(.primary, deadlift), Slot(.secondary, overhead), Slot(.secondary, vertical),
                                                     Slot(.accessory, lunge), Slot(.accessory, curl), Slot(.accessory, triceps)])
        let fullC = Day(name: "Full Body C", slots: [Slot(.primary, squatB), Slot(.primary, incline), Slot(.secondary, rowB),
                                                     Slot(.accessory, glute), Slot(.accessory, rearDelt), Slot(.accessory, calf)])
        let push = Day(name: "Push", slots: [Slot(.primary, press), Slot(.secondary, overhead), Slot(.accessory, incline),
                                             Slot(.accessory, lateral), Slot(.accessory, fly), Slot(.accessory, triceps)])
        let pull = Day(name: "Pull", slots: [Slot(.primary, row), Slot(.secondary, verticalB), Slot(.accessory, rowB),
                                             Slot(.accessory, rearDelt), Slot(.accessory, curl), Slot(.accessory, curlB)])
        let legs = Day(name: "Legs", slots: [Slot(.primary, squat), Slot(.secondary, hinge), Slot(.accessory, singleLeg),
                                             Slot(.accessory, hamCurl), Slot(.accessory, calf), Slot(.accessory, core)])

        switch days {
        case 2: return ("Full Body — 2 Days", [fullA, fullB])
        case 3: return ("Full Body — 3 Days", [fullA, fullB, fullC])
        case 4: return ("Upper / Lower — 4 Days", [lowerA, upperA, lowerB, upperB])
        case 5: return ("Push / Pull / Legs + Upper / Lower", [push, pull, legs, upperB, lowerB])
        default:
            var pushB = push; pushB.name = "Push B"
            var pullB = pull; pullB.name = "Pull B"
            var legsB = lowerB; legsB.name = "Legs B"
            var pushA = push; pushA.name = "Push A"
            var pullA = pull; pullA.name = "Pull A"
            var legsA = legs; legsA.name = "Legs A"
            return ("Push / Pull / Legs — 6 Days", [pushA, pullA, legsA, pushB, pullB, legsB])
        }
    }
}

extension Format {
    static func number1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
