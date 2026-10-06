import Foundation

/// Today's answer to "what should I do?", composed from the user's own data.
/// Each line only appears when the data behind it exists; nothing is padded
/// with generic advice.
public struct DailyBrief: Hashable, Sendable {
    public struct Line: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable { case training, nutrition, progress, bodyWeight }
        public var kind: Kind
        public var text: String
        public var evidence: [Evidence]
        public var id: String { kind.rawValue }
    }

    public var headline: String
    public var lines: [Line]

    /// The sentence form, as shown on Today.
    public var summary: String { ([headline] + lines.map(\.text)).joined(separator: " ") }
}

public struct DailyBriefEngine: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
    }

    public func brief(context: CoachContext, recommendations: [ProgressionRecommendation]) -> DailyBrief {
        let now = context.now
        let unit = context.profile.unit
        let finished = context.sessions.filter(\.isFinished)
        let trainedToday = finished.first { calendar.isDate($0.startedAt, inSameDayAs: now) }
        let next = context.program?.nextWorkout
        var lines: [DailyBrief.Line] = []

        // Headline + training line
        let headline: String
        if let trainedToday {
            headline = "\(trainedToday.name) done today."
        } else if let next {
            headline = "\(next.name) today."
            if let main = next.exercises.first, let exercise = catalog[main.exerciseID],
               let rec = recommendations.first(where: { $0.exerciseID == main.exerciseID }),
               let weight = rec.weight, weight > 0, rec.action != .establishBaseline {
                let reps = main.repRange.isFixed ? "\(rec.reps)" : "\(rec.reps)–\(main.repRange.upper)"
                lines.append(.init(kind: .training,
                                   text: "Start \(exercise.name.lowercased()) at \(Format.weight(weight, unit: unit)) × \(reps) on your first working set.",
                                   evidence: [Evidence("Why", rec.reason)] + rec.evidence))
            }
        } else {
            headline = "Rest day."
        }

        // Protein: last 7 complete days, then what's left today.
        let nutrition = NutritionEngine(calendar: calendar)
        let targets = context.profile.targets
        let past = nutrition.loggedDays(context.foodEntries, days: 8, endingAt: now, targets: targets)
            .filter { !calendar.isDate($0.date, inSameDayAs: now) && $0.consumed.calories >= AdaptiveNutritionEngine.completeDayCalories }
        let today = nutrition.daily(context.foodEntries, on: now, targets: targets)
        let remaining = max(targets.protein - today.consumed.protein, 0)
        if past.count >= 3 {
            let average = past.reduce(0) { $0 + $1.consumed.protein } / Double(past.count)
            let evidence = [Evidence("7-day average", Format.grams(average)), Evidence("Target", Format.grams(targets.protein)),
                            Evidence("Today so far", Format.grams(today.consumed.protein))]
            if average < targets.protein * 0.9 {
                lines.append(.init(kind: .nutrition,
                                   text: "You averaged \(Format.grams(average)) protein over the last \(past.count) days, below your \(Format.grams(targets.protein)) target." +
                                       (remaining > 0 ? " Aim for another \(Format.grams(remaining)) today." : ""),
                                   evidence: evidence))
            } else if remaining > 0 {
                lines.append(.init(kind: .nutrition, text: "\(Format.grams(remaining)) protein to go today to stay on your streak.", evidence: evidence))
            }
        } else if remaining > 0, today.consumed.calories > 0 {
            lines.append(.init(kind: .nutrition, text: "\(Format.grams(remaining)) protein left to hit \(Format.grams(targets.protein)) today.",
                               evidence: [Evidence("Today so far", Format.grams(today.consumed.protein))]))
        }

        // Strength: main lift of the next workout, estimated 1RM change over ~30 days.
        if let liftID = (next ?? context.program?.workouts.first)?.exercises.first?.exerciseID, let lift = catalog[liftID] {
            let history = ProgressionEngine().history(for: liftID, in: finished)
            let monthAgo = now.addingTimeInterval(-30 * 86_400)
            if let latest = history.first, let baseline = history.last(where: { $0.date >= monthAgo }), latest.sessionID != baseline.sessionID {
                let delta = latest.estimatedOneRepMax - baseline.estimatedOneRepMax
                if delta >= 2.5 {
                    lines.append(.init(kind: .progress,
                                       text: "Your \(lift.name.lowercased()) estimated 1RM is up \(Format.estimate(delta, unit: unit)) this month.",
                                       evidence: [Evidence(Format.shortDate(baseline.date, calendar: calendar), Format.estimate(baseline.estimatedOneRepMax, unit: unit)),
                                                  Evidence(Format.shortDate(latest.date, calendar: calendar), Format.estimate(latest.estimatedOneRepMax, unit: unit))]))
                }
            }
        }

        // Body weight: trend over the last 3 weeks, framed against the goal.
        let recent = context.bodyWeights.filter { $0.date >= now.addingTimeInterval(-21 * 86_400) }.sorted { $0.date < $1.date }
        if recent.count >= 5 {
            let trend = AnalyticsEngine(calendar: calendar).smoothedTrend(recent.map { ChartPoint(date: $0.date, value: $0.kilograms) })
            if let first = trend.first, let last = trend.last {
                let change = last.value - first.value
                let text = abs(change) < 0.3
                    ? "Trend weight steady at \(Format.estimate(last.value, unit: unit))."
                    : "Trend weight \(Format.estimate(first.value, unit: unit)) → \(Format.estimate(last.value, unit: unit)) over 3 weeks."
                lines.append(.init(kind: .bodyWeight, text: text,
                                   evidence: [Evidence("Weigh-ins", "\(recent.count)"), Evidence("Goal", context.profile.goal.title)]))
            }
        }

        return DailyBrief(headline: headline, lines: Array(lines.prefix(4)))
    }
}
