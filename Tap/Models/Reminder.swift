import Foundation
import SwiftData
import CoreLocation

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }

    /// Chip text, given the reference fire date.
    func chipText(for date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch self {
        case .none: return time
        case .daily: return "Every day \(time)"
        case .weekly:
            let weekday = date.formatted(.dateTime.weekday(.wide))
            return "Every \(weekday) \(time)"
        case .monthly:
            let day = Calendar.current.component(.day, from: date)
            return "Monthly on day \(day), \(time)"
        }
    }
}

enum LocationTriggerType: String, Codable, CaseIterable, Identifiable {
    case arrive
    case leave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrive: return "When I arrive"
        case .leave: return "When I leave"
        }
    }
}

@Model
final class Reminder {
    @Attribute(.unique) var id: UUID
    var content: String
    var createdAt: Date
    var isUrgent: Bool
    var isCompleted: Bool

    // Time condition
    var fireDate: Date?
    var timeFired: Bool
    var repeatRuleRaw: String?

    // Interval condition: fire every `intervalMinutes` within active hours.
    var intervalMinutes: Int?
    var activeStartHour: Int = 9
    var activeEndHour: Int = 22

    // Location condition: either a saved place reference or an ad-hoc pin
    var savedPlace: SavedPlace?
    var adHocLatitude: Double?
    var adHocLongitude: Double?
    var adHocRadius: Double?
    var adHocName: String?
    var triggerTypeRaw: String?
    var locationFired: Bool

    init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = .now,
        isUrgent: Bool = false,
        fireDate: Date? = nil,
        savedPlace: SavedPlace? = nil,
        adHocLatitude: Double? = nil,
        adHocLongitude: Double? = nil,
        adHocRadius: Double? = nil,
        adHocName: String? = nil,
        triggerType: LocationTriggerType? = nil
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.isUrgent = isUrgent
        self.isCompleted = false
        self.fireDate = fireDate
        self.timeFired = false
        self.savedPlace = savedPlace
        self.adHocLatitude = adHocLatitude
        self.adHocLongitude = adHocLongitude
        self.adHocRadius = adHocRadius
        self.adHocName = adHocName
        self.triggerTypeRaw = triggerType?.rawValue
        self.locationFired = false
    }

    var triggerType: LocationTriggerType? {
        get { triggerTypeRaw.flatMap(LocationTriggerType.init(rawValue:)) }
        set { triggerTypeRaw = newValue?.rawValue }
    }

    var repeatRule: RepeatRule {
        get { repeatRuleRaw.flatMap(RepeatRule.init(rawValue:)) ?? .none }
        set { repeatRuleRaw = newValue == .none ? nil : newValue.rawValue }
    }

    var isRepeating: Bool { repeatRule != .none && fireDate != nil }

    /// Fires repeatedly through the day (e.g. water reminders).
    var isInterval: Bool { intervalMinutes != nil }

    /// Any kind of recurrence — never auto-resolves, "Done" acknowledges one hit.
    var recurs: Bool { isRepeating || isInterval }

    var hasTimeCondition: Bool { fireDate != nil || isInterval }

    /// Chip/label for an interval reminder, e.g. "Every 2h · 9 AM–10 PM".
    var intervalChipText: String? {
        guard let minutes = intervalMinutes else { return nil }
        let every = minutes % 60 == 0 ? "Every \(minutes / 60)h" : "Every \(minutes)m"
        return "\(every) · \(Self.hourLabel(activeStartHour))–\(Self.hourLabel(activeEndHour))"
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    var hasLocationCondition: Bool {
        savedPlace != nil || (adHocLatitude != nil && adHocLongitude != nil)
    }

    /// Both conditions set → race mode.
    var isRace: Bool { hasTimeCondition && hasLocationCondition }

    var locationCoordinate: CLLocationCoordinate2D? {
        if let place = savedPlace { return place.coordinate }
        if let lat = adHocLatitude, let lon = adHocLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    var locationRadius: Double {
        savedPlace?.radius ?? adHocRadius ?? 150
    }

    var locationName: String? {
        savedPlace?.name ?? adHocName
    }

    /// Stable identifier for the time-leg notification.
    var timeNotificationID: String { "time-\(id.uuidString)" }
    /// Stable identifier for the location-leg notification.
    var locationNotificationID: String { "loc-\(id.uuidString)" }
    /// Stable identifier for the monitored geofence region.
    var regionID: String { "region-\(id.uuidString)" }

    /// Whether this reminder lands on the given day (repeat-rule aware).
    func occursOn(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard !isCompleted else { return false }
        // Interval reminders fire every day from when they were created.
        if isInterval {
            return calendar.startOfDay(for: day) >= calendar.startOfDay(for: createdAt)
        }
        guard let fireDate else { return false }
        let dayStart = calendar.startOfDay(for: day)
        let firstDayStart = calendar.startOfDay(for: fireDate)
        switch repeatRule {
        case .none:
            return calendar.isDate(fireDate, inSameDayAs: day)
        case .daily:
            return dayStart >= firstDayStart
        case .weekly:
            return dayStart >= firstDayStart
                && calendar.component(.weekday, from: fireDate) == calendar.component(.weekday, from: day)
        case .monthly:
            return dayStart >= firstDayStart
                && calendar.component(.day, from: fireDate) == calendar.component(.day, from: day)
        }
    }

    /// A reminder is done once every set condition has fired (or it's marked completed).
    /// A reminder with no conditions yet is NOT resolved — it's waiting for setup
    /// and must stay visible in Upcoming.
    var isResolved: Bool {
        if isCompleted { return true }
        // Recurring reminders keep firing until explicitly completed.
        if recurs { return false }
        guard hasTimeCondition || hasLocationCondition else { return false }
        let timeDone = !hasTimeCondition || timeFired
        let locationDone = !hasLocationCondition || locationFired
        return timeDone && locationDone
    }
}
