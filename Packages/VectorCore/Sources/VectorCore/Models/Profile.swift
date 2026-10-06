import Foundation

public enum TrainingGoal: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// `improveFitness` is kept so profiles saved by earlier builds still decode;
    /// it's no longer offered in onboarding.
    case buildMuscle, loseFat, getStronger, maintain, recomposition, improveFitness

    public var id: String { rawValue }

    /// Goals offered in onboarding and settings.
    public static let selectable: [TrainingGoal] = [.buildMuscle, .loseFat, .getStronger, .maintain, .recomposition]

    public var title: String {
        switch self {
        case .buildMuscle: "Build muscle"
        case .loseFat: "Lose fat"
        case .getStronger: "Gain strength"
        case .maintain: "Maintain"
        case .recomposition: "Recomposition"
        case .improveFitness: "Improve fitness"
        }
    }

    public var detail: String {
        switch self {
        case .buildMuscle: "Hypertrophy-focused volume with a small surplus"
        case .loseFat: "Keep your strength while in a calorie deficit"
        case .getStronger: "Heavier compound lifts, lower rep ranges"
        case .maintain: "Hold your weight and keep training consistent"
        case .recomposition: "Lose fat and build muscle at maintenance calories"
        case .improveFitness: "Balanced training and sustainable habits"
        }
    }

    public var symbol: String {
        switch self {
        case .buildMuscle: "figure.strengthtraining.traditional"
        case .loseFat: "flame"
        case .getStronger: "scalemass"
        case .maintain: "equal.circle"
        case .recomposition: "arrow.triangle.2.circlepath"
        case .improveFitness: "heart.text.square"
        }
    }

    /// Calorie direction implied by the goal.
    public var nutritionGoal: NutritionGoal {
        switch self {
        case .buildMuscle: .gain
        case .loseFat: .lose
        case .getStronger, .maintain, .recomposition, .improveFitness: .maintain
        }
    }

    /// Target body-weight change per week as a fraction of body weight.
    /// The adaptive check-in steers calories toward this rate.
    public var targetWeeklyRate: Double {
        switch self {
        case .buildMuscle: 0.0025
        case .loseFat: -0.005
        case .getStronger: 0.001
        case .maintain, .recomposition, .improveFitness: 0
        }
    }

    /// Protein per kg of body weight. Higher in a deficit and for recomposition.
    public var proteinPerKg: Double {
        switch self {
        case .loseFat, .recomposition: 2.0
        default: 1.8
        }
    }
}

public enum DietaryPreference: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case vegetarian, vegan, pescatarian, dairyFree, glutenFree, halal, kosher

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .pescatarian: "Pescatarian"
        case .dairyFree: "Dairy-free"
        case .glutenFree: "Gluten-free"
        case .halal: "Halal"
        case .kosher: "Kosher"
        }
    }
}

extension DietaryPreference {
    /// Everyday protein sources that fit every selected preference.
    public static func proteinExamples(for preferences: Set<DietaryPreference>) -> String {
        let plantOnly = preferences.contains(.vegan)
        let noDairy = plantOnly || preferences.contains(.dairyFree)
        let noMeat = plantOnly || preferences.contains(.vegetarian) || preferences.contains(.pescatarian)
        if plantOnly { return "tofu, tempeh or a plant protein shake" }
        if noMeat && noDairy { return preferences.contains(.pescatarian) ? "fish, eggs or a plant protein shake" : "eggs, tofu or a plant protein shake" }
        if noMeat { return preferences.contains(.pescatarian) ? "Greek yogurt, fish or a shake" : "Greek yogurt, eggs or a shake" }
        if noDairy { return "chicken, eggs or a plant protein shake" }
        return "Greek yogurt or a shake"
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
    /// Optional so profiles saved before this field existed still decode.
    public var dietaryPreferences: Set<DietaryPreference>?

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
        restTimerNotifications: Bool = true,
        dietaryPreferences: Set<DietaryPreference>? = nil
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
        self.dietaryPreferences = dietaryPreferences
    }
}
