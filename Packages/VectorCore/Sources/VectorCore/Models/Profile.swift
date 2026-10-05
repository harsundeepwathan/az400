import Foundation

public enum TrainingGoal: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case buildMuscle, loseFat, getStronger, improveFitness

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buildMuscle: "Build muscle"
        case .loseFat: "Lose fat"
        case .getStronger: "Get stronger"
        case .improveFitness: "Improve fitness"
        }
    }

    public var detail: String {
        switch self {
        case .buildMuscle: "Hypertrophy-focused volume with a small surplus"
        case .loseFat: "Keep your strength while in a calorie deficit"
        case .getStronger: "Heavier compound lifts, lower rep ranges"
        case .improveFitness: "Balanced training and sustainable habits"
        }
    }

    public var symbol: String {
        switch self {
        case .buildMuscle: "figure.strengthtraining.traditional"
        case .loseFat: "flame"
        case .getStronger: "scalemass"
        case .improveFitness: "heart.text.square"
        }
    }
}

public enum ExperienceLevel: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case beginner, intermediate, advanced

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var detail: String {
        switch self {
        case .beginner: "Less than 1 year of consistent lifting"
        case .intermediate: "1–3 years, comfortable with the main lifts"
        case .advanced: "3+ years, progress now takes planning"
        }
    }
}

public enum EquipmentAccess: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case fullGym, homeGym, dumbbells, bodyweight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullGym: "Full gym"
        case .homeGym: "Home gym"
        case .dumbbells: "Dumbbells only"
        case .bodyweight: "Bodyweight"
        }
    }

    public var detail: String {
        switch self {
        case .fullGym: "Barbells, machines, cables"
        case .homeGym: "Rack, barbell, bench, dumbbells"
        case .dumbbells: "Adjustable or fixed dumbbells"
        case .bodyweight: "No equipment needed"
        }
    }

    public var symbol: String {
        switch self {
        case .fullGym: "building.2"
        case .homeGym: "house"
        case .dumbbells: "dumbbell"
        case .bodyweight: "figure.core.training"
        }
    }

    public var available: Set<Equipment> {
        switch self {
        case .fullGym: Set(Equipment.allCases)
        case .homeGym: [.barbell, .dumbbell, .bodyweight, .band, .kettlebell]
        case .dumbbells: [.dumbbell, .bodyweight, .band]
        case .bodyweight: [.bodyweight, .band]
        }
    }
}

public enum NutritionGoal: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case lose, maintain, gain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lose: "Lose weight"
        case .maintain: "Maintain"
        case .gain: "Gain weight"
        }
    }

    public var detail: String {
        switch self {
        case .lose: "About 0.5% of body weight per week"
        case .maintain: "Recomposition at maintenance calories"
        case .gain: "Lean gain, about 0.25% per week"
        }
    }

    /// Daily calorie adjustment vs. maintenance.
    public var calorieAdjustment: Double {
        switch self {
        case .lose: -500
        case .maintain: 0
        case .gain: 250
        }
    }
}

public enum BiologicalSex: String, Codable, CaseIterable, Hashable, Sendable {
    case male, female, unspecified
}

public enum WeightUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case kilograms, pounds

    public var symbol: String { self == .kilograms ? "kg" : "lb" }
    public static let poundsPerKilogram = 2.2046226218

    public func fromKilograms(_ kg: Double) -> Double { self == .kilograms ? kg : kg * Self.poundsPerKilogram }
    public func toKilograms(_ value: Double) -> Double { self == .kilograms ? value : value / Self.poundsPerKilogram }
}

public struct UserProfile: Codable, Hashable, Sendable {
    public var name: String
    public var goal: TrainingGoal
    public var experience: ExperienceLevel
    public var daysPerWeek: Int
    public var equipment: EquipmentAccess
    public var nutritionGoal: NutritionGoal
    public var sex: BiologicalSex
    public var birthYear: Int
    public var heightCm: Double
    public var weightKg: Double
    public var targetWeightKg: Double
    public var unit: WeightUnit
    public var targets: NutritionTargets
    /// Exercise ids the athlete wants to avoid (injury / preference).
    public var avoidedExerciseIDs: Set<String>
    public var restTimerNotifications: Bool

    public init(
        name: String,
        goal: TrainingGoal,
        experience: ExperienceLevel,
        daysPerWeek: Int,
        equipment: EquipmentAccess,
        nutritionGoal: NutritionGoal,
        sex: BiologicalSex = .unspecified,
        birthYear: Int = 1995,
        heightCm: Double,
        weightKg: Double,
        targetWeightKg: Double,
        unit: WeightUnit = .kilograms,
        targets: NutritionTargets,
        avoidedExerciseIDs: Set<String> = [],
        restTimerNotifications: Bool = true
    ) {
        self.name = name
        self.goal = goal
        self.experience = experience
        self.daysPerWeek = daysPerWeek
        self.equipment = equipment
        self.nutritionGoal = nutritionGoal
        self.sex = sex
        self.birthYear = birthYear
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.targetWeightKg = targetWeightKg
        self.unit = unit
        self.targets = targets
        self.avoidedExerciseIDs = avoidedExerciseIDs
        self.restTimerNotifications = restTimerNotifications
    }
}
