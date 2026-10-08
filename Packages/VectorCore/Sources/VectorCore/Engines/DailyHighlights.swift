import Foundation

/// One positive, checkable fact from the user's own logs, shown at the top of
/// Today as "Today's insight". Every highlight is a comparison the user can
/// verify (this week against the same point last week, now against three
/// weeks ago), computed on device. Nothing is generated or invented: when no
/// fact passes the rules, there is no highlight and Today shows the workout first.
public struct DailyHighlight: Identifiable, Hashable, Sendable {
    public enum Fact: Hashable, Sendable {
        /// Working reps for one lift this week so far, against the same point last week.
        case liftReps(exerciseID: String, thisWeek: Int, lastWeek: Int)
        /// Heaviest completed working set now, against the heaviest `weeks` weeks ago.
        case liftGain(exerciseID: String, fromKilograms: Double, toKilograms: Double, weeks: Int)
        /// Training volume this week so far, against the same point last week.
        case weeklyVolume(thisWeek: Double, lastWeek: Double)
        /// Days among the last `of` (before today) with protein at or near target.
        case proteinDays(onTarget: Int, of: Int)
        /// A count of finished workouts, for users without enough history to compare.
        case milestone(workouts: Int)
    }

    public var fact: Fact

    public var id: String {
        switch fact {
        case .liftReps(let id, _, _): "lift-reps-\(id)"
        case .liftGain(let id, _, _, _): "lift-gain-\(id)"
        case .weeklyVolume: "weekly-volume"
        case .proteinDays: "protein-days"
        case .milestone(let count): "milestone-\(count)"
        }
    }

    public init(_ fact: Fact) {
        self.fact = fact
    }
}

public struct DailyHighlightEngine: Sendable {
    public let calendar: Calendar

    /// Today shows at most this many, one at a time.
    public static let maximum = 3
    /// Comparisons start once the first workout is this many days old.
    public static let historyDays = 14
    /// Smallest rises worth calling out.
    static let repsRise = 0.10
    static let volumeRise = 0.05
    static let minimumGainKilograms = 2.5
    /// A protein day counts when it reaches this share of the target.
    static let proteinShare = 0.9
    static let proteinDaysNeeded = 4

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Highlights for `now`, lead first. The lead rotates by day so the same
    /// kind of fact doesn't open Today two days running.
    public func highlights(sessions: [WorkoutSession], foodEntries: [FoodEntry], proteinTarget: Double,
                           now: Date) -> [DailyHighlight] {
        let finished = sessions.filter { $0.isFinished && $0.startedAt <= now }
        guard let first = finished.map(\.startedAt).min() else { return [] }

        let historyDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                                  to: calendar.startOfDay(for: now)).day ?? 0
        guard historyDays >= Self.historyDays else {
            return [DailyHighlight(.milestone(workouts: finished.count))]
        }

        var candidates: [DailyHighlight] = []
        if let window = weekWindows(now: now) {
            let thisWeek = finished.filter { window.thisWeek.contains($0.startedAt) }
            let lastWeek = finished.filter { window.lastWeek.contains($0.startedAt) }
            if let reps = liftReps(thisWeek: thisWeek, lastWeek: lastWeek) { candidates.append(reps) }
            if let volume = weeklyVolume(thisWeek: thisWeek, lastWeek: lastWeek) { candidates.append(volume) }
        }
        if let gain = liftGain(finished, now: now) { candidates.append(gain) }
        if let protein = proteinDays(foodEntries, target: proteinTarget, now: now) { candidates.append(protein) }

        guard !candidates.isEmpty else { return [] }
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        let offset = day % candidates.count
        let rotated = Array(candidates[offset...] + candidates[..<offset])
        return Array(rotated.prefix(Self.maximum))
    }

    // MARK: Rules

    /// This week from its start until now, and last week over the same span.
    func weekWindows(now: Date) -> (thisWeek: ClosedRange<Date>, lastWeek: ClosedRange<Date>)? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let lastStart = calendar.date(byAdding: .day, value: -7, to: week.start) else { return nil }
        let elapsed = now.timeIntervalSince(week.start)
        return (week.start...now, lastStart...lastStart.addingTimeInterval(elapsed))
    }

    func liftReps(thisWeek: [WorkoutSession], lastWeek: [WorkoutSession]) -> DailyHighlight? {
        let now = repsByExercise(thisWeek), before = repsByExercise(lastWeek)
        let rising = now.compactMap { id, reps -> (id: String, reps: Int, last: Int, rise: Double)? in
            guard let last = before[id], last > 0 else { return nil }
            let rise = Double(reps - last) / Double(last)
            return rise >= Self.repsRise ? (id, reps, last, rise) : nil
        }
        // Biggest rise first; more reps, then the id, break ties so the result is stable.
        guard let best = rising.max(by: { ($0.rise, $0.reps, $1.id) < ($1.rise, $1.reps, $0.id) }) else { return nil }
        return DailyHighlight(.liftReps(exerciseID: best.id, thisWeek: best.reps, lastWeek: best.last))
    }

    func weeklyVolume(thisWeek: [WorkoutSession], lastWeek: [WorkoutSession]) -> DailyHighlight? {
        let now = thisWeek.reduce(0) { $0 + $1.volume }, before = lastWeek.reduce(0) { $0 + $1.volume }
        guard before > 0, now >= before * (1 + Self.volumeRise) else { return nil }
        return DailyHighlight(.weeklyVolume(thisWeek: now, lastWeek: before))
    }

    /// Heaviest working set in the last two weeks against the heaviest from
    /// three to five weeks ago, for lifts trained in both windows.
    func liftGain(_ sessions: [WorkoutSession], now: Date) -> DailyHighlight? {
        let day: TimeInterval = 86_400
        let recent = sessions.filter { $0.startedAt > now.addingTimeInterval(-14 * day) }
        let earlier = sessions.filter {
            $0.startedAt > now.addingTimeInterval(-35 * day) && $0.startedAt <= now.addingTimeInterval(-21 * day)
        }
        let current = heaviest(recent), past = heaviest(earlier)
        let gains = current.compactMap { id, top -> (id: String, from: Double, to: Double)? in
            guard let from = past[id], top - from >= Self.minimumGainKilograms else { return nil }
            return (id, from, top)
        }
        guard let best = gains.max(by: { ($0.to - $0.from, $1.id) < ($1.to - $1.from, $0.id) }) else { return nil }
        return DailyHighlight(.liftGain(exerciseID: best.id, fromKilograms: best.from, toKilograms: best.to, weeks: 3))
    }

    func proteinDays(_ entries: [FoodEntry], target: Double, now: Date) -> DailyHighlight? {
        guard target > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let onTarget = (1...7).filter { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
            let protein = entries.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.macros.protein }
            return protein >= target * Self.proteinShare
        }.count
        guard onTarget >= Self.proteinDaysNeeded else { return nil }
        return DailyHighlight(.proteinDays(onTarget: onTarget, of: 7))
    }

    // MARK: Helpers

    func repsByExercise(_ sessions: [WorkoutSession]) -> [String: Int] {
        var result: [String: Int] = [:]
        for session in sessions {
            for log in session.exercises {
                result[log.exerciseID, default: 0] += log.completedWorkingSets.reduce(0) { $0 + $1.reps }
            }
        }
        return result.filter { $0.value > 0 }
    }

    func heaviest(_ sessions: [WorkoutSession]) -> [String: Double] {
        var result: [String: Double] = [:]
        for session in sessions {
            for log in session.exercises {
                guard let top = log.completedWorkingSets.map(\.weight).max(), top > 0 else { continue }
                result[log.exerciseID] = max(result[log.exerciseID] ?? 0, top)
            }
        }
        return result
    }
}
