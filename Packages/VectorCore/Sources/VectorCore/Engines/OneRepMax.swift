import Foundation

public enum OneRepMax {
    /// Estimated one-rep max using the Epley formula, which tracks well in the
    /// 1–10 rep range lifters actually train in. Above 12 reps estimates get
    /// unreliable, so reps are capped there rather than extrapolating.
    public static func estimate(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        if reps == 1 { return weight }
        let cappedReps = Double(min(reps, 12))
        return weight * (1 + cappedReps / 30)
    }

    /// Load expected to be achievable for `reps` given an estimated 1RM.
    public static func load(forReps reps: Int, oneRepMax: Double) -> Double {
        guard reps > 0, oneRepMax > 0 else { return 0 }
        if reps == 1 { return oneRepMax }
        return oneRepMax / (1 + Double(min(reps, 12)) / 30)
    }
}

public enum LoadRounding {
    /// Rounds to the nearest multiple of `step` (2.5 kg plates by default).
    public static func round(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return (value * 2).rounded() / 2 }
        return (value / step).rounded() * step
    }
}
