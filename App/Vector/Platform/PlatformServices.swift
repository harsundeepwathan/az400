import Foundation
import UIKit
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif
import VectorCore

// MARK: - Haptics

/// Imperative haptics for events that don't map to a SwiftUI state change.
/// Declarative `.sensoryFeedback` is preferred inside views.
@MainActor
enum Haptics {
    static func setCompleted() { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8) }
    static func personalRecord() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func restFinished() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// MARK: - Notifications

/// Schedules the "rest finished" local notification so the athlete gets
/// alerted even with the phone locked in their pocket.
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let restIdentifier = "vector.rest-timer"
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func scheduleRestEnd(at date: Date, nextUp: String?) {
        cancelRest()
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = nextUp.map { "Time for your next set: \($0)." } ?? "Time for your next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.restIdentifier, content: content, trigger: trigger))
    }

    func cancelRest() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.restIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.restIdentifier])
    }

    // While the app is open the in-app timer already alerts with a haptic,
    // so only play the sound rather than covering the workout with a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.identifier == Self.restIdentifier ? [.sound] : [.banner, .sound]
    }
}

// MARK: - Live Activities

@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit)
    private var activity: Activity<WorkoutActivityAttributes>?
    #endif

    func update(workout: ActiveWorkout?, restTimer: RestTimer?, catalog: ExerciseCatalog) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let workout else {
            end()
            return
        }
        let index = workout.currentExerciseIndex
        let log = workout.session.exercises.indices.contains(index) ? workout.session.exercises[index] : nil
        let setNumber = (workout.focus?.set ?? 0) + 1
        let state = WorkoutActivityAttributes.ContentState(
            exerciseName: log.flatMap { catalog[$0.exerciseID]?.name } ?? workout.session.name,
            setLabel: log.map { "Set \(min(setNumber, $0.sets.count)) of \($0.sets.count)" } ?? "",
            completedSets: workout.completedSets,
            totalSets: workout.totalSets,
            restEndsAt: restTimer.map(\.endsAt)
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else {
            let attributes = WorkoutActivityAttributes(workoutName: workout.session.name, startedAt: workout.session.startedAt)
            activity = try? Activity.request(attributes: attributes, content: content)
        }
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
