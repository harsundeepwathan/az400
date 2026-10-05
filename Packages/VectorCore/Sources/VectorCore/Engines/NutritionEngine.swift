import Foundation

public struct NutritionEngine: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Targets

    /// Mifflin–St Jeor resting energy expenditure.
    public static func restingEnergy(sex: BiologicalSex, weightKg: Double, heightCm: Double, age: Int) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        case .unspecified: return base - 78
        }
    }

    public static func activityMultiplier(trainingDays: Int) -> Double {
        switch trainingDays {
        case ..<3: 1.375
        case 3...4: 1.465
        default: 1.55
        }
    }

    /// Daily targets. Protein is set per kg of body weight (higher in a
    /// deficit to protect muscle), fat gets a floor for hormonal health, and
    /// carbohydrate takes the remaining energy.
    public static func targets(
        sex: BiologicalSex,
        weightKg: Double,
        heightCm: Double,
        age: Int,
        trainingDays: Int,
        goal: NutritionGoal
    ) -> NutritionTargets {
        let maintenance = restingEnergy(sex: sex, weightKg: weightKg, heightCm: heightCm, age: age)
            * activityMultiplier(trainingDays: trainingDays)
        let calories = max(((maintenance + goal.calorieAdjustment) / 50).rounded() * 50, 1200)
        let proteinPerKg: Double = goal == .lose ? 2.0 : 1.8
        let protein = (weightKg * proteinPerKg / 5).rounded() * 5
        let fat = (max(weightKg * 0.8, calories * 0.25 / 9) / 5).rounded() * 5
        let carbs = max(((calories - protein * 4 - fat * 9) / 4 / 5).rounded() * 5, 50)
        return NutritionTargets(calories: calories, protein: protein, carbs: carbs, fat: fat)
    }

    // MARK: Daily totals

    public func entries(_ entries: [FoodEntry], on day: Date) -> [FoodEntry] {
        entries.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    public func daily(_ all: [FoodEntry], on day: Date, targets: NutritionTargets) -> DailyNutrition {
        let consumed = entries(all, on: day).reduce(Macros.zero) { $0 + $1.macros }
        return DailyNutrition(date: calendar.startOfDay(for: day), consumed: consumed, targets: targets)
    }

    /// Daily totals for the last `days` days ending at `now`, oldest first.
    /// Only days with at least one entry are returned, because an unlogged
    /// day says nothing about what the user actually ate.
    public func loggedDays(_ all: [FoodEntry], days: Int, endingAt now: Date, targets: NutritionTargets) -> [DailyNutrition] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let dayEntries = entries(all, on: day)
            guard !dayEntries.isEmpty else { return nil }
            return DailyNutrition(date: day, consumed: dayEntries.reduce(.zero) { $0 + $1.macros }, targets: targets)
        }
    }

    /// Consecutive days (most recent first) hitting the protein target. Today
    /// counts only if it is already hit, so an in-progress day never breaks a streak.
    public func proteinStreak(_ all: [FoodEntry], now: Date, targets: NutritionTargets) -> Int {
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if daily(all, on: day, targets: targets).hitProteinTarget { streak += 1 }
        while true {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
            guard daily(all, on: day, targets: targets).hitProteinTarget else { break }
            streak += 1
        }
        return streak
    }

    /// Entries from the last few days grouped as recent foods, deduplicated by name.
    public func recentFoods(_ all: [FoodEntry], limit: Int = 8) -> [FoodEntry] {
        var seen = Set<String>()
        return all
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
