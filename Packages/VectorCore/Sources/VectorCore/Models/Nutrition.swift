import Foundation

public struct Macros: Codable, Hashable, Sendable {
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(calories: Double, protein: Double, carbs: Double, fat: Double) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public static let zero = Macros(calories: 0, protein: 0, carbs: 0, fat: 0)

    public static func + (lhs: Macros, rhs: Macros) -> Macros {
        Macros(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat
        )
    }

    public static func += (lhs: inout Macros, rhs: Macros) { lhs = lhs + rhs }

    public func scaled(by factor: Double) -> Macros {
        Macros(calories: calories * factor, protein: protein * factor, carbs: carbs * factor, fat: fat * factor)
    }

    /// Calories implied by macros (4/4/9). Used to sanity-check quick adds.
    public var caloriesFromMacros: Double { protein * 4 + carbs * 4 + fat * 9 }
}

public enum MealType: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case breakfast, lunch, dinner, snacks

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    public var symbol: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snacks: "takeoutbag.and.cup.and.straw"
        }
    }

    /// Sensible default meal for a given hour of the day.
    public static func suggested(forHour hour: Int) -> MealType {
        switch hour {
        case 4..<11: .breakfast
        case 11..<16: .lunch
        case 16..<22: .dinner
        default: .snacks
        }
    }
}

public struct FoodItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var brand: String?
    /// Nutrition per 100 g (or 100 ml).
    public var per100g: Macros
    /// Human serving description and its weight, e.g. "1 cup" = 158 g.
    public var servingName: String
    public var servingGrams: Double
    public var barcode: String?

    public init(
        id: String,
        name: String,
        brand: String? = nil,
        per100g: Macros,
        servingName: String,
        servingGrams: Double,
        barcode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.servingName = servingName
        self.servingGrams = servingGrams
        self.barcode = barcode
    }

    public func macros(grams: Double) -> Macros { per100g.scaled(by: grams / 100) }
}

public enum FoodEntrySource: String, Codable, Hashable, Sendable {
    case search, barcode, quickAdd, aiScan, savedMeal
}

public struct FoodEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var meal: MealType
    public var name: String
    public var foodID: String?
    /// Nil for quick-add entries that have no weight.
    public var grams: Double?
    /// Snapshot of the nutrition at the time of logging so later database
    /// edits never rewrite history.
    public var macros: Macros
    public var source: FoodEntrySource

    public init(
        id: UUID = UUID(),
        date: Date,
        meal: MealType,
        name: String,
        foodID: String? = nil,
        grams: Double? = nil,
        macros: Macros,
        source: FoodEntrySource
    ) {
        self.id = id
        self.date = date
        self.meal = meal
        self.name = name
        self.foodID = foodID
        self.grams = grams
        self.macros = macros
        self.source = source
    }
}

public struct SavedMeal: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [FoodEntry]

    public init(id: UUID = UUID(), name: String, items: [FoodEntry]) {
        self.id = id
        self.name = name
        self.items = items
    }

    public var macros: Macros { items.reduce(.zero) { $0 + $1.macros } }
}

public struct NutritionTargets: Codable, Hashable, Sendable {
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(calories: Double, protein: Double, carbs: Double, fat: Double) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public var asMacros: Macros { Macros(calories: calories, protein: protein, carbs: carbs, fat: fat) }
}

/// Totals for a single calendar day.
public struct DailyNutrition: Hashable, Sendable {
    public var date: Date
    public var consumed: Macros
    public var targets: NutritionTargets

    public init(date: Date, consumed: Macros, targets: NutritionTargets) {
        self.date = date
        self.consumed = consumed
        self.targets = targets
    }

    public var caloriesRemaining: Double { targets.calories - consumed.calories }
    public var calorieProgress: Double { Self.ratio(consumed.calories, targets.calories) }
    public var proteinProgress: Double { Self.ratio(consumed.protein, targets.protein) }
    public var carbsProgress: Double { Self.ratio(consumed.carbs, targets.carbs) }
    public var fatProgress: Double { Self.ratio(consumed.fat, targets.fat) }
    public var hitProteinTarget: Bool { consumed.protein >= targets.protein * 0.95 }

    static func ratio(_ value: Double, _ target: Double) -> Double {
        target > 0 ? value / target : 0
    }
}
