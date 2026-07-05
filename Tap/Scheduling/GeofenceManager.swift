import Foundation
import CoreLocation
import SwiftData

/// Owns CLLocationManager region monitoring. Region delegate callbacks run even
/// when the app is relaunched in the background, which is what lets race logic
/// and stacking execute code at the moment a geofence fires.
final class GeofenceManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = GeofenceManager()

    private let manager = CLLocationManager()
    /// Set by TapApp at launch so background events can query/update reminders.
    var modelContainer: ModelContainer?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        // Escalate to Always as soon as When-In-Use is granted (needed for background geofencing).
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    // MARK: - Region registration

    func startMonitoring(_ reminder: Reminder) {
        guard let coordinate = reminder.locationCoordinate, let trigger = reminder.triggerType else { return }
        let region = CLCircularRegion(
            center: coordinate,
            radius: min(reminder.locationRadius, manager.maximumRegionMonitoringDistance),
            identifier: reminder.regionID
        )
        region.notifyOnEntry = trigger == .arrive
        region.notifyOnExit = trigger == .leave
        manager.startMonitoring(for: region)
    }

    func stopMonitoring(_ reminder: Reminder) {
        for region in manager.monitoredRegions where region.identifier == reminder.regionID {
            manager.stopMonitoring(for: region)
        }
    }

    /// Re-registers regions for all unresolved location reminders (called at launch
    /// and after edits). iOS caps monitored regions (~20 per app); nearest-deadline
    /// reminders win if we're over the cap.
    func syncMonitoredRegions(reminders: [Reminder]) {
        let active = reminders.filter { $0.hasLocationCondition && !$0.isResolved && !$0.locationFired }
        let capped = Array(
            active.sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }.prefix(18)
        )
        let wantedIDs = Set(capped.map(\.regionID))

        for region in manager.monitoredRegions where region.identifier.hasPrefix("region-") && !wantedIDs.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        for reminder in capped {
            startMonitoring(reminder)
        }
    }

    // MARK: - Region events

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        handleRegionEvent(regionID: region.identifier, event: .arrive)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        handleRegionEvent(regionID: region.identifier, event: .leave)
    }

    private func handleRegionEvent(regionID: String, event: LocationTriggerType) {
        guard let container = modelContainer else { return }
        Task { @MainActor in
            await RaceCoordinator.handleGeofenceEvent(
                regionID: regionID,
                event: event,
                context: container.mainContext,
                geofence: self
            )
        }
    }
}
