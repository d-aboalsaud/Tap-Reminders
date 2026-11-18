import Foundation
import UserNotifications
import SwiftData

/// Routes "open this reminder" requests from notification taps into the UI.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var pendingReminderID: UUID?
    @Published var selectedTab: Int = 0
    /// Bumped to ask the capture screen to focus its text field (fast-capture reset).
    @Published var captureFocusRequest: UUID?
    /// Set when the user interacted with a notification — suppresses the
    /// fast-capture reset that would otherwise steal the navigation.
    var lastNotificationInteraction: Date?
}

/// UNUserNotificationCenter delegate: shows banners while the app is in the
/// foreground, opens the tapped reminder, and handles Done / Snooze actions.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    var modelContainer: ModelContainer?

    static let categoryID = "REMINDER"
    static let doneActionID = "DONE"
    static let snoozeActionID = "SNOOZE"
    static let snoozeInterval: TimeInterval = 30 * 60

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(
            identifier: Self.doneActionID, title: "Done ✓", options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionID, title: "Snooze 30 min", options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [done, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // Show reminders as normal banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        // A single reminder carries "reminderID"; a same-place stack carries "reminderIDs".
        let reminderIDs = ((userInfo["reminderIDs"] as? [String]) ?? [userInfo["reminderID"] as? String].compactMap { $0 })
            .compactMap(UUID.init(uuidString:))
        await MainActor.run { AppRouter.shared.lastNotificationInteraction = .now }

        switch response.actionIdentifier {
        case Self.doneActionID:
            for id in reminderIDs { await markDone(id) }

        case Self.snoozeActionID:
            // Acting on it stops the nagging; the snoozed delivery restarts it.
            for id in reminderIDs {
                NotificationScheduler.cancelNags(reminderID: id)
                await rescheduleNagsAfterSnooze(reminderID: id)
            }
            snooze(response.notification.request.content, reminderIDs: reminderIDs)

        case UNNotificationDefaultActionIdentifier:
            // Opening the reminder counts as acknowledged.
            for id in reminderIDs {
                NotificationScheduler.cancelNags(reminderID: id)
            }
            if !reminderIDs.isEmpty {
                await MainActor.run {
                    AppRouter.shared.selectedTab = 1
                    // A stack has no single page to open — land on the list.
                    if reminderIDs.count == 1 {
                        AppRouter.shared.pendingReminderID = reminderIDs[0]
                    }
                }
            }

        default:
            break
        }
    }

    @MainActor
    private func rescheduleNagsAfterSnooze(reminderID: UUID) {
        guard let container = modelContainer else { return }
        let all = (try? container.mainContext.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.id == reminderID }),
              reminder.isUrgent, !reminder.isCompleted
        else { return }
        NotificationScheduler.scheduleNags(
            for: reminder,
            startingAt: .now.addingTimeInterval(Self.snoozeInterval)
        )
    }

    @MainActor
    private func markDone(_ id: UUID) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.id == id }) else { return }
        // Done on ONE occurrence of a recurring reminder acknowledges it without
        // killing the recurrence; stopping it is done from the app.
        guard !reminder.recurs else {
            NotificationScheduler.cancelNags(reminderID: reminder.id)
            return
        }
        reminder.isCompleted = true
        NotificationScheduler.cancelAll(for: reminder)
        GeofenceManager.shared.stopMonitoring(reminder)
        try? context.save()
        NotificationScheduler.updateBadgeNow(context: context)
    }

    /// Re-delivers the same content later; category/userInfo carry over so the
    /// snoozed notification can itself be snoozed or completed.
    private func snooze(_ content: UNNotificationContent, reminderIDs: [UUID]) {
        guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeInterval, repeats: false)
        // A single reminder's snooze has a known ID so completing it cancels the snooze.
        let identifier = reminderIDs.count == 1
            ? NotificationScheduler.snoozeID(reminderIDs[0])
            : "snooze-stack-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: mutable,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
