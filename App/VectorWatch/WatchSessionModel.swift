import Foundation
import Observation
import VectorCore
import WatchConnectivity
import WatchKit

/// Watch side of the connection. Applies commands locally first (so taps
/// feel instant), sends them to the phone, then adopts the phone's state.
@Observable
@MainActor
final class WatchSessionModel: NSObject, WCSessionDelegate {
    private(set) var state: WatchWorkoutState?
    private(set) var isPhoneReachable = false
    /// The exercise page the user is looking at.
    var selectedExercise = 0

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var workout: ActiveWorkout? { state?.workout }
    var restTimer: RestTimer? { state?.restTimer }
    var unit: WeightUnit { state?.unit ?? .kilograms }

    func name(of exerciseID: String) -> String { state?.exerciseNames[exerciseID] ?? exerciseID }
    func increment(of exerciseID: String) -> Double { state?.increments[exerciseID] ?? 2.5 }

    // MARK: Intents

    func startNextWorkout() { send(.startNextWorkout) }

    func complete(_ position: SetPosition) {
        guard var current = state, var workout = current.workout,
              let result = workout.complete(position) else { return }
        current.workout = workout
        if result.restSeconds > 0, !result.finishedWorkout {
            current.restTimer = RestTimer(startedAt: Date(), duration: TimeInterval(result.restSeconds))
        }
        state = current
        if let next = result.nextFocus { selectedExercise = next.exercise }
        WKInterfaceDevice.current().play(result.isPersonalRecord ? .success : .click)
        send(.completeSet(position))
    }

    func setWeight(_ weight: Double, at position: SetPosition) {
        state?.workout?.setWeight(weight, at: position)
        send(.setWeight(position, weight))
    }

    func setReps(_ reps: Int, at position: SetPosition) {
        state?.workout?.setReps(reps, at: position)
        send(.setReps(position, reps))
    }

    func adjustRest(by seconds: Double) {
        state?.restTimer?.adjust(by: seconds, now: Date())
        send(.adjustRest(seconds))
    }

    func skipRest() {
        state?.restTimer = nil
        send(.skipRest)
    }

    func restFinished() {
        guard state?.restTimer != nil else { return }
        state?.restTimer = nil
        WKInterfaceDevice.current().play(.notification)
    }

    func finish() {
        state?.workout = nil
        state?.restTimer = nil
        send(.finishWorkout)
    }

    private func send(_ command: WatchCommand) {
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(command.encoded(), replyHandler: nil) { _ in
                // Fall back to guaranteed (queued) delivery if the live message fails.
                session.transferUserInfo(command.encoded())
            }
        } else {
            session.transferUserInfo(command.encoded())
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if let decoded = WatchWorkoutState.decode(context) { self.adopt(decoded) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let decoded = WatchWorkoutState.decode(applicationContext) else { return }
        Task { @MainActor in self.adopt(decoded) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isPhoneReachable = reachable }
    }

    private func adopt(_ newState: WatchWorkoutState) {
        state = newState
        if let focus = newState.workout?.focus { selectedExercise = focus.exercise }
    }
}
