import Foundation
import UserNotifications

/// Builds and schedules local notifications for reminders, including the
/// soft-ping vs full-content distinction used by time+location race mode.
enum NotificationScheduler {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Content builders

    static func fullContent(for reminder: Reminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.isUrgent ? "🔥 \(reminder.content)" : reminder.content
        if let name = reminder.locationName, reminder.hasLocationCondition {
            content.subtitle = reminder.triggerType == .leave ? "Leaving \(name)" : "At \(name)"
        }
        content.sound = reminder.isUrgent ? .defaultCritical : .default
        content.interruptionLevel = reminder.isUrgent ? .timeSensitive : .active
        content.categoryIdentifier = NotificationDelegate.categoryID
        content.userInfo = ["reminderID": reminder.id.uuidString]
        return content
    }

    /// Soft/info ping fired by whichever race condition is met FIRST.
    static func softContent(for reminder: Reminder, leg: RaceLeg) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch leg {
        case .time:
            content.title = "The time came"
            content.body = "Waiting on the place for: \(reminder.content)"
        case .location:
            let name = reminder.locationName ?? "your place"
            content.title = reminder.triggerType == .leave ? "You left \(name)" : "You reached \(name)"
            content.body = "Waiting on the time for: \(reminder.content)"
        }
        content.sound = nil
        content.interruptionLevel = .passive
        content.userInfo = ["reminderID": reminder.id.uuidString]
        return content
    }

    enum RaceLeg { case time, location }

    // MARK: - Time leg scheduling

    /// Schedules the time-leg notification. In race mode it is pre-set with SOFT
    /// content (time firing first means it's the info ping); if the location leg
    /// fires first, RaceCoordinator rewrites this pending request to FULL content.
    static func scheduleTimeLeg(for reminder: Reminder) {
        guard let fireDate = reminder.fireDate, fireDate > .now else { return }
        let content = reminder.isRace
            ? softContent(for: reminder, leg: .time)
            : fullContent(for: reminder)
        schedule(id: reminder.timeNotificationID, content: content, fireDate: fireDate)
    }

    static func rewriteTimeLegAsFull(for reminder: Reminder) {
        guard let fireDate = reminder.fireDate, fireDate > .now else { return }
        cancelTimeLeg(for: reminder)
        schedule(id: reminder.timeNotificationID, content: fullContent(for: reminder), fireDate: fireDate)
    }

    static func cancelTimeLeg(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.timeNotificationID])
    }

    static func cancelAll(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [reminder.timeNotificationID, reminder.locationNotificationID]
        )
    }

    // MARK: - Immediate delivery (location events, stacking)

    static func deliverNow(id: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// One combined notification for multiple reminders sharing a location trigger.
    static func deliverStacked(reminders: [Reminder], placeName: String, trigger: LocationTriggerType) {
        let content = UNMutableNotificationContent()
        let anyUrgent = reminders.contains(where: \.isUrgent)
        content.title = trigger == .leave ? "Leaving \(placeName)" : "You're at \(placeName)"
        content.body = reminders
            .map { ($0.isUrgent ? "🔥 " : "• ") + $0.content }
            .joined(separator: "\n")
        content.sound = anyUrgent ? .defaultCritical : .default
        content.interruptionLevel = anyUrgent ? .timeSensitive : .active
        deliverNow(id: "stack-\(UUID().uuidString)", content: content)
    }

    // MARK: - Helpers

    private static func schedule(id: String, content: UNMutableNotificationContent, fireDate: Date) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func isTimeLegStillPending(for reminder: Reminder) async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == reminder.timeNotificationID }
    }
}
