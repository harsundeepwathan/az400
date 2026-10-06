import Foundation

// The deterministic coaching engine. Everything that decides what a user
// should change (calories, whether the plan is on track, whether a past
// adjustment worked) is computed here, in code, with explicit thresholds.
// AI is only ever given the result to explain.

// MARK: - Confidence

/// How much Vector trusts its own conclusion. Below `.moderate`, targets
/// never change; below `.low`, Vector says what data it still needs.
public enum CoachConfidence: Int, Codable, Comparable, CaseIterable, Sendable {
    case insufficient, low, moderate, high

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .insufficient: "Not enough data yet"
        case .low: "Low confidence"
        case .moderate: "Moderate confidence"
        case .high: "High confidence"
        }
    }
}

// MARK: - Goal bands

/// The weekly rate of body-weight change each goal aims for, as a fraction
/// of body weight. A range, not a point: anywhere inside it is on track.
public struct GoalBand: Hashable, Sendable {
    public var lower: Double
    public var upper: Double

    public var midpoint: Double { (lower + upper) / 2 }

    public func contains(_ rate: Double) -> Bool { rate >= lower - 1e-9 && rate <= upper + 1e-9 }

    /// The band in kilograms per week for a given body weight.
    public func kilograms(at bodyWeightKg: Double) -> ClosedRange<Double> {
        (lower * bodyWeightKg)...(upper * bodyWeightKg)
    }
}

extension TrainingGoal {
    public var band: GoalBand {
        switch self {
        case .buildMuscle: GoalBand(lower: 0.0015, upper: 0.004)
        case .loseFat: GoalBand(lower: -0.0075, upper: -0.003)
        case .getStronger: GoalBand(lower: 0, upper: 0.0025)
        case .maintain, .recomposition, .improveFitness: GoalBand(lower: -0.0015, upper: 0.0015)
        }
    }
}

// MARK: - Metrics

public struct WeightTrend: Hashable, Sendable {
    public var startKg: Double
    public var endKg: Double
    public var spanDays: Double
    public var weighIns: Int

    public var changeKg: Double { endKg - startKg }
    public var kgPerWeek: Double { changeKg / max(spanDays, 1) * 7 }
    public var fractionPerWeek: Double { endKg > 0 ? kgPerWeek / endKg : 0 }
}

public struct NutritionAdherence: Hashable, Sendable {
    public var windowDays: Int
    public var loggedDays: Int
    /// Days logged within ±10% of the calorie target.
    public var calorieDaysOnTarget: Int
    /// Days logged at or above 90% of the protein target.
    public var proteinDaysOnTarget: Int
    public var averageCalories: Double?
    public var averageProtein: Double?

    /// Unlogged days can't be verified, so they count against adherence.
    public var calorieAdherence: Double { windowDays > 0 ? Double(calorieDaysOnTarget) / Double(windowDays) : 0 }
    public var proteinAdherence: Double { windowDays > 0 ? Double(proteinDaysOnTarget) / Double(windowDays) : 0 }
    public var loggingCoverage: Double { windowDays > 0 ? Double(loggedDays) / Double(windowDays) : 0 }
}

public struct TrainingAdherence: Hashable, Sendable {
    public var planned: Int
    public var completed: Int
    public var adherence: Double { planned > 0 ? min(Double(completed) / Double(planned), 1) : 0 }
}

/// Pure measurements over windows of the user's own data. Today is always
/// excluded from nutrition windows because it isn't over yet.
public struct CoachMetrics: Sendable {
    /// Days below this are treated as partially logged and ignored.
    public static let completeDayCalories = 800.0
    public static let calorieTolerance = 0.10
    public static let proteinThreshold = 0.90

    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// `[start, today)`: the `days` complete days before today.
    public func window(days: Int, endingBefore now: Date) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        return DateInterval(start: start, end: today)
    }

    public func nutritionAdherence(_ entries: [FoodEntry], targets: NutritionTargets, days: Int, now: Date) -> NutritionAdherence {
        let window = window(days: days, endingBefore: now)
        let logged = NutritionEngine(calendar: calendar)
            .loggedDays(entries, days: days + 1, endingAt: now, targets: targets)
            .filter { $0.date >= window.start && $0.date < window.end && $0.consumed.calories >= Self.completeDayCalories }
        let onCalories = logged.filter { abs($0.consumed.calories - targets.calories) <= targets.calories * Self.calorieTolerance }.count
        let onProtein = logged.filter { $0.consumed.protein >= targets.protein * Self.proteinThreshold }.count
        let average = { (value: (DailyNutrition) -> Double) -> Double? in
            logged.isEmpty ? nil : logged.reduce(0) { $0 + value($1) } / Double(logged.count)
        }
        return NutritionAdherence(windowDays: days, loggedDays: logged.count, calorieDaysOnTarget: onCalories,
                                  proteinDaysOnTarget: onProtein, averageCalories: average { $0.consumed.calories },
                                  averageProtein: average { $0.consumed.protein })
    }

    /// Smoothed (EWMA) weight trend across weigh-ins in the window. Uses all
    /// history for smoothing so the window's start isn't one noisy weigh-in.
    public func weightTrend(_ entries: [BodyWeightEntry], days: Int, now: Date) -> WeightTrend? {
        let window = DateInterval(start: window(days: days, endingBefore: now).start, end: now)
        let inWindow = entries.filter { window.contains($0.date) }.sorted { $0.date < $1.date }
        guard let first = inWindow.first, let last = inWindow.last, inWindow.count >= 2 else { return nil }
        let all = entries.filter { $0.date <= now }.sorted { $0.date < $1.date }
        let trend = AnalyticsEngine(calendar: calendar).smoothedTrend(all.map { ChartPoint(date: $0.date, value: $0.kilograms) })
        let start = trend.last { $0.date <= first.date }?.value ?? first.kilograms
        let end = trend.last { $0.date <= last.date }?.value ?? last.kilograms
        return WeightTrend(startKg: start, endKg: end, spanDays: last.date.timeIntervalSince(first.date) / 86_400, weighIns: inWindow.count)
    }

    /// Mean of raw weigh-ins in the 7 days ending `weeksAgo` weeks before today.
    public func weeklyAverage(_ entries: [BodyWeightEntry], weeksAgo: Int, now: Date) -> Double? {
        let end = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: now) ?? now
        let start = end.addingTimeInterval(-7 * 86_400)
        let values = entries.filter { $0.date > start && $0.date <= end }.map(\.kilograms)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public func trainingAdherence(_ sessions: [WorkoutSession], plannedPerWeek: Int, days: Int, now: Date) -> TrainingAdherence {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let completed = sessions.filter { $0.isFinished && $0.startedAt >= start && $0.startedAt <= now }.count
        let planned = Int((Double(plannedPerWeek) * Double(days) / 7).rounded())
        return TrainingAdherence(planned: planned, completed: completed)
    }

    /// Workouts planned and done in the current calendar week (for accountability).
    public func thisWeek(_ sessions: [WorkoutSession], plannedPerWeek: Int, now: Date) -> (planned: Int, completed: Int, daysLeft: Int) {
        let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86_400)
        let completed = sessions.filter { $0.isFinished && $0.startedAt >= week.start && $0.startedAt < week.end }.count
        let daysLeft = max((calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: week.end).day ?? 0) - 1, 0)
        return (plannedPerWeek, completed, daysLeft)
    }

    /// Fractional change in total working volume: last 7 days vs the 7 before.
    public func volumeChange(_ sessions: [WorkoutSession], now: Date) -> Double? {
        let volume = { (from: Date, to: Date) in
            sessions.filter { $0.isFinished && $0.startedAt >= from && $0.startedAt < to }.reduce(0) { $0 + $1.volume }
        }
        let current = volume(now.addingTimeInterval(-7 * 86_400), now)
        let previous = volume(now.addingTimeInterval(-14 * 86_400), now.addingTimeInterval(-7 * 86_400))
        return previous > 0 ? (current - previous) / previous : nil
    }
}

// MARK: - Decisions and memory

/// One coaching decision, kept so Vector can explain its history and later
/// measure whether a change worked.
public struct CoachDecision: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case calorieAdjustment, noChange, improveAdherence
    }

    public enum Status: String, Codable, Sendable {
        /// Recommendation accepted (or a no-change review acknowledged).
        case applied
        /// Recommendation shown and the user kept their current target.
        case rejected
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var status: Status
    public var goal: TrainingGoal
    public var previousCalories: Double
    public var newCalories: Double
    public var reason: String
    public var evidence: [Evidence]
    public var confidence: CoachConfidence
    /// Trend rate (kg/week) when the decision was made, for outcome evaluation.
    public var baselineKgPerWeek: Double?
    public var baselineCalorieAdherence: Double?

    public init(id: UUID = UUID(), date: Date, kind: Kind, status: Status, goal: TrainingGoal, previousCalories: Double,
                newCalories: Double, reason: String, evidence: [Evidence], confidence: CoachConfidence,
                baselineKgPerWeek: Double?, baselineCalorieAdherence: Double?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.status = status
        self.goal = goal
        self.previousCalories = previousCalories
        self.newCalories = newCalories
        self.reason = reason
        self.evidence = evidence
        self.confidence = confidence
        self.baselineKgPerWeek = baselineKgPerWeek
        self.baselineCalorieAdherence = baselineCalorieAdherence
    }

    public var calorieChange: Double { newCalories - previousCalories }
}

public struct DecisionOutcome: Hashable, Sendable {
    public enum Verdict: String, Hashable, Sendable {
        /// Too soon after the change, or too few weigh-ins since, to judge.
        case measuring
        case effective, partiallyEffective, notEffective
    }

    public var decision: CoachDecision
    public var verdict: Verdict
    public var kgPerWeekBefore: Double?
    public var kgPerWeekAfter: Double?
    public var summary: String
}

// MARK: - Weekly check-in

public struct BaselineItem: Hashable, Sendable, Identifiable {
    public var label: String
    public var done: Int
    public var needed: Int
    public var id: String { label }
    public var isComplete: Bool { done >= needed }
}

public enum CoachRecommendation: Hashable, Sendable {
    /// Not enough data to say anything about the plan yet.
    case learningBaseline([BaselineItem])
    /// Intake was too far from target for the trend to be meaningful.
    case improveAdherence(reason: String)
    /// The plan is working: change nothing.
    case onTrack(reason: String)
    /// Change the calorie target.
    case adjustCalories(from: Double, to: Double, reason: String)
    /// Outside the goal band but the data isn't strong enough to act on yet.
    case watch(reason: String)
}

public struct WeeklyReview: Hashable, Sendable {
    public struct Training: Hashable, Sendable {
        public var planned: Int
        public var completed: Int
        public var adherence: Double
        public var volumeChange: Double?
        public var mainLift: String?
        public var e1rmBefore: Double?
        public var e1rmNow: Double?
    }

    public struct Body: Hashable, Sendable {
        public var previousWeekAverage: Double?
        public var currentWeekAverage: Double?
        public var trend: WeightTrend?
        public var weeklyChange: Double? {
            guard let previousWeekAverage, let currentWeekAverage else { return nil }
            return currentWeekAverage - previousWeekAverage
        }
    }

    public enum GoalStatus: String, Hashable, Sendable { case below, within, above, unknown }

    public var date: Date
    public var goal: TrainingGoal
    public var targets: NutritionTargets
    public var training: Training
    public var nutrition: NutritionAdherence
    public var body: Body
    public var bandKgPerWeek: ClosedRange<Double>?
    public var goalStatus: GoalStatus
    public var confidence: CoachConfidence
    public var recommendation: CoachRecommendation
    public var evidence: [Evidence]
    public var previousOutcome: DecisionOutcome?

    /// The decision record to store when the user acts on this review.
    public func decision(status: CoachDecision.Status) -> CoachDecision? {
        let (kind, newCalories, reason): (CoachDecision.Kind, Double, String)
        switch recommendation {
        case .learningBaseline: return nil
        case .watch(let text): (kind, newCalories, reason) = (.noChange, targets.calories, text)
        case .onTrack(let text): (kind, newCalories, reason) = (.noChange, targets.calories, text)
        case .improveAdherence(let text): (kind, newCalories, reason) = (.improveAdherence, targets.calories, text)
        case .adjustCalories(_, let to, let text): (kind, newCalories, reason) = (.calorieAdjustment, to, text)
        }
        return CoachDecision(date: date, kind: kind, status: status, goal: goal, previousCalories: targets.calories,
                             newCalories: status == .applied ? newCalories : targets.calories, reason: reason,
                             evidence: evidence, confidence: confidence, baselineKgPerWeek: body.trend?.kgPerWeek,
                             baselineCalorieAdherence: nutrition.calorieAdherence)
    }
}

/// Builds the weekly review and makes exactly one, conservative decision.
public struct WeeklyCheckInEngine: Sendable {
    /// Decisions look back three weeks; the review shows the last week.
    public static let decisionWindowDays = 21
    public static let minimumSpanDays = 14.0
    public static let minimumWeighIns = 8
    public static let minimumLoggedDays = 10
    /// Below this calorie adherence the trend says more about logging than about the target.
    public static let adherenceGate = 0.80
    public static let maxChange = 250.0
    public static let minChange = 100.0
    public static let minimumCalories = 1200.0
    /// Never steer weight loss faster than this fraction of body weight per week.
    public static let maxLossRate = 0.01
    static let kcalPerKg = 7700.0
    static let reviewInterval: TimeInterval = 7 * 86_400 - 3600

    public let calendar: Calendar
    public let catalog: ExerciseCatalog

    public init(calendar: Calendar = .current, catalog: ExerciseCatalog = .standard) {
        self.calendar = calendar
        self.catalog = catalog
    }

    /// A review is due weekly after the last decision (or legacy check-in).
    public func isDue(lastReview: Date?, now: Date) -> Bool {
        guard let lastReview else { return true }
        return now.timeIntervalSince(lastReview) >= Self.reviewInterval
    }

    public func review(profile: UserProfile, program: TrainingProgram?, sessions: [WorkoutSession], foodEntries: [FoodEntry],
                       bodyWeights: [BodyWeightEntry], decisions: [CoachDecision], now: Date) -> WeeklyReview {
        let metrics = CoachMetrics(calendar: calendar)
        let unit = profile.unit
        let plannedPerWeek = max(program?.daysPerWeek ?? profile.daysPerWeek, 1)

        // Last 7 days, for display.
        let week = metrics.nutritionAdherence(foodEntries, targets: profile.targets, days: 7, now: now)
        let trainingWeek = metrics.trainingAdherence(sessions, plannedPerWeek: plannedPerWeek, days: 7, now: now)
        let lift = mainLift(program: program, sessions: sessions, now: now)
        let training = WeeklyReview.Training(planned: trainingWeek.planned, completed: trainingWeek.completed,
                                             adherence: trainingWeek.adherence, volumeChange: metrics.volumeChange(sessions, now: now),
                                             mainLift: lift?.name, e1rmBefore: lift?.before, e1rmNow: lift?.now)
        let body = WeeklyReview.Body(previousWeekAverage: metrics.weeklyAverage(bodyWeights, weeksAgo: 1, now: now),
                                     currentWeekAverage: metrics.weeklyAverage(bodyWeights, weeksAgo: 0, now: now),
                                     trend: metrics.weightTrend(bodyWeights, days: Self.decisionWindowDays, now: now))

        // Up to three weeks, for the decision. A new user's window starts at
        // their first log, so days before they joined don't count against them.
        let firstLog = (foodEntries.map(\.date) + bodyWeights.map(\.date)).min() ?? now
        let daysSinceFirst = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstLog), to: calendar.startOfDay(for: now)).day ?? 0
        let windowDays = min(max(daysSinceFirst, 7), Self.decisionWindowDays)
        let long = metrics.nutritionAdherence(foodEntries, targets: profile.targets, days: windowDays, now: now)
        let trend = body.trend
        let band = profile.goal.band
        let weight = trend?.endKg ?? profile.weightKg
        let goalStatus: WeeklyReview.GoalStatus = trend.map { t in
            t.fractionPerWeek < band.lower ? .below : (t.fractionPerWeek > band.upper ? .above : .within)
        } ?? .unknown

        var evidence: [Evidence] = [
            Evidence("Workouts (7 days)", "\(trainingWeek.completed) of \(trainingWeek.planned)"),
            Evidence("Calorie adherence (\(windowDays) days)", Self.percent(long.calorieAdherence)),
            Evidence("Days logged (\(windowDays) days)", "\(long.loggedDays) of \(windowDays)")
        ]
        if let avg = long.averageCalories {
            evidence.append(Evidence("Average intake", "\(Format.integer(avg)) of \(Format.integer(profile.targets.calories)) kcal"))
        }
        if let trend {
            evidence.append(Evidence("Weight trend", "\(Self.signedKg(trend.kgPerWeek, unit: unit))/week over \(Int(trend.spanDays.rounded())) days"))
        }
        evidence.append(Evidence("Goal range", Self.bandText(band, weight: weight, unit: unit)))

        let confidence = Self.confidence(trend: trend, nutrition: long)
        let recommendation = decide(profile: profile, trend: trend, nutrition: long, confidence: confidence,
                                    goalStatus: goalStatus, band: band, weight: weight, trainingAdherence: trainingWeek)

        return WeeklyReview(date: now, goal: profile.goal, targets: profile.targets, training: training, nutrition: week, body: body,
                            bandKgPerWeek: trend == nil ? nil : band.kilograms(at: weight), goalStatus: goalStatus,
                            confidence: confidence, recommendation: recommendation, evidence: evidence,
                            previousOutcome: OutcomeEvaluator(calendar: calendar).latestOutcome(decisions: decisions, bodyWeights: bodyWeights, now: now))
    }

    static func confidence(trend: WeightTrend?, nutrition: NutritionAdherence) -> CoachConfidence {
        guard let trend, trend.spanDays >= Self.minimumSpanDays, trend.weighIns >= Self.minimumWeighIns,
              nutrition.loggedDays >= Self.minimumLoggedDays else {
            let some = (trend?.weighIns ?? 0) >= 3 || nutrition.loggedDays >= 5
            return some ? .low : .insufficient
        }
        if trend.spanDays >= 20, trend.weighIns >= 12, nutrition.loggingCoverage >= 0.85 { return .high }
        return .moderate
    }

    func baseline(trend: WeightTrend?, nutrition: NutritionAdherence, sessions trainingAdherence: TrainingAdherence) -> [BaselineItem] {
        [
            BaselineItem(label: "workouts", done: min(trainingAdherence.completed, 2), needed: 2),
            BaselineItem(label: "nutrition days", done: min(nutrition.loggedDays, Self.minimumLoggedDays), needed: Self.minimumLoggedDays),
            BaselineItem(label: "weigh-ins", done: min(trend?.weighIns ?? 0, Self.minimumWeighIns), needed: Self.minimumWeighIns)
        ]
    }

    func decide(profile: UserProfile, trend: WeightTrend?, nutrition: NutritionAdherence, confidence: CoachConfidence,
                goalStatus: WeeklyReview.GoalStatus, band: GoalBand, weight: Double, trainingAdherence: TrainingAdherence) -> CoachRecommendation {
        let unit = profile.unit
        let goalText = profile.goal.title.lowercased()
        let bandText = Self.bandText(band, weight: weight, unit: unit)

        guard confidence >= .moderate, let trend else {
            // Adherence can be judged before the weight trend can.
            if nutrition.loggedDays >= 7, nutrition.calorieAdherence < Self.adherenceGate - 0.2 {
                return .improveAdherence(reason: "You've been within 10% of your \(Format.integer(profile.targets.calories)) kcal target on \(Self.percent(nutrition.calorieAdherence)) of the last \(nutrition.windowDays) days. Follow your current target more consistently before Vector judges whether it's working.")
            }
            return .learningBaseline(baseline(trend: trend, nutrition: nutrition, sessions: trainingAdherence))
        }

        if nutrition.calorieAdherence < Self.adherenceGate {
            return .improveAdherence(reason: "You've been within 10% of your \(Format.integer(profile.targets.calories)) kcal target on \(Self.percent(nutrition.calorieAdherence)) of the last \(nutrition.windowDays) days. Follow your current target more consistently before adjusting it: changing the number now would be guessing.")
        }

        let rateText = "\(Self.signedKg(trend.kgPerWeek, unit: unit))/week"
        if goalStatus == .within {
            return .onTrack(reason: "Your weight trend of \(rateText) is inside your \(goalText) range (\(bandText)) with \(Self.percent(nutrition.calorieAdherence)) calorie adherence. No changes recommended.")
        }

        // Estimate real expenditure from intake and the trend, then aim at the band midpoint.
        let intake = nutrition.averageCalories ?? profile.targets.calories
        let expenditure = intake - trend.changeKg * Self.kcalPerKg / max(trend.spanDays, 1)
        var targetRate = band.midpoint
        if profile.goal == .loseFat { targetRate = max(targetRate, -Self.maxLossRate) }
        let ideal = expenditure + targetRate * weight * Self.kcalPerKg / 7
        let current = profile.targets.calories
        let direction: Double = goalStatus == .below ? 1 : -1
        var change = (ideal - current) * direction >= 0 ? abs(ideal - current) : 0
        change = min(max(change, Self.minChange), Self.maxChange) * direction
        let proposed = max(((current + change) / 50).rounded() * 50, Self.minimumCalories)

        if confidence < .high, abs(proposed - current) >= 50, trend.spanDays < 20 {
            return .watch(reason: "Your weight trend of \(rateText) is \(goalStatus == .below ? "below" : "above") your \(goalText) range (\(bandText)), but there's only \(Int(trend.spanDays.rounded())) days of trend. Keep your current targets for one more week so Vector can confirm it before changing anything.")
        }
        if proposed == current {
            return .improveAdherence(reason: "Your trend is \(goalStatus == .below ? "below" : "above") your range, but your calorie target is already at the safe minimum of \(Format.integer(Self.minimumCalories)) kcal. Please speak to a qualified professional before eating less.")
        }
        let delta = proposed - current
        return .adjustCalories(from: current, to: proposed, reason: "Your weight trend has been \(rateText) for \(Int(trend.spanDays.rounded())) days, \(goalStatus == .below ? "below" : "above") your \(goalText) range (\(bandText)), with \(Self.percent(nutrition.calorieAdherence)) calorie adherence. \(delta > 0 ? "Increase" : "Reduce") your target by \(Format.integer(abs(delta))) kcal a day to move toward the range.")
    }

    func mainLift(program: TrainingProgram?, sessions: [WorkoutSession], now: Date) -> (name: String, before: Double?, now: Double)? {
        let engine = ProgressionEngine()
        let candidates = (program?.nextWorkout?.exercises.first).map { [$0.exerciseID] } ?? []
        let tracked = AnalyticsEngine(catalog: catalog, calendar: calendar).trackedExercises(sessions).filter(\.isCompound).map(\.id)
        for id in candidates + tracked {
            let history = engine.history(for: id, in: sessions).filter { $0.date <= now }
            guard let latest = history.first, let exercise = catalog[id] else { continue }
            let monthAgo = now.addingTimeInterval(-30 * 86_400)
            let baseline = history.last { $0.date >= monthAgo }
            let before = baseline.flatMap { $0.sessionID == latest.sessionID ? nil : $0.estimatedOneRepMax }
            return (exercise.name, before, latest.estimatedOneRepMax)
        }
        return nil
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func signedKg(_ kg: Double, unit: WeightUnit) -> String {
        let value = (unit.fromKilograms(abs(kg)) * 100).rounded() / 100
        let sign = kg > 0.004 ? "+" : (kg < -0.004 ? "\u{2212}" : "")
        return sign + Format.number(value, maxFraction: 2) + " " + unit.symbol
    }

    static func bandText(_ band: GoalBand, weight: Double, unit: WeightUnit) -> String {
        let range = band.kilograms(at: weight)
        return "\(signedKg(range.lowerBound, unit: unit)) to \(signedKg(range.upperBound, unit: unit))/week"
    }
}

// MARK: - Outcomes

/// Did the last calorie change do what it was meant to?
public struct OutcomeEvaluator: Sendable {
    public static let minimumDaysAfter = 14.0
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func latestOutcome(decisions: [CoachDecision], bodyWeights: [BodyWeightEntry], now: Date) -> DecisionOutcome? {
        guard let decision = decisions.filter({ $0.kind == .calorieAdjustment && $0.status == .applied && $0.calorieChange != 0 })
            .max(by: { $0.date < $1.date }) else { return nil }
        return evaluate(decision, bodyWeights: bodyWeights, now: now)
    }

    public func evaluate(_ decision: CoachDecision, bodyWeights: [BodyWeightEntry], now: Date) -> DecisionOutcome {
        let days = now.timeIntervalSince(decision.date) / 86_400
        let after = bodyWeights.filter { $0.date > decision.date && $0.date <= now }
        let unit: WeightUnit = .kilograms
        guard days >= Self.minimumDaysAfter, after.count >= 6,
              let trend = CoachMetrics(calendar: calendar).weightTrend(bodyWeights, days: Int(min(days, 28)), now: now) else {
            return DecisionOutcome(decision: decision, verdict: .measuring, kgPerWeekBefore: decision.baselineKgPerWeek, kgPerWeekAfter: nil,
                                   summary: "Measuring the effect of your \(Format.integer(abs(decision.calorieChange))) kcal change. Vector needs about 2 weeks of weigh-ins after a change to judge it.")
        }
        let band = decision.goal.band.kilograms(at: trend.endKg)
        let rate = trend.kgPerWeek
        let before = decision.baselineKgPerWeek
        let verdict: DecisionOutcome.Verdict
        if band.contains(rate) {
            verdict = .effective
        } else if let before {
            let target = (band.lowerBound + band.upperBound) / 2
            let progress = abs(before - target) > 0.0001 ? (abs(before - target) - abs(rate - target)) / abs(before - target) : 0
            verdict = progress >= 0.5 ? .partiallyEffective : .notEffective
        } else {
            verdict = .notEffective
        }
        let change = "\(decision.calorieChange > 0 ? "+" : "\u{2212}")\(Format.integer(abs(decision.calorieChange))) kcal"
        let beforeText = before.map { WeeklyCheckInEngine.signedKg($0, unit: unit) + "/week" } ?? "unknown"
        let afterText = WeeklyCheckInEngine.signedKg(rate, unit: unit) + "/week"
        let summary: String
        switch verdict {
        case .effective: summary = "Your \(change) change moved your trend from \(beforeText) to \(afterText), inside your goal range. The adjustment is working."
        case .partiallyEffective: summary = "Your \(change) change moved your trend from \(beforeText) to \(afterText): closer to your goal range, but not in it yet."
        case .notEffective: summary = "Your \(change) change hasn't moved your trend toward your goal range yet (\(beforeText) before, \(afterText) since)."
        case .measuring: summary = ""
        }
        return DecisionOutcome(decision: decision, verdict: verdict, kgPerWeekBefore: before, kgPerWeekAfter: rate, summary: summary)
    }
}

extension NutritionTargets {
    /// The same targets at a new calorie level: protein and fat stay, carbs
    /// absorb the difference (rounded to 5 g, never below 50 g).
    public func withCalories(_ calories: Double) -> NutritionTargets {
        var updated = self
        updated.calories = calories
        let carbs = (calories - protein * 4 - fat * 9) / 4
        updated.carbs = max((carbs / 5).rounded() * 5, 50)
        return updated
    }
}
