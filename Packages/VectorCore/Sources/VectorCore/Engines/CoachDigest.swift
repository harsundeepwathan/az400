import Foundation

/// The structured digest sent to `POST /v1/coach/summary` (shared contract
/// in `docs/tasks/p1-tasklist.md`). Every number is computed on device from
/// the user's own logs by the existing engines; the server's model may only
/// rephrase these numbers, never add its own.
///
/// Weights are in the user's display unit (`unit`), so the summary quotes the
/// same numbers the app shows. Nullable fields are always encoded, as `null`.
/// Decodable so the app can keep the exact digest a summary was written
/// from (`CoachSummaryArchive`).
public struct CoachDigest: Codable, Hashable, Sendable {
    public struct PR: Codable, Hashable, Sendable {
        public var exercise: String
        public var weight: Double
        public var reps: Int
    }

    public struct MainLift: Codable, Hashable, Sendable {
        public var exercise: String
        public var e1rmNow: Double
        public var e1rm30dAgo: Double?

        enum CodingKeys: String, CodingKey {
            case exercise, e1rmNow = "e1rm_now", e1rm30dAgo = "e1rm_30d_ago"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(exercise, forKey: .exercise)
            try container.encode(e1rmNow, forKey: .e1rmNow)
            try container.encode(e1rm30dAgo, forKey: .e1rm30dAgo)
        }
    }

    public struct Training: Codable, Hashable, Sendable {
        public var workoutsLast7d: Int
        public var workoutsPrev7d: Int
        public var plannedPerWeek: Int
        /// Percent (6.5 means +6.5%), not a fraction. Nil without a baseline week.
        public var volumeChangePct: Double?
        public var prsLast14d: [PR]
        public var mainLift: MainLift?

        enum CodingKeys: String, CodingKey {
            case workoutsLast7d = "workouts_last_7d", workoutsPrev7d = "workouts_prev_7d", plannedPerWeek = "planned_per_week"
            case volumeChangePct = "volume_change_pct", prsLast14d = "prs_last_14d", mainLift = "main_lift"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(workoutsLast7d, forKey: .workoutsLast7d)
            try container.encode(workoutsPrev7d, forKey: .workoutsPrev7d)
            try container.encode(plannedPerWeek, forKey: .plannedPerWeek)
            try container.encode(volumeChangePct, forKey: .volumeChangePct)
            try container.encode(prsLast14d, forKey: .prsLast14d)
            try container.encode(mainLift, forKey: .mainLift)
        }
    }

    public struct Nutrition: Codable, Hashable, Sendable {
        public var daysLoggedLast7d: Int
        public var avgCalories: Double?
        public var targetCalories: Double
        public var avgProtein: Double?
        public var targetProtein: Double
        public var proteinDaysHit: Int

        enum CodingKeys: String, CodingKey {
            case daysLoggedLast7d = "days_logged_last_7d", avgCalories = "avg_calories", targetCalories = "target_calories"
            case avgProtein = "avg_protein", targetProtein = "target_protein", proteinDaysHit = "protein_days_hit"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(daysLoggedLast7d, forKey: .daysLoggedLast7d)
            try container.encode(avgCalories, forKey: .avgCalories)
            try container.encode(targetCalories, forKey: .targetCalories)
            try container.encode(avgProtein, forKey: .avgProtein)
            try container.encode(targetProtein, forKey: .targetProtein)
            try container.encode(proteinDaysHit, forKey: .proteinDaysHit)
        }
    }

    public struct Body: Codable, Hashable, Sendable {
        public var trendWeightNow: Double?
        public var trendWeight14dAgo: Double?
        public var weighInsLast14d: Int

        enum CodingKeys: String, CodingKey {
            case trendWeightNow = "trend_weight_now", trendWeight14dAgo = "trend_weight_14d_ago", weighInsLast14d = "weigh_ins_last_14d"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(trendWeightNow, forKey: .trendWeightNow)
            try container.encode(trendWeight14dAgo, forKey: .trendWeight14dAgo)
            try container.encode(weighInsLast14d, forKey: .weighInsLast14d)
        }
    }

    /// `yyyy-MM-dd`: the Gregorian date in the user's time zone, whatever
    /// calendar the device uses.
    public var date: String
    /// `build_muscle | lose_fat | gain_strength | maintain | recomposition`.
    public var goal: String
    /// `kg | lb`.
    public var unit: String
    public var training: Training
    public var nutrition: Nutrition
    public var body: Body
    public var recommendations: [String]

    /// False when the last two weeks hold no workouts, meals or weigh-ins:
    /// there is nothing to summarise, so the app doesn't ask.
    public var hasLoggedData: Bool {
        training.workoutsLast7d + training.workoutsPrev7d + nutrition.daysLoggedLast7d + body.weighInsLast14d > 0
    }

    public static let maxPRs = 5
    public static let maxRecommendations = 5
    /// In UTF-16 code units, as the server's validator (zod) counts them.
    public static let maxStringLength = 120

    /// Contract goal value. `improveFitness` (kept only so old profiles
    /// decode) is sent as `maintain`, which is its calorie direction.
    public static func goalValue(_ goal: TrainingGoal) -> String {
        switch goal {
        case .buildMuscle: "build_muscle"
        case .loseFat: "lose_fat"
        case .getStronger: "gain_strength"
        case .maintain, .improveFitness: "maintain"
        case .recomposition: "recomposition"
        }
    }

    /// The request body: `{"digest": {...}}`.
    public func requestBody() throws -> Data {
        struct Envelope: Encodable { var digest: CoachDigest }
        return try JSONEncoder().encode(Envelope(digest: self))
    }
}

/// Builds a `CoachDigest` from the same context the insight engine uses.
public struct CoachDigestBuilder: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar
    let analytics: AnalyticsEngine
    let nutrition: NutritionEngine
    let insights: InsightEngine
    let progression = ProgressionEngine()

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
        analytics = AnalyticsEngine(catalog: catalog, calendar: calendar)
        nutrition = NutritionEngine(calendar: calendar)
        insights = InsightEngine(catalog: catalog, calendar: calendar)
    }

    /// `recommendations` defaults to the insight engine's program recommendations.
    public func build(_ context: CoachContext, recommendations: [ProgressionRecommendation]? = nil) -> CoachDigest {
        let unit = context.profile.unit
        return CoachDigest(
            date: Self.dayString(context.now, calendar: calendar),
            goal: CoachDigest.goalValue(context.profile.goal),
            unit: unit == .kilograms ? "kg" : "lb",
            training: training(context),
            nutrition: nutritionDigest(context),
            body: body(context),
            recommendations: recommendationLines(recommendations ?? insights.programRecommendations(context), unit: unit)
        )
    }

    // MARK: Training

    func training(_ context: CoachContext) -> CoachDigest.Training {
        let unit = context.profile.unit
        let end = calendar.startOfDay(for: context.now).addingTimeInterval(86_400)
        let last7 = DateInterval(start: end.addingTimeInterval(-7 * 86_400), end: end)
        let prev7 = DateInterval(start: last7.start.addingTimeInterval(-7 * 86_400), end: last7.start)
        let finished = context.sessions.filter(\.isFinished)
        let summary = analytics.summary(context.sessions, range: .week, now: context.now)

        let since14 = end.addingTimeInterval(-14 * 86_400)
        let prs = analytics.personalRecords(context.sessions)
            .filter { $0.date >= since14 && $0.date < end }
            .prefix(CoachDigest.maxPRs)
            .map { CoachDigest.PR(exercise: Self.clip($0.exerciseName), weight: Self.weight($0.weight, unit: unit), reps: max($0.reps, 0)) }

        return CoachDigest.Training(
            workoutsLast7d: finished.filter { last7.contains($0.startedAt) }.count,
            workoutsPrev7d: finished.filter { prev7.contains($0.startedAt) }.count,
            plannedPerWeek: max(context.program?.daysPerWeek ?? context.profile.daysPerWeek, 0),
            volumeChangePct: summary.volumeChange.flatMap { $0.isFinite ? Self.round($0 * 100, places: 1) : nil },
            prsLast14d: Array(prs),
            mainLift: mainLift(context)
        )
    }

    /// The first lift of the next workout (as on Today), else the most
    /// trained compound lift. e1RM 30 days ago is the oldest performance in
    /// the last 30 days, matching the "up this month" line on Today.
    func mainLift(_ context: CoachContext) -> CoachDigest.MainLift? {
        let unit = context.profile.unit
        let planned = (context.program?.nextWorkout ?? context.program?.workouts.first)?.exercises.first?.exerciseID
        let candidates = [planned].compactMap { $0 } + analytics.trackedExercises(context.sessions).filter(\.isCompound).map(\.id)
        for id in candidates {
            let history = progression.history(for: id, in: context.sessions).filter { $0.date <= context.now }
            guard let latest = history.first, latest.estimatedOneRepMax > 0 else { continue }
            let monthAgo = context.now.addingTimeInterval(-30 * 86_400)
            let baseline = history.last { $0.date >= monthAgo }
            let before = baseline.flatMap { $0.sessionID == latest.sessionID || $0.estimatedOneRepMax <= 0 ? nil : $0 }
            return CoachDigest.MainLift(
                exercise: Self.clip(catalog[id]?.name ?? id),
                e1rmNow: Self.round(unit.fromKilograms(latest.estimatedOneRepMax), places: 1),
                e1rm30dAgo: before.map { Self.round(unit.fromKilograms($0.estimatedOneRepMax), places: 1) }
            )
        }
        return nil
    }

    // MARK: Nutrition

    /// The 7 complete days before today; today is still in progress.
    func nutritionDigest(_ context: CoachContext) -> CoachDigest.Nutrition {
        let targets = context.profile.targets
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: context.now)) ?? context.now
        let days = nutrition.loggedDays(context.foodEntries, days: 7, endingAt: yesterday, targets: targets)
        let count = Double(days.count)
        return CoachDigest.Nutrition(
            daysLoggedLast7d: days.count,
            avgCalories: days.isEmpty ? nil : Self.nonNegative((days.reduce(0) { $0 + $1.consumed.calories } / count).rounded()),
            targetCalories: Self.nonNegative(targets.calories.rounded()),
            avgProtein: days.isEmpty ? nil : Self.nonNegative((days.reduce(0) { $0 + $1.consumed.protein } / count).rounded()),
            targetProtein: Self.nonNegative(targets.protein.rounded()),
            proteinDaysHit: days.filter(\.hitProteinTarget).count
        )
    }

    // MARK: Body

    /// EWMA trend (the same one the body-weight chart draws). "Now" needs a
    /// weigh-in in the last 14 days; "14 days ago" needs one 14–28 days ago.
    func body(_ context: CoachContext) -> CoachDigest.Body {
        let unit = context.profile.unit
        let now = context.now
        let since14 = now.addingTimeInterval(-14 * 86_400)
        let since28 = now.addingTimeInterval(-28 * 86_400)
        let entries = context.bodyWeights
            .filter { $0.date <= now && $0.date >= now.addingTimeInterval(-90 * 86_400) && $0.kilograms > 0 }
            .sorted { $0.date < $1.date }
        let trend = analytics.smoothedTrend(entries.map { ChartPoint(date: $0.date, value: $0.kilograms) })
        let current = trend.last.flatMap { $0.date >= since14 ? $0 : nil }
        let earlier = trend.last { $0.date < since14 }.flatMap { $0.date >= since28 ? $0 : nil }
        return CoachDigest.Body(
            trendWeightNow: current.map { Self.round(unit.fromKilograms($0.value), places: 1) },
            trendWeight14dAgo: earlier.map { Self.round(unit.fromKilograms($0.value), places: 1) },
            weighInsLast14d: entries.filter { $0.date >= since14 }.count
        )
    }

    // MARK: Recommendations

    /// Concrete load changes only; "repeat" and "find your weight" add nothing to a summary.
    func recommendationLines(_ recommendations: [ProgressionRecommendation], unit: WeightUnit) -> [String] {
        recommendations.compactMap { rec -> String? in
            guard let weight = rec.weight, weight > 0 else { return nil }
            let name = catalog[rec.exerciseID]?.name ?? rec.exerciseID
            let load = "\(Self.plain(Self.weight(weight, unit: unit))) \(unit.symbol) × \(rec.reps)"
            let (prefix, suffix): (String, String)
            switch rec.action {
            case .increaseLoad: (prefix, suffix) = ("Increase ", " to \(load)")
            case .increaseReps: (prefix, suffix) = ("Add reps on ", ": \(load)")
            case .reduceLoad: (prefix, suffix) = ("Reduce ", " to \(load)")
            case .deload: (prefix, suffix) = ("Deload ", " to \(load)")
            case .repeatLoad, .establishBaseline: return nil
            }
            // Only the name is shortened, so the load and reps are never cut off.
            let budget = CoachDigest.maxStringLength - prefix.utf16.count - suffix.utf16.count
            let clippedName = Self.clip(name, limit: budget)
            guard !clippedName.isEmpty else { return nil }
            return prefix + clippedName + suffix
        }
        .prefix(CoachDigest.maxRecommendations)
        .map { $0 }
    }

    // MARK: Number hygiene

    /// `yyyy-MM-dd` of the Gregorian date in `calendar`'s time zone. The
    /// user's calendar may be Japanese, Buddhist, Hebrew and so on; only its
    /// time zone is used, so the year is never an era year.
    public static func dayString(_ date: Date, calendar: Calendar) -> String {
        dayString(date, timeZone: calendar.timeZone)
    }

    public static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A logged weight in the display unit: two decimals in kg (82.25), one in lb.
    static func weight(_ kilograms: Double, unit: WeightUnit) -> Double {
        nonNegative(round(unit.fromKilograms(kilograms), places: unit == .kilograms ? 2 : 1))
    }

    static func round(_ value: Double, places: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    static func nonNegative(_ value: Double) -> Double { value.isFinite ? max(value, 0) : 0 }

    /// Locale-independent number text ("82.5", "85"), so the server's
    /// numeric check reads exactly the digest's numbers.
    static func plain(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// At most `limit` UTF-16 code units (how the server counts), cut at a
    /// character boundary so an emoji or accented letter is never split.
    static func clip(_ text: String, limit: Int = CoachDigest.maxStringLength) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf16.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }
}
