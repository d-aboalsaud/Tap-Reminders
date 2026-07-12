import Foundation
import SwiftData
import CoreLocation

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

    var hasTimeCondition: Bool { fireDate != nil }

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

    /// A reminder is done once every set condition has fired (or it's marked completed).
    /// A reminder with no conditions yet is NOT resolved — it's waiting for setup
    /// and must stay visible in Upcoming.
    var isResolved: Bool {
        if isCompleted { return true }
        guard hasTimeCondition || hasLocationCondition else { return false }
        let timeDone = !hasTimeCondition || timeFired
        let locationDone = !hasLocationCondition || locationFired
        return timeDone && locationDone
    }
}
