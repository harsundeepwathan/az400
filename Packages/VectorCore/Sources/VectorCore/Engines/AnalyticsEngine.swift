import Foundation

public enum TimeRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case week, month, threeMonths, sixMonths, year, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: "7D"
        case .month: "1M"
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .year: "1Y"
        case .all: "ALL"
        }
    }

    public var comparisonLabel: String {
        switch self {
        case .week: "vs previous week"
        case .month: "vs previous month"
        case .threeMonths: "vs previous 3 months"
        case .sixMonths: "vs previous 6 months"
        case .year: "vs previous year"
        case .all: "all time"
        }
    }

    /// Ranges beyond the free history window require Pro.
    public var requiresPro: Bool { self == .sixMonths || self == .year || self == .all }

    /// Granularity used when bucketing chart data.
    public var bucket: Calendar.Component { self == .week || self == .month ? .day : .weekOfYear }

    public func interval(endingAt now: Date, calendar: Calendar = .current, earliest: Date? = nil) -> DateInterval {
        let end = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let start: Date
        switch self {
        case .week: start = calendar.date(byAdding: .day, value: -7, to: end)!
        case .month: start = calendar.date(byAdding: .month, value: -1, to: end)!
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: end)!
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: end)!
        case .year: start = calendar.date(byAdding: .year, value: -1, to: end)!
        case .all: start = calendar.startOfDay(for: min(earliest ?? end.addingTimeInterval(-86_400), end.addingTimeInterval(-86_400)))
        }
        return DateInterval(start: start, end: end)
    }

    /// The equally long window immediately before `interval`.
    public func previous(_ interval: DateInterval) -> DateInterval? {
        guard self != .all else { return nil }
        return DateInterval(start: interval.start.addingTimeInterval(-interval.duration), end: interval.start)
    }
}

public struct TrainingSummary: Hashable, Sendable {
    public var workouts: Int
    public var volume: Double
    public var sets: Int
    public var averageDuration: TimeInterval
    /// Fractional change vs. the previous equal window; nil without a baseline.
    public var volumeChange: Double?
    /// New heaviest working sets in the window.
    public var personalRecords: Int

    public var isEmpty: Bool { workouts == 0 }
}

public struct ChartPoint: Identifiable, Hashable, Sendable {
    public var date: Date
    public var value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct MuscleVolume: Identifiable, Hashable, Sendable {
    public var muscle: MuscleGroup
    /// Hard sets in the window. Secondary muscles count as half a set.
    public var sets: Double
    public var previousSets: Double
    public var id: MuscleGroup { muscle }

    /// Evidence-based hypertrophy range for weekly hard sets.
    public static let recommendedWeeklySets: ClosedRange<Double> = 10...20

    public enum Status: Hashable, Sendable { case low, optimal, high }

    public var status: Status {
        if sets < Self.recommendedWeeklySets.lowerBound { return .low }
        if sets > Self.recommendedWeeklySets.upperBound { return .high }
        return .optimal
    }

    public var change: Double? { previousSets > 0 ? (sets - previousSets) / previousSets : nil }
}

public struct PersonalRecord: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case weight, reps }

    public var id: String { "\(sessionID)-\(exerciseID)" }
    public var sessionID: UUID
    public var exerciseID: String
    public var exerciseName: String
    public var date: Date
    public var weight: Double
    public var reps: Int
    public var kind: Kind
    /// Improvement over the previous best: kilograms for `.weight`, reps for `.reps`.
    public var improvement: Double

    public func improvementLabel(unit: WeightUnit = .kilograms) -> String {
        switch kind {
        case .weight: "+" + Format.weight(improvement, unit: unit)
        case .reps: "+\(Int(improvement)) rep" + (improvement == 1 ? "" : "s")
        }
    }
}

public struct AnalyticsEngine: Sendable {
    public let catalog: ExerciseCatalog
    public let calendar: Calendar

    public init(catalog: ExerciseCatalog = .standard, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
    }

    func finished(_ sessions: [WorkoutSession], in interval: DateInterval?) -> [WorkoutSession] {
        sessions
            .filter { $0.isFinished && (interval?.contains($0.startedAt) ?? true) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Summary

    public func summary(_ sessions: [WorkoutSession], range: TimeRange, now: Date) -> TrainingSummary {
        let earliest = sessions.map(\.startedAt).min()
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: earliest)
        let current = finished(sessions, in: interval)
        let volume = current.reduce(0) { $0 + $1.volume }
        var change: Double?
        if let previousInterval = range.previous(interval) {
            let previousVolume = finished(sessions, in: previousInterval).reduce(0) { $0 + $1.volume }
            if previousVolume > 0 { change = (volume - previousVolume) / previousVolume }
        }
        // The headline count uses weight PRs only; rep PRs still appear in the PR list.
        let prs = personalRecords(sessions).filter { interval.contains($0.date) && $0.kind == .weight }.count
        let durations = current.map(\.duration)
        return TrainingSummary(
            workouts: current.count,
            volume: volume,
            sets: current.reduce(0) { $0 + $1.completedSetCount },
            averageDuration: durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count),
            volumeChange: change,
            personalRecords: prs
        )
    }

    // MARK: Series

    private func bucketStart(_ date: Date, component: Calendar.Component) -> Date {
        if component == .day { return calendar.startOfDay(for: date) }
        return calendar.dateInterval(of: component, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Every bucket in the window, so charts show gaps as zeroes rather than
    /// silently connecting distant points.
    private func buckets(for interval: DateInterval, component: Calendar.Component) -> [Date] {
        var result: [Date] = []
        var cursor = bucketStart(interval.start, component: component)
        while cursor < interval.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func series(_ sessions: [WorkoutSession], range: TimeRange, now: Date, value: (WorkoutSession) -> Double) -> [ChartPoint] {
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: sessions.map(\.startedAt).min())
        let component = range.bucket
        var totals: [Date: Double] = [:]
        for session in finished(sessions, in: interval) {
            totals[bucketStart(session.startedAt, component: component), default: 0] += value(session)
        }
        return buckets(for: interval, component: component).map { ChartPoint(date: $0, value: totals[$0] ?? 0) }
    }

    public func volumeSeries(_ sessions: [WorkoutSession], range: TimeRange, now: Date) -> [ChartPoint] {
        series(sessions, range: range, now: now) { $0.volume }
    }

    /// Workouts per week across the window (always weekly buckets).
    public func frequencySeries(_ sessions: [WorkoutSession], range: TimeRange, now: Date) -> [ChartPoint] {
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: sessions.map(\.startedAt).min())
        var totals: [Date: Double] = [:]
        for session in finished(sessions, in: interval) {
            totals[bucketStart(session.startedAt, component: .weekOfYear), default: 0] += 1
        }
        return buckets(for: interval, component: .weekOfYear).map { ChartPoint(date: $0, value: totals[$0] ?? 0) }
    }

    /// Best estimated 1RM per session for an exercise.
    public func strengthSeries(_ sessions: [WorkoutSession], exerciseID: String, range: TimeRange, now: Date) -> [ChartPoint] {
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: sessions.map(\.startedAt).min())
        return finished(sessions, in: interval).compactMap { session in
            guard let log = session.log(for: exerciseID), log.bestEstimatedOneRepMax > 0 else { return nil }
            return ChartPoint(date: session.startedAt, value: log.bestEstimatedOneRepMax)
        }
    }

    public func bodyWeightSeries(_ entries: [BodyWeightEntry], range: TimeRange, now: Date) -> [ChartPoint] {
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: entries.map(\.date).min())
        return entries
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
            .map { ChartPoint(date: $0.date, value: $0.kilograms) }
    }

    /// 7-day exponentially weighted trend, which hides daily water noise the
    /// way serious nutrition apps do.
    public func smoothedTrend(_ points: [ChartPoint], alpha: Double = 0.25) -> [ChartPoint] {
        var result: [ChartPoint] = []
        var trend: Double?
        for point in points {
            let next = trend.map { $0 + alpha * (point.value - $0) } ?? point.value
            trend = next
            result.append(ChartPoint(date: point.date, value: next))
        }
        return result
    }

    /// Exercises with logged history, most frequently trained first.
    public func trackedExercises(_ sessions: [WorkoutSession]) -> [Exercise] {
        var counts: [String: Int] = [:]
        for session in sessions where session.isFinished {
            for log in session.exercises where !log.completedWorkingSets.isEmpty {
                counts[log.exerciseID, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .compactMap { catalog[$0.key] }
    }

    // MARK: Muscles

    public func weeklySetsPerMuscle(_ sessions: [WorkoutSession], now: Date) -> [MuscleVolume] {
        let end = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let current = DateInterval(start: end.addingTimeInterval(-7 * 86_400), end: end)
        let previous = DateInterval(start: current.start.addingTimeInterval(-7 * 86_400), end: current.start)
        let now = sets(finished(sessions, in: current))
        let before = sets(finished(sessions, in: previous))
        return MuscleGroup.analyticsOrder.map {
            MuscleVolume(muscle: $0, sets: now[$0] ?? 0, previousSets: before[$0] ?? 0)
        }
    }

    /// Average weekly sets per muscle over `weeks` weeks ending at `end`.
    public func averageWeeklySets(_ sessions: [WorkoutSession], weeks: Int, endingAt end: Date) -> [MuscleGroup: Double] {
        let interval = DateInterval(start: end.addingTimeInterval(-Double(weeks) * 7 * 86_400), end: end)
        return sets(finished(sessions, in: interval)).mapValues { $0 / Double(weeks) }
    }

    func sets(_ sessions: [WorkoutSession]) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for session in sessions {
            for log in session.exercises {
                guard let exercise = catalog[log.exerciseID] else { continue }
                let count = Double(log.completedWorkingSets.count)
                for muscle in exercise.primaryMuscles { result[muscle, default: 0] += count }
                for muscle in exercise.secondaryMuscles { result[muscle, default: 0] += count * 0.5 }
            }
        }
        return result
    }

    // MARK: Personal records

    /// Chronological sweep. The first time an exercise is logged sets the
    /// baseline and is not itself a PR. After that a heavier working set is a
    /// weight PR, and more reps at the best weight is a rep PR. Each exercise
    /// can produce at most one PR per session (its best one).
    public func personalRecords(_ sessions: [WorkoutSession]) -> [PersonalRecord] {
        struct Best { var weight: Double; var reps: Int }
        var bests: [String: Best] = [:]
        var records: [PersonalRecord] = []

        for session in finished(sessions, in: nil) {
            for log in session.exercises {
                guard let top = log.heaviestSet else { continue }
                let name = catalog[log.exerciseID]?.name ?? log.exerciseID
                guard let best = bests[log.exerciseID] else {
                    bests[log.exerciseID] = Best(weight: top.weight, reps: top.reps)
                    continue
                }
                if top.weight > best.weight {
                    records.append(PersonalRecord(sessionID: session.id, exerciseID: log.exerciseID, exerciseName: name,
                                                  date: session.startedAt, weight: top.weight, reps: top.reps,
                                                  kind: .weight, improvement: top.weight - best.weight))
                    bests[log.exerciseID] = Best(weight: top.weight, reps: top.reps)
                } else if top.weight == best.weight, top.reps > best.reps {
                    records.append(PersonalRecord(sessionID: session.id, exerciseID: log.exerciseID, exerciseName: name,
                                                  date: session.startedAt, weight: top.weight, reps: top.reps,
                                                  kind: .reps, improvement: Double(top.reps - best.reps)))
                    bests[log.exerciseID] = Best(weight: top.weight, reps: top.reps)
                }
            }
        }
        return records.sorted { $0.date > $1.date }
    }

    /// PRs a just-finished session would set against prior history.
    public func personalRecords(for session: WorkoutSession, history: [WorkoutSession]) -> [PersonalRecord] {
        let prior = history.filter { $0.id != session.id && $0.startedAt < session.startedAt }
        return personalRecords(prior + [session]).filter { $0.sessionID == session.id }
    }

    /// Most recent finished session from the same template, before `date`.
    /// Exercise ids from finished sessions, most recently trained first, without duplicates.
    public func recentExerciseIDs(_ sessions: [WorkoutSession], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions.filter(\.isFinished).sorted(by: { $0.startedAt > $1.startedAt }) {
            for log in session.exercises where seen.insert(log.exerciseID).inserted {
                result.append(log.exerciseID)
                if result.count == limit { return result }
            }
        }
        return result
    }

    public func previousSession(templateID: UUID?, before date: Date, in sessions: [WorkoutSession]) -> WorkoutSession? {
        guard let templateID else { return nil }
        return sessions
            .filter { $0.isFinished && $0.templateID == templateID && $0.startedAt < date }
            .max { $0.startedAt < $1.startedAt }
    }
}
