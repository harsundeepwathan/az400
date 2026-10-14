import Foundation

/// Percentage-based warm-up sets for a lift with external load: the empty bar,
/// then about 50%, 70% and 85% of the first working weight with falling reps.
/// Loads round down to the plate step; a ramp set is dropped when it would
/// not sit between the previous one and the working weight.
public struct WarmupPlanner: Sendable {
    /// The empty bar in kilograms.
    public var bar: Double
    /// The smallest load increase available (2.5 kg, or 5 lb in kilograms).
    public var step: Double

    public init(bar: Double = 20, step: Double = 2.5) {
        self.bar = bar
        self.step = step
    }

    static let ramp: [(fraction: Double, reps: Int)] = [(0.5, 8), (0.7, 5), (0.85, 3)]

    /// Warm-up sets (kind `.warmup`) leading up to `workingWeight`; empty when
    /// the working weight is at or below the empty bar.
    public func warmups(forWorkingWeight workingWeight: Double) -> [SetLog] {
        guard workingWeight > bar, step > 0 else { return [] }
        var loads: [(Double, Int)] = []
        if workingWeight >= bar * 2 { loads.append((bar, 10)) }
        for (fraction, reps) in Self.ramp {
            let load = (workingWeight * fraction / step).rounded(.down) * step
            let previous = loads.last?.0 ?? 0
            guard load >= bar, workingWeight > load, load > previous else { continue }
            loads.append((load, reps))
        }
        return loads.map { SetLog(kind: .warmup, weight: $0.0, reps: $0.1) }
    }
}

extension ActiveWorkout {
    /// Puts warm-up sets before an exercise's first working set, worked out
    /// from that set's load. Does nothing when the exercise already has
    /// warm-ups or no working load yet.
    public mutating func addWarmups(toExercise index: Int, planner: WarmupPlanner = WarmupPlanner()) {
        guard session.exercises.indices.contains(index) else { return }
        let sets = session.exercises[index].sets
        guard !sets.contains(where: { $0.kind == .warmup }),
              let first = sets.first(where: { $0.kind != .warmup }) else { return }
        let warmups = planner.warmups(forWorkingWeight: max(first.weight, first.targetWeight ?? 0))
        guard !warmups.isEmpty else { return }
        session.exercises[index].sets.insert(contentsOf: warmups, at: 0)
        // Warm-ups come first, so an exercise that hasn't started yet starts with them.
        if focus?.exercise == index, !sets.contains(where: \.isCompleted) {
            focus = SetPosition(exercise: index, set: 0)
        } else if let current = focus, current.exercise == index {
            focus = SetPosition(exercise: index, set: current.set + warmups.count)
        }
    }
}
