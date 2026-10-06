import Foundation
import VectorCore
import WatchConnectivity

/// iPhone side of the Apple Watch connection: publishes workout state and
/// applies commands (complete set, adjust load, rest timer) sent from the wrist.
@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?
    private var lastSent: WatchWorkoutState?

    func start(model: AppModel) {
        guard WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
        model.onCommit = { [weak self] _ in self?.publish() }
    }

    func publish() {
        guard let model, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let workout = model.activeWorkout
        let ids = Set(workout?.session.exercises.map(\.exerciseID) ?? [])
        let state = WatchWorkoutState(
            workout: workout,
            restTimer: model.restTimer,
            exerciseNames: Dictionary(uniqueKeysWithValues: ids.map { ($0, model.catalog[$0]?.name ?? $0) }),
            increments: Dictionary(uniqueKeysWithValues: ids.map { id in
                let step = model.catalog[id]?.loadIncrement ?? 2.5
                return (id, step > 0 ? step : 2.5)
            }),
            unit: model.unit,
            nextWorkoutName: model.nextWorkout?.name
        )
        guard state != lastSent else { return }
        lastSent = state
        try? WCSession.default.updateApplicationContext(state.encoded())
    }

    private func apply(_ command: WatchCommand) {
        guard let model else { return }
        switch command {
        case .startNextWorkout:
            if model.activeWorkout == nil, let next = model.nextWorkout { model.startWorkout(next) }
        case .completeSet(let position):
            model.completeSet(position)
        case .setWeight(let position, let weight):
            model.updateWorkout { $0.setWeight(weight, at: position) }
        case .setReps(let position, let reps):
            model.updateWorkout { $0.setReps(reps, at: position) }
        case .adjustRest(let seconds):
            model.adjustRest(by: seconds)
        case .skipRest:
            model.skipRest()
        case .finishWorkout:
            model.finishWorkout()
        }
        publish()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchCommand.decode(message) else { return }
        Task { @MainActor in self.apply(command) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = WatchCommand.decode(userInfo) else { return }
        Task { @MainActor in self.apply(command) }
    }
}
