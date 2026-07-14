import Foundation
import EventKit

/// Read-only bridge to the iPhone calendar. Tap. never writes to it.
@MainActor
final class EventKitProvider: ObservableObject {
    @Published var authorized = false
    @Published var denied = false

    private let store = EKEventStore()

    func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
        case .notDetermined:
            Task {
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                self.authorized = granted
                self.denied = !granted
            }
        default:
            denied = true
        }
    }

    func events(on day: Date) -> [EKEvent] {
        guard authorized else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
    }
}
