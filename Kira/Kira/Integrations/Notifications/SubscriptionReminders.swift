import Foundation
import UserNotifications
import KiraCore

/// Local renewal and trial-ending reminders. Scheduled on-device with UserNotifications;
/// nothing is sent to a server.
///
/// Privacy: notification text names the service but never the amount, because notifications can
/// appear on the Lock Screen.
enum SubscriptionReminders {
    static let identifierPrefix = "kira.subscription."
    /// Reminders fire at 9:00 local time.
    static let reminderHour = 9

    /// Asks for permission the first time a reminder is turned on. Returns whether reminders can fire.
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default: return false
        }
    }

    /// Replaces all Kira subscription reminders with ones for the current list.
    static func reschedule(_ subscriptions: [ServiceSubscription], engine: SubscriptionEngine, now: Date) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) })

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for subscription in subscriptions where subscription.isLive {
            guard let lead = subscription.reminderDaysBefore else { continue }
            let schedule = engine.billingSchedule(engine.rolledForward(subscription, now: now))
            let fireDay = engine.calendar.addingDays(-max(lead, 0), to: engine.calendar.startOfDay(schedule.nextRenewal))
            var components = engine.calendar.calendar.dateComponents([.year, .month, .day], from: fireDay)
            components.hour = reminderHour
            components.timeZone = engine.calendar.calendar.timeZone
            guard let fireDate = engine.calendar.calendar.date(from: components), fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = subscription.status == .trial ? "\(subscription.name) trial ends \(relative(lead))" : "\(subscription.name) renews \(relative(lead))"
            content.body = subscription.status == .trial
                ? "Cancel in the provider’s app before then if you don’t want to be charged."
                : "Open Kira to review or mark it as cancelled."
            content.sound = .default
            content.threadIdentifier = "subscriptions"
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifierPrefix + subscription.id.uuidString, content: content, trigger: trigger))
        }
    }

    static func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) })
        }
    }

    private static func relative(_ days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}
