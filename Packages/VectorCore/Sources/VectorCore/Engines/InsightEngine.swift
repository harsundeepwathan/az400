import Foundation

public struct CoachInsight: Identifiable, Hashable, Sendable {
    public enum Category: String, Hashable, Sendable { case training, nutrition, recovery, progress }
    public enum Tone: String, Hashable, Sendable { case positive, neutral, attention }

    public enum Action: Hashable, Sendable {
        case startWorkout
        case openExercise(String)
        case logFood
        case reviewProgressions
        case viewProgress
        case viewMuscleBalance
    }

    /// Stable identifier (kind + subject) so dismissals persist across launches.
    public var id: String
    public var category: Category
    public var tone: Tone
    public var title: String
    public var message: String
    /// The data the insight is derived from. Always shown.
    public var evidence: [Evidence]
    public var suggestion: String?
    public var action: Action?
    public var actionTitle: String?
    /// Higher first.
    public var priority: Int
    /// Pro insights can be teased to free users but the detail is gated.
    public var requiresPro: Bool

    public init(id: String, category: Category, tone: Tone, title: String, message: String, evidence: [Evidence],
                suggestion: String? = nil, action: Action? = nil, actionTitle: String? = nil,
                priority: Int, requiresPro: Bool) {
        self.id = id
        self.category = category
        self.tone = tone
        self.title = title
        self.message = message
        self.evidence = evidence
        self.suggestion = suggestion
        self.action = action
        self.actionTitle = actionTitle
        self.priority = priority
        self.requiresPro = requiresPro
    }

    public var symbol: String {
        switch category {
        case .training: "figure.strengthtraining.traditional"
        case .nutrition: "fork.knife"
        case .recovery: "bed.double"
        case .progress: "chart.line.uptrend.xyaxis"
        }
    }
}

public struct CoachContext: Sendable {
    public var sessions: [WorkoutSession]
    public var foodEntries: [FoodEntry]
    public var bodyWeights: [BodyWeightEntry]
    public var program: TrainingProgram?
    public var profile: UserProfile
    public var now: Date

    public init(sessions: [WorkoutSession], foodEntries: [FoodEntry], bodyWeights: [BodyWeightEntry],
                program: TrainingProgram?, profile: UserProfile, now: Date) {
        self.sessions = sessions
        self.foodEntries = foodEntries
        self.bodyWeights = bodyWeights
        self.program = program
        self.profile = profile
        self.now = now
    }
}

/// Deterministic, explainable coaching rules. A language model may rephrase
/// these for tone, but every claim originates here with its evidence attached,
/// so the coach never states something the data does not support.
public struct InsightEngine: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar
    let analytics: AnalyticsEngine
    let progression = ProgressionEngine()
    let nutrition: NutritionEngine

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
        analytics = AnalyticsEngine(catalog: catalog, calendar: calendar)
        nutrition = NutritionEngine(calendar: calendar)
    }

    public func insights(_ context: CoachContext) -> [CoachInsight] {
        var result: [CoachInsight] = []
        result += templateVolumeTrend(context)
        result += proteinStreak(context)
        result += proteinShortfall(context)
        result += muscleImbalance(context)
        result += performanceDecline(context)
        result += progressionOpportunities(context)
        result += trainingGap(context)
        result += bodyWeightTrend(context)
        return result.sorted { $0.priority > $1.priority }
    }

    /// Recommendations for every exercise in the program, keyed by exercise id.
    public func programRecommendations(_ context: CoachContext) -> [ProgressionRecommendation] {
        guard let program = context.program else { return [] }
        var seen = Set<String>()
        var result: [ProgressionRecommendation] = []
        for template in program.upcoming {
            for item in template.exercises where seen.insert(item.exerciseID).inserted {
                guard let exercise = catalog[item.exerciseID] else { continue }
                let history = progression.history(for: item.exerciseID, in: context.sessions)
                result.append(progression.recommend(for: exercise, repRange: item.repRange, sets: item.sets,
                                                    history: history, unit: context.profile.unit))
            }
        }
        return result
    }

    // MARK: Rules

    func templateVolumeTrend(_ context: CoachContext) -> [CoachInsight] {
        // Prefer the workout that's up next, since that's what the user is about to train.
        let finished = context.sessions.filter(\.isFinished).sorted { $0.startedAt > $1.startedAt }
        guard let templateID = context.program?.nextWorkout?.id ?? finished.first?.templateID,
              let latest = finished.first(where: { $0.templateID == templateID }) else { return [] }
        let sameTemplate = finished.filter { $0.templateID == templateID }.prefix(3)
        guard sameTemplate.count == 3 else { return [] }

        // Lead with the template's first (main) lift when it has data.
        let mainID = latest.exercises.first?.exerciseID
        if let mainID, let name = catalog[mainID]?.name {
            let volumes = sameTemplate.map { $0.log(for: mainID)?.volume ?? 0 }
            if let oldest = volumes.last, oldest > 0, volumes[0] > 0 {
                let change = (volumes[0] - oldest) / oldest
                let up = change > 0
                // Small dips are normal session-to-session noise; only flag real drops.
                if up ? change >= 0.03 : change <= -0.08 {
                    let lift = name.lowercased()
                    return [CoachInsight(
                        id: "volume-trend-\(templateID)-\(mainID)",
                        category: .progress,
                        tone: up ? .positive : .attention,
                        title: up ? "Volume is climbing" : "Volume is slipping",
                        message: "Your \(lift) volume \(up ? "increased" : "decreased") \(Format.signedPercent(abs(change)).dropFirst()) over your last three \(latest.name) sessions.",
                        evidence: sameTemplate.reversed().map {
                            Evidence(Format.shortDate($0.startedAt, calendar: calendar),
                                     Format.volume($0.log(for: mainID)?.volume ?? 0, unit: context.profile.unit))
                        },
                        action: .openExercise(mainID),
                        actionTitle: "View \(name)",
                        priority: up ? 50 : 65,
                        requiresPro: false
                    )]
                }
            }
        }
        return []
    }

    func proteinStreak(_ context: CoachContext) -> [CoachInsight] {
        let targets = context.profile.targets
        let streak = nutrition.proteinStreak(context.foodEntries, now: context.now, targets: targets)
        guard streak >= 3 else { return [] }
        let days = nutrition.loggedDays(context.foodEntries, days: streak + 1, endingAt: context.now, targets: targets)
            .filter(\.hitProteinTarget)
            .suffix(min(streak, 5))
        return [CoachInsight(
            id: "protein-streak-\(streak)",
            category: .nutrition,
            tone: .positive,
            title: "Protein streak",
            message: "You've hit your protein target \(streak) days in a row.",
            evidence: days.map { Evidence(Format.shortDate($0.date, calendar: calendar), Format.grams($0.consumed.protein)) }
                + [Evidence("Target", Format.grams(targets.protein))],
            priority: 45,
            requiresPro: false
        )]
    }

    func proteinShortfall(_ context: CoachContext) -> [CoachInsight] {
        let targets = context.profile.targets
        let days = nutrition.loggedDays(context.foodEntries, days: 7, endingAt: context.now, targets: targets)
            .filter { !calendar.isDate($0.date, inSameDayAs: context.now) }
        guard days.count >= 3 else { return [] }
        let average = days.reduce(0) { $0 + $1.consumed.protein } / Double(days.count)
        guard average < targets.protein * 0.85 else { return [] }
        let gap = targets.protein - average
        return [CoachInsight(
            id: "protein-shortfall",
            category: .nutrition,
            tone: .attention,
            title: "Protein is running low",
            message: "You've averaged only \(Format.grams(average)) protein against your \(Format.grams(targets.protein)) target this week.",
            evidence: [
                Evidence("Days logged", "\(days.count)"),
                Evidence("Average", Format.grams(average)),
                Evidence("Target", Format.grams(targets.protein)),
                Evidence("Days on target", "\(days.filter(\.hitProteinTarget).count) of \(days.count)")
            ],
            suggestion: "Adding a \(Format.grams(min(gap, 40))) protein serving (e.g. \(DietaryPreference.proteinExamples(for: context.profile.dietaryPreferences ?? []))) closes most of the gap.",
            action: .logFood,
            actionTitle: "Log food",
            priority: 70,
            requiresPro: true
        )]
    }

    func muscleImbalance(_ context: CoachContext) -> [CoachInsight] {
        let end = calendar.startOfDay(for: context.now).addingTimeInterval(86_400)
        let recentStart = end.addingTimeInterval(-28 * 86_400)
        let recent = analytics.averageWeeklySets(context.sessions, weeks: 4, endingAt: end)
        let prior = analytics.averageWeeklySets(context.sessions, weeks: 4, endingAt: recentStart)
        let pairs: [(MuscleGroup, MuscleGroup)] = [(.chest, .back), (.back, .chest), (.quads, .hamstrings), (.hamstrings, .quads)]
        for (grown, flat) in pairs {
            guard let before = prior[grown], before >= 2, let now = recent[grown] else { continue }
            let growth = (now - before) / before
            let flatBefore = prior[flat] ?? 0
            let flatNow = recent[flat] ?? 0
            let flatChange = flatBefore > 0 ? (flatNow - flatBefore) / flatBefore : 0
            guard growth >= 0.2, flatChange <= 0.05 else { continue }
            return [CoachInsight(
                id: "imbalance-\(grown.rawValue)-\(flat.rawValue)",
                category: .training,
                tone: .neutral,
                title: "\(grown.displayName) is outpacing \(flat.displayName.lowercased())",
                message: "Your \(grown.displayName.lowercased()) volume has increased \(Int((growth * 100).rounded()))% over four weeks while \(flat.displayName.lowercased()) volume remained flat.",
                evidence: [
                    Evidence("\(grown.displayName) sets / week", "\(Format.number1(before)) → \(Format.number1(now))"),
                    Evidence("\(flat.displayName) sets / week", "\(Format.number1(flatBefore)) → \(Format.number1(flatNow))")
                ],
                suggestion: "Add 2–3 \(flat.displayName.lowercased()) sets per week to keep the ratio balanced.",
                action: .viewMuscleBalance,
                actionTitle: "See muscle balance",
                priority: 55,
                requiresPro: true
            )]
        }
        return []
    }

    func performanceDecline(_ context: CoachContext) -> [CoachInsight] {
        let declining = analytics.trackedExercises(context.sessions).filter(\.isCompound).compactMap { exercise -> (Exercise, [Double])? in
            let history = progression.history(for: exercise.id, in: context.sessions).prefix(3).map(\.estimatedOneRepMax)
            guard history.count == 3, history[0] < history[1], history[1] < history[2] else { return nil }
            return (exercise, Array(history.reversed()))
        }
        guard !declining.isEmpty else { return [] }
        let names = declining.prefix(2).map(\.0.name)
        let subject = declining.count == 1 ? names[0] : names.joined(separator: " and ")
        return [CoachInsight(
            id: "decline-" + declining.map(\.0.id).joined(separator: "-"),
            category: .recovery,
            tone: .attention,
            title: "Consider a deload",
            message: "Your performance on \(subject) has declined across three sessions.",
            evidence: declining.prefix(3).map { exercise, values in
                Evidence("\(exercise.name) e1RM", values.map { Format.estimate($0, unit: context.profile.unit, includeUnit: false) }
                    .joined(separator: " → ") + " " + context.profile.unit.symbol)
            },
            suggestion: "Train at ~90% of your working weights for one week, then resume. Check sleep and calories too.",
            priority: 80,
            requiresPro: true
        )]
    }

    func progressionOpportunities(_ context: CoachContext) -> [CoachInsight] {
        let increases = programRecommendations(context).filter { $0.action == .increaseLoad }
        guard !increases.isEmpty else { return [] }
        return [CoachInsight(
            id: "progressions-\(increases.count)",
            category: .training,
            tone: .positive,
            title: "You're getting stronger",
            message: "We found \(increases.count) progression \(increases.count == 1 ? "opportunity" : "opportunities") based on your training.",
            evidence: increases.prefix(4).compactMap { rec in
                guard let name = catalog[rec.exerciseID]?.name, let weight = rec.weight else { return nil }
                return Evidence(name, "\(Format.weight(weight, unit: context.profile.unit)) × \(rec.reps)")
            },
            action: .reviewProgressions,
            actionTitle: "See recommendations",
            priority: 60,
            requiresPro: true
        )]
    }

    func trainingGap(_ context: CoachContext) -> [CoachInsight] {
        guard let last = context.sessions.filter(\.isFinished).map(\.startedAt).max() else { return [] }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: context.now)).day ?? 0
        let expectedGap = Int((7.0 / Double(max(context.profile.daysPerWeek, 1))).rounded(.up))
        guard days > expectedGap + 2 else { return [] }
        let next = context.program?.nextWorkout?.name ?? "your next session"
        return [CoachInsight(
            id: "gap-\(days)",
            category: .training,
            tone: .neutral,
            title: "Time to get back in",
            message: "It's been \(days) days since your last session. \(next) is up next. Even a shorter session keeps momentum.",
            evidence: [Evidence("Last workout", Format.relativeDays(from: last, to: context.now, calendar: calendar)),
                       Evidence("Plan", "\(context.profile.daysPerWeek) days / week")],
            action: .startWorkout,
            actionTitle: "Start \(next)",
            priority: 75,
            requiresPro: false
        )]
    }

    func bodyWeightTrend(_ context: CoachContext) -> [CoachInsight] {
        let start = context.now.addingTimeInterval(-21 * 86_400)
        let entries = context.bodyWeights.filter { $0.date >= start }.sorted { $0.date < $1.date }
        guard entries.count >= 6 else { return [] }
        let trend = analytics.smoothedTrend(entries.map { ChartPoint(date: $0.date, value: $0.kilograms) })
        guard let first = trend.first, let last = trend.last else { return [] }
        let weeks = max(last.date.timeIntervalSince(first.date) / (7 * 86_400), 1)
        let weekly = (last.value - first.value) / weeks
        let rate = weekly / first.value
        let unit = context.profile.unit
        let goal = context.profile.nutritionGoal
        let onTrack: Bool
        switch goal {
        case .lose: onTrack = rate <= -0.0025 && rate >= -0.01
        case .gain: onTrack = rate >= 0.001 && rate <= 0.005
        case .maintain: onTrack = abs(rate) < 0.003
        }
        let direction = weekly >= 0 ? "+" : "\u{2212}"
        return [CoachInsight(
            id: "bodyweight-\(goal.rawValue)-\(onTrack)",
            category: .progress,
            tone: onTrack ? .positive : .neutral,
            title: onTrack ? "Weight trend is on track" : "Weight trend needs attention",
            message: "Your trend weight is moving \(direction)\(Format.weight((abs(weekly) * 100).rounded() / 100, unit: unit)) per week. "
                + (onTrack ? "That's right in the range for your goal to \(goal.title.lowercased())." : "Consider adjusting calories by about 150–200 kcal."),
            evidence: [Evidence("Trend start", Format.estimate(first.value, unit: unit)),
                       Evidence("Trend now", Format.estimate(last.value, unit: unit)),
                       Evidence("Weekly rate", Format.signedPercent(rate) + " of body weight")],
            action: .viewProgress,
            actionTitle: "View body weight",
            priority: onTrack ? 30 : 58,
            requiresPro: true
        )]
    }
}
