import Foundation
import SwiftData
import UserNotifications

/// Implements the time+location race and same-place notification stacking.
///
/// Race rules (both conditions set):
///  - whichever condition is met FIRST fires a soft/info ping
///  - whichever is met SECOND fires the full reminder content
///
/// iOS can't rewrite a *delivered* notification, but it CAN rewrite a *pending*
/// one — so the time leg is pre-scheduled with soft content (correct if time
/// wins), and if location wins first we rewrite the still-pending time leg to
/// full content.
@MainActor
enum RaceCoordinator {

    /// Registers all notifications/regions for a newly created or edited reminder.
    static func activate(_ reminder: Reminder, geofence: GeofenceManager) {
        NotificationScheduler.cancelAll(for: reminder)
        geofence.stopMonitoring(reminder)
        guard !reminder.isResolved else { return }

        if reminder.hasTimeCondition && !reminder.timeFired {
            NotificationScheduler.scheduleTimeLeg(for: reminder)
        }
        if reminder.hasLocationCondition && !reminder.locationFired {
            geofence.startMonitoring(reminder)
        }
    }

    static func deactivate(_ reminder: Reminder, geofence: GeofenceManager) {
        NotificationScheduler.cancelAll(for: reminder)
        geofence.stopMonitoring(reminder)
    }

    /// Called from the CLLocationManager delegate when a monitored region fires.
    static func handleGeofenceEvent(
        regionID: String,
        event: LocationTriggerType,
        context: ModelContext,
        geofence: GeofenceManager
    ) async {
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.regionID == regionID }),
              reminder.triggerType == event,
              !reminder.locationFired,
              !reminder.isResolved
        else { return }

        if reminder.isRace {
            await resolveRaceLocationEvent(reminder)
        } else {
            deliverLocationOnly(fired: reminder, allReminders: all, geofence: geofence)
        }

        reminder.locationFired = true
        geofence.stopMonitoring(reminder)
        try? context.save()
    }

    // MARK: - Race resolution (location leg fired)

    private static func resolveRaceLocationEvent(_ reminder: Reminder) async {
        let timeStillPending = await NotificationScheduler.isTimeLegStillPending(for: reminder)
        if timeStillPending {
            // Location won the race → soft ping now, upgrade the pending time leg to full.
            NotificationScheduler.deliverNow(
                id: reminder.locationNotificationID,
                content: NotificationScheduler.softContent(for: reminder, leg: .location)
            )
            NotificationScheduler.rewriteTimeLegAsFull(for: reminder)
        } else {
            // Time already fired (as the soft ping) → location is second → full content.
            NotificationScheduler.deliverNow(
                id: reminder.locationNotificationID,
                content: NotificationScheduler.fullContent(for: reminder)
            )
        }
    }

    // MARK: - Location-only delivery with stacking

    /// Multiple location-only reminders sharing the same place+trigger group into
    /// ONE combined notification instead of separate pings.
    private static func deliverLocationOnly(fired: Reminder, allReminders: [Reminder], geofence: GeofenceManager) {
        let siblings = allReminders.filter { other in
            other.id != fired.id
            && !other.isRace
            && !other.locationFired
            && !other.isResolved
            && other.triggerType == fired.triggerType
            && sameLocation(other, fired)
        }

        if siblings.isEmpty {
            NotificationScheduler.deliverNow(
                id: fired.locationNotificationID,
                content: NotificationScheduler.fullContent(for: fired)
            )
        } else {
            let group = [fired] + siblings
            NotificationScheduler.deliverStacked(
                reminders: group,
                placeName: fired.locationName ?? "your place",
                trigger: fired.triggerType ?? .arrive
            )
            for sibling in siblings {
                sibling.locationFired = true
                geofence.stopMonitoring(sibling)
            }
        }
    }

    private static func sameLocation(_ a: Reminder, _ b: Reminder) -> Bool {
        if let pa = a.savedPlace, let pb = b.savedPlace { return pa.id == pb.id }
        guard let ca = a.locationCoordinate, let cb = b.locationCoordinate else { return false }
        return abs(ca.latitude - cb.latitude) < 0.0001 && abs(ca.longitude - cb.longitude) < 0.0001
    }

    // MARK: - Time-leg delivery bookkeeping

    /// Marks time legs as fired once their date passes (called on foreground).
    static func reconcileFiredTimeLegs(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        var changed = false
        for reminder in all where reminder.hasTimeCondition && !reminder.timeFired {
            if let date = reminder.fireDate, date <= .now {
                reminder.timeFired = true
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
