import SwiftUI
import SwiftData

@main
struct TapApp: App {
    let container: ModelContainer
    @StateObject private var geofence = GeofenceManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?

    /// Away longer than this → snap back to Capture, ready to type.
    private static let captureResetAfter: TimeInterval = 120

    init() {
        do {
            container = try ModelContainer(for: Reminder.self, SavedPlace.self)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
        GeofenceManager.shared.modelContainer = container
        NotificationDelegate.shared.modelContainer = container
        NotificationDelegate.shared.register()
        NotificationScheduler.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Color.tapBlue)
                .environmentObject(geofence)
                .environmentObject(AppRouter.shared)
                .onAppear {
                    geofence.requestPermissions()
                    reconcile()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        reconcile()
                        // Fast-capture reset: away long enough means the user is
                        // back to add something — land them typing. Quick app
                        // switches and notification taps keep their context.
                        if let away = backgroundedAt,
                           Date.now.timeIntervalSince(away) > Self.captureResetAfter,
                           AppRouter.shared.pendingReminderID == nil {
                            AppRouter.shared.selectedTab = 0
                            AppRouter.shared.captureFocusRequest = UUID()
                        }
                        backgroundedAt = nil
                    case .background:
                        backgroundedAt = .now
                    default:
                        break
                    }
                }
        }
        .modelContainer(container)
    }

    @MainActor
    private func reconcile() {
        let context = container.mainContext
        RaceCoordinator.reconcileFiredTimeLegs(context: context)
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        GeofenceManager.shared.syncMonitoredRegions(reminders: all)
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    var body: some View {
        TabView(selection: $router.selectedTab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "plus.circle.fill") }
                .tag(0)
            ReminderListView()
                .tabItem { Label("Reminders", systemImage: "list.bullet") }
                .tag(1)
            SavedPlacesView()
                .tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
                .tag(2)
        }
        .preferredColorScheme(
            (AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme
        )
    }
}
