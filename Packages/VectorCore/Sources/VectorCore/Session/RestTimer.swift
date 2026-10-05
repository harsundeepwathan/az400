import Foundation

/// Wall-clock based rest timer. Storing an end date (rather than counting
/// down ticks) keeps it correct across backgrounding, Live Activities and
/// the watch, all of which simply render `remaining(at:)`.
public struct RestTimer: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    /// Exercise the rest belongs to, so the UI can label it.
    public var exerciseID: String?

    public init(startedAt: Date, duration: TimeInterval, exerciseID: String? = nil) {
        self.startedAt = startedAt
        self.duration = max(duration, 0)
        self.exerciseID = exerciseID
    }

    public var endsAt: Date { startedAt.addingTimeInterval(duration) }

    public func remaining(at now: Date) -> TimeInterval { max(endsAt.timeIntervalSince(now), 0) }

    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// Fraction elapsed in 0...1.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    /// +15 / −15 buttons. Never lets the remaining time go below zero.
    public mutating func adjust(by seconds: TimeInterval, now: Date) {
        let remaining = remaining(at: now)
        let delta = max(seconds, -remaining)
        duration = max(duration + delta, 0)
    }
}
