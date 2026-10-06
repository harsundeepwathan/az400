import Foundation
import VectorCore

/// Everything the watch needs to render the current workout. The phone is
/// the source of truth and sends this after every change.
struct WatchWorkoutState: Codable, Equatable {
    var workout: ActiveWorkout?
    var restTimer: RestTimer?
    var exerciseNames: [String: String]
    /// Load step per exercise for Digital Crown adjustments.
    var increments: [String: Double]
    var unit: WeightUnit
    var nextWorkoutName: String?

    static let contextKey = "state"

    func encoded() -> [String: Any] {
        guard let data = try? JSONFileStore.encoder.encode(self) else { return [:] }
        return [Self.contextKey: data]
    }

    static func decode(_ dictionary: [String: Any]) -> WatchWorkoutState? {
        guard let data = dictionary[contextKey] as? Data else { return nil }
        return try? JSONFileStore.decoder.decode(WatchWorkoutState.self, from: data)
    }
}

/// Intents the watch sends to the phone. They mirror ActiveWorkout's
/// mutations so the watch can apply them optimistically.
enum WatchCommand: Codable, Equatable {
    case startNextWorkout
    case completeSet(SetPosition)
    case setWeight(SetPosition, Double)
    case setReps(SetPosition, Int)
    case adjustRest(Double)
    case skipRest
    case finishWorkout

    static let messageKey = "command"

    func encoded() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.messageKey: data]
    }

    static func decode(_ dictionary: [String: Any]) -> WatchCommand? {
        guard let data = dictionary[messageKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchCommand.self, from: data)
    }
}
