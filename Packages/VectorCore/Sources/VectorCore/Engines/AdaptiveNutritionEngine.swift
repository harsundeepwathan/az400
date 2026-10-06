import Foundation

/// One weekly adaptive-nutrition check-in, stored so the user (and the coach)
/// can see how targets have moved and why.
public struct NutritionCheckIn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var windowDays: Int
    public var trendStartKg: Double
    public var trendEndKg: Double
    /// Observed change in trend weight per week (kg).
    public var weeklyChangeKg: Double
    public var averageIntake: Double
    public var loggedDays: Int
    /// Energy expenditure implied by intake and weight change.
    public var estimatedExpenditure: Double
    public var previousCalories: Double
    public var recommendedCalories: Double
    public var applied: Bool

    public init(id: UUID = UUID(), date: Date, windowDays: Int, trendStartKg: Double, trendEndKg: Double,
                weeklyChangeKg: Double, averageIntake: Double, loggedDays: Int, estimatedExpenditure: Double,
                previousCalories: Double, recommendedCalories: Double, applied: Bool = false) {
        self.id = id
        self.date = date
        self.windowDays = windowDays
        self.trendStartKg = trendStartKg
        self.trendEndKg = trendEndKg
        self.weeklyChangeKg = weeklyChangeKg
        self.averageIntake = averageIntake
        self.loggedDays = loggedDays
        self.estimatedExpenditure = estimatedExpenditure
        self.previousCalories = previousCalories
        self.recommendedCalories = recommendedCalories
        self.applied = applied
    }

    public var change: Double { recommendedCalories - previousCalories }
}

public enum CheckInResult: Hashable, Sendable {
    /// Enough data: a recommendation with its reasoning.
    case ready(NutritionCheckIn, reason: String, evidence: [Evidence])
    /// Not enough data yet; `missing` says exactly what's needed.
    case needsMoreData(missing: String, evidence: [Evidence])
}

/// Closes the loop between what the user eats, what the scale does and what
/// their goal needs. It estimates real energy expenditure from logged intake
/// and the weight trend (energy balance, ~7,700 kcal per kg), then sets the
/// calorie target that should produce the goal's rate of change.
///
/// Guard rails: it needs two weeks of mostly complete logging and regular
/// weigh-ins, changes targets by at most 250 kcal per check-in, and never
/// goes below 1,200 kcal. Partial-logging days are ignored rather than
/// trusted, because they'd make expenditure look artificially low.
public struct AdaptiveNutritionEngine: Sendable {
    public static let windowDays = 14
    public static let minimumLoggedDays = 10
    public static let minimumWeighIns = 6
    public static let maxChangePerCheckIn = 250.0
    public static let minimumCalories = 1200.0
    /// Days below this are treated as incompletely logged.
    public static let completeDayCalories = 800.0
    static let kcalPerKg = 7700.0

    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Check-ins are weekly.
    public func isDue(lastCheckIn: Date?, now: Date) -> Bool {
        guard let lastCheckIn else { return true }
        return now.timeIntervalSince(lastCheckIn) >= 7 * 86_400 - 3600
    }

    public func evaluate(profile: UserProfile, bodyWeights: [BodyWeightEntry], foodEntries: [FoodEntry], now: Date) -> CheckInResult {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -Self.windowDays, to: today) else {
            return .needsMoreData(missing: "Keep logging.", evidence: [])
        }
        let window = DateInterval(start: windowStart, end: today)

        // Intake: complete days only, excluding today (still in progress).
        let nutrition = NutritionEngine(calendar: calendar)
        let days = nutrition.loggedDays(foodEntries, days: Self.windowDays + 1, endingAt: now, targets: profile.targets)
            .filter { window.contains($0.date) && $0.consumed.calories >= Self.completeDayCalories }
        let weighIns = bodyWeights.filter { window.contains($0.date) }.sorted { $0.date < $1.date }

        var evidence = [
            Evidence("Complete food-log days", "\(days.count) of \(Self.windowDays)"),
            Evidence("Weigh-ins", "\(weighIns.count) in \(Self.windowDays) days")
        ]
        var missing: [String] = []
        if days.count < Self.minimumLoggedDays {
            missing.append("\(Self.minimumLoggedDays - days.count) more fully logged days")
        }
        if weighIns.count < Self.minimumWeighIns {
            missing.append("\(Self.minimumWeighIns - weighIns.count) more weigh-ins")
        }
        guard missing.isEmpty, let first = weighIns.first, let last = weighIns.last else {
            return .needsMoreData(missing: "Your first check-in needs " + missing.joined(separator: " and ") + ".", evidence: evidence)
        }

        // Smooth with all available history so the window's start isn't a single noisy weigh-in.
        let analytics = AnalyticsEngine(calendar: calendar)
        let all = bodyWeights.filter { $0.date <= now }.sorted { $0.date < $1.date }
        let trend = analytics.smoothedTrend(all.map { ChartPoint(date: $0.date, value: $0.kilograms) })
        let startTrend = trend.last { $0.date <= first.date }?.value ?? first.kilograms
        let endTrend = trend.last { $0.date <= last.date }?.value ?? last.kilograms
        let spanDays = max(last.date.timeIntervalSince(first.date) / 86_400, 1)

        let change = endTrend - startTrend
        let weeklyChange = change / spanDays * 7
        let averageIntake = days.reduce(0) { $0 + $1.consumed.calories } / Double(days.count)
        let expenditure = averageIntake - change * Self.kcalPerKg / spanDays
        let goalDailyEnergy = profile.goal.targetWeeklyRate * endTrend * Self.kcalPerKg / 7
        let ideal = expenditure + goalDailyEnergy

        let current = profile.targets.calories
        let clamped = min(max(ideal, current - Self.maxChangePerCheckIn), current + Self.maxChangePerCheckIn)
        var recommended = max((clamped / 50).rounded() * 50, Self.minimumCalories)
        if abs(recommended - current) < 50 { recommended = current }

        let checkIn = NutritionCheckIn(
            date: now, windowDays: Self.windowDays, trendStartKg: startTrend, trendEndKg: endTrend,
            weeklyChangeKg: weeklyChange, averageIntake: averageIntake, loggedDays: days.count,
            estimatedExpenditure: expenditure, previousCalories: current, recommendedCalories: recommended
        )

        let unit = profile.unit
        evidence = [
            Evidence("Trend weight", "\(Format.estimate(startTrend, unit: unit)) → \(Format.estimate(endTrend, unit: unit))"),
            Evidence("Weekly change", (weeklyChange >= 0 ? "+" : "\u{2212}") + Format.weight((abs(weeklyChange) * 100).rounded() / 100, unit: unit)),
            Evidence("Average intake", "\(Format.integer(averageIntake)) kcal (\(days.count) days)"),
            Evidence("Estimated expenditure", "\(Format.integer(expenditure)) kcal")
        ] + evidence.suffix(1)

        let goalText: String
        switch profile.goal.targetWeeklyRate {
        case 0: goalText = "to hold your weight"
        case ..<0: goalText = "to lose about \(Format.weight((abs(profile.goal.targetWeeklyRate) * endTrend * 100).rounded() / 100, unit: unit)) a week"
        default: goalText = "to gain about \(Format.weight((profile.goal.targetWeeklyRate * endTrend * 100).rounded() / 100, unit: unit)) a week"
        }
        let trendText = abs(change) < 0.2
            ? "Your trend weight held around \(Format.estimate(endTrend, unit: unit))"
            : "Your trend weight went from \(Format.estimate(startTrend, unit: unit)) to \(Format.estimate(endTrend, unit: unit))"
        let base = "\(trendText) over \(Int(spanDays.rounded())) days while you averaged \(Format.integer(averageIntake)) kcal, so your expenditure is about \(Format.integer(expenditure)) kcal."
        let reason: String
        if recommended == current {
            reason = base + " Your \(Format.integer(current)) kcal target is already right \(goalText). No change needed."
        } else {
            let delta = recommended - current
            let capped = abs(ideal - current) > Self.maxChangePerCheckIn ? " (capped at \(Int(Self.maxChangePerCheckIn)) kcal per week so changes stay gradual)" : ""
            reason = base + " \(delta > 0 ? "Increase" : "Reduce") your target by \(Format.integer(abs(delta))) kcal to \(Format.integer(recommended)) kcal \(goalText)\(capped)."
        }
        return .ready(checkIn, reason: reason, evidence: evidence)
    }

    /// New targets for an accepted check-in: protein and fat are kept, carbohydrate absorbs the change.
    public static func targets(applying checkIn: NutritionCheckIn, to targets: NutritionTargets) -> NutritionTargets {
        var updated = targets
        updated.calories = checkIn.recommendedCalories
        let carbs = (checkIn.recommendedCalories - targets.protein * 4 - targets.fat * 9) / 4
        updated.carbs = max((carbs / 5).rounded() * 5, 50)
        return updated
    }
}
