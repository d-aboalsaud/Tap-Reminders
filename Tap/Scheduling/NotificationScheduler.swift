import Foundation
import UserNotifications
import MapKit
import SwiftData
import UIKit

/// Builds and schedules local notifications for reminders, including the
/// soft-ping vs full-content distinction used by time+location race mode.
enum NotificationScheduler {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Signature sounds

    static let chime = UNNotificationSound(named: UNNotificationSoundName("tap-chime.caf"))
    static let urgentChime = UNNotificationSound(named: UNNotificationSoundName("tap-urgent.caf"))

    // MARK: - Urgent re-alert ("nag") settings

    /// Urgent reminders re-fire this often until acknowledged…
    static let nagInterval: TimeInterval = 10 * 60
    /// …up to this many times (1 hour of nagging).
    static let nagCount = 6

    // MARK: - Content builders

    static func fullContent(for reminder: Reminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.isUrgent ? "🔥 \(reminder.content)" : reminder.content
        if let name = reminder.locationName, reminder.hasLocationCondition {
            content.subtitle = reminder.triggerType == .leave ? "Leaving \(name)" : "At \(name)"
        }
        content.sound = reminder.isUrgent ? urgentChime : chime
        content.interruptionLevel = reminder.isUrgent ? .timeSensitive : .active
        content.categoryIdentifier = NotificationDelegate.categoryID
        content.userInfo = ["reminderID": reminder.id.uuidString, "isUrgent": reminder.isUrgent]
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
        if reminder.isInterval {
            // Interval reminders share one slot budget, so adding one re-spaces the others.
            if let context = reminder.modelContext {
                rescheduleIntervals(in: context)
            } else {
                scheduleInterval(for: reminder, slotShare: intervalSlotCap)
            }
            return
        }
        if reminder.isRepeating {
            scheduleRepeating(for: reminder)
            return
        }
        guard let fireDate = reminder.fireDate, fireDate > .now else { return }
        let content = reminder.isRace
            ? softContent(for: reminder, leg: .time)
            : fullContent(for: reminder)
        // Badge estimate at schedule time; corrected on next app open.
        if !reminder.isRace, let context = reminder.modelContext {
            content.badge = NSNumber(value: unhandledCount(in: context) + 1)
        }
        schedule(id: reminder.timeNotificationID, content: content, fireDate: fireDate)
        // Race time-leg starts as a soft ping — no nagging until full content fires.
        if !reminder.isRace {
            scheduleNags(for: reminder, startingAt: fireDate)
        }
    }

    /// Repeating reminders use an iOS repeating calendar trigger — the system
    /// re-fires them forever until the request is removed.
    private static func scheduleRepeating(for reminder: Reminder) {
        guard let fireDate = reminder.fireDate else { return }
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = calendar.component(.hour, from: fireDate)
        components.minute = calendar.component(.minute, from: fireDate)
        switch reminder.repeatRule {
        case .weekly:
            components.weekday = calendar.component(.weekday, from: fireDate)
        case .monthly:
            let day = calendar.component(.day, from: fireDate)
            // A day-31 trigger never fires in 30-day months, so late days get
            // one yearly trigger per month, clamped to that month's last day.
            if day > 28 {
                scheduleLateMonthly(for: reminder, day: day, hour: components.hour!, minute: components.minute!)
                return
            }
            components.day = day
        case .daily, .none:
            break
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: reminder.timeNotificationID,
            content: fullContent(for: reminder),
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func scheduleLateMonthly(for reminder: Reminder, day: Int, hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        for month in 1...12 {
            var components = DateComponents()
            components.month = month
            components.day = Reminder.monthlyFireDay(day, month: month)
            components.hour = hour
            components.minute = minute
            center.add(UNNotificationRequest(
                identifier: monthlySlotID(reminder.id, month),
                content: fullContent(for: reminder),
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            ))
        }
    }

    private static func monthlySlotID(_ id: UUID, _ month: Int) -> String {
        "monthly-\(id.uuidString)-\(month)"
    }

    /// Interval reminders fire every `intervalMinutes` within active hours.
    /// iOS has no native "every N minutes between X and Y" trigger, so we
    /// schedule one daily-repeating calendar notification per slot in the window.
    private static let intervalSlotCap = 24
    /// iOS keeps only the 64 soonest pending notifications and silently drops
    /// the rest. All interval reminders share this many slots; the remainder
    /// is left for one-off times, monthly slots, nags and snoozes.
    private static let intervalSlotBudget = 40

    /// Slots one interval reminder may use while `activeCount` of them share the budget.
    static func intervalSlotShare(activeCount: Int) -> Int {
        max(1, min(intervalSlotCap, intervalSlotBudget / max(activeCount, 1)))
    }

    /// Minutes between the notifications actually scheduled: the requested
    /// interval, widened when the reminder's share of slots can't cover its window.
    static func effectiveIntervalMinutes(for reminder: Reminder, slotShare: Int) -> Int? {
        guard let interval = reminder.intervalMinutes, interval >= 1 else { return nil }
        let window = (reminder.activeEndHour - reminder.activeStartHour) * 60
        guard window > 0 else { return nil }
        let wanted = window / interval + 1
        guard wanted > slotShare else { return interval }
        guard slotShare > 1 else { return window }
        // Spread the available slots evenly across the window, in 5-minute steps.
        let spread = Int((Double(window) / Double(slotShare - 1) / 5).rounded(.up)) * 5
        return max(interval, spread)
    }

    /// Same as above, using the reminder's current share of the budget.
    static func effectiveIntervalMinutes(for reminder: Reminder) -> Int? {
        let count = reminder.modelContext.map { activeIntervalReminders(in: $0).count } ?? 1
        return effectiveIntervalMinutes(for: reminder, slotShare: intervalSlotShare(activeCount: count))
    }

    private static func activeIntervalReminders(in context: ModelContext, excluding excludedID: UUID? = nil) -> [Reminder] {
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        return all.filter { $0.isInterval && !$0.isCompleted && $0.id != excludedID }
    }

    /// Re-spaces every active interval reminder so together they fit the budget.
    /// Called whenever one is added, edited or removed, and on app open.
    static func rescheduleIntervals(in context: ModelContext, excluding excludedID: UUID? = nil) {
        let active = activeIntervalReminders(in: context, excluding: excludedID)
        let share = intervalSlotShare(activeCount: active.count)
        for reminder in active {
            cancelIntervalSlots(reminderID: reminder.id)
            scheduleInterval(for: reminder, slotShare: share)
        }
    }

    private static func scheduleInterval(for reminder: Reminder, slotShare: Int) {
        guard let interval = effectiveIntervalMinutes(for: reminder, slotShare: slotShare) else { return }
        let startMinutes = reminder.activeStartHour * 60
        let endMinutes = reminder.activeEndHour * 60
        let center = UNUserNotificationCenter.current()
        var slot = startMinutes
        var index = 0
        while slot <= endMinutes && index < slotShare {
            var components = DateComponents()
            components.hour = slot / 60
            components.minute = slot % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            center.add(UNNotificationRequest(
                identifier: intervalSlotID(reminder.id, index),
                content: fullContent(for: reminder),
                trigger: trigger
            ))
            slot += interval
            index += 1
        }
    }

    private static func intervalSlotID(_ id: UUID, _ index: Int) -> String {
        "interval-\(id.uuidString)-\(index)"
    }

    static func cancelIntervalSlots(reminderID: UUID) {
        let ids = (0..<intervalSlotCap).map { intervalSlotID(reminderID, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func rewriteTimeLegAsFull(for reminder: Reminder) {
        guard let fireDate = reminder.fireDate, fireDate > .now else { return }
        cancelTimeLeg(for: reminder)
        schedule(id: reminder.timeNotificationID, content: fullContent(for: reminder), fireDate: fireDate)
        scheduleNags(for: reminder, startingAt: fireDate)
    }

    static func cancelTimeLeg(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.timeNotificationID])
        cancelIntervalSlots(reminderID: reminder.id)
        cancelMonthlySlots(reminderID: reminder.id)
    }

    static func cancelMonthlySlots(reminderID: UUID) {
        let ids = (1...12).map { monthlySlotID(reminderID, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func cancelAll(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [reminder.timeNotificationID, reminder.locationNotificationID, snoozeID(reminder.id)]
        )
        cancelIntervalSlots(reminderID: reminder.id)
        cancelMonthlySlots(reminderID: reminder.id)
        cancelNags(reminderID: reminder.id)
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
        content.sound = anyUrgent ? urgentChime : chime
        content.interruptionLevel = anyUrgent ? .timeSensitive : .active
        // Same category as single reminders → Done / Snooze act on the whole stack.
        content.categoryIdentifier = NotificationDelegate.categoryID
        content.userInfo = [
            "reminderIDs": reminders.map(\.id.uuidString),
            "isUrgent": anyUrgent,
        ]
        deliverNow(id: "stack-\(UUID().uuidString)", content: content)
    }

    /// One pending snooze per reminder: re-snoozing replaces it, and completing
    /// the reminder can cancel it by ID.
    static func snoozeID(_ id: UUID) -> String {
        "snooze-\(id.uuidString)"
    }

    // MARK: - Urgent re-alert (nag) series

    /// Schedules follow-up urgent notifications every `nagInterval` after
    /// `start`, cancelled when the user acts (Done / Snooze / opens it).
    static func scheduleNags(for reminder: Reminder, startingAt start: Date) {
        guard reminder.isUrgent else { return }
        let center = UNUserNotificationCenter.current()
        for i in 1...nagCount {
            let fireAt = start.addingTimeInterval(nagInterval * Double(i))
            guard fireAt > .now else { continue }
            let content = fullContent(for: reminder)
            content.title = "🔥 Still waiting: \(reminder.content)"
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(
                identifier: nagID(reminder.id, i), content: content, trigger: trigger
            ))
        }
    }

    static func cancelNags(reminderID: UUID) {
        let ids = (1...nagCount).map { nagID(reminderID, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    private static func nagID(_ id: UUID, _ index: Int) -> String {
        "nag-\(id.uuidString)-\(index)"
    }

    // MARK: - App icon badge

    /// Reminders whose conditions all fired but the user hasn't completed.
    static func unhandledCount(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        return all.filter { $0.isResolved && !$0.isCompleted }.count
    }

    static func updateBadgeNow(context: ModelContext) {
        UNUserNotificationCenter.current().setBadgeCount(unhandledCount(in: context))
    }

    // MARK: - Map attachment for place notifications

    /// Attaches a map snapshot of the geofenced place. Best-effort: if the
    /// snapshot can't be produced (no network in the background window), the
    /// notification simply goes out without an image.
    static func attachMapSnapshot(
        to content: UNMutableNotificationContent,
        coordinate: CLLocationCoordinate2D,
        radius: Double
    ) async {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: max(radius * 8, 600),
            longitudinalMeters: max(radius * 8, 600)
        )
        options.size = CGSize(width: 600, height: 320)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return }

        // Draw a brand-blue pin dot at the place.
        let image = UIGraphicsImageRenderer(size: options.size).image { _ in
            snapshot.image.draw(at: .zero)
            let point = snapshot.point(for: coordinate)
            let dot = UIBezierPath(
                arcCenter: point, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true
            )
            UIColor(red: 0.15, green: 0.35, blue: 0.95, alpha: 1).setFill()
            dot.fill()
            UIColor.white.setStroke()
            dot.lineWidth = 3
            dot.stroke()
        }

        guard let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            let attachment = try UNNotificationAttachment(identifier: "map", url: url)
            content.attachments = [attachment]
        } catch {
            // Ship the notification without the image.
        }
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
