import SwiftUI
import SwiftData

struct SavedPlacesView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var geofence: GeofenceManager
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    @Query private var reminders: [Reminder]

    @State private var editingPlace: SavedPlace?
    @State private var showAdd = false
    @State private var pendingDeletion: SavedPlace?

    var body: some View {
        NavigationStack {
            List {
                if places.isEmpty {
                    RippleEmptyState(
                        icon: "mappin.and.ellipse",
                        title: "No saved places",
                        message: "Add places like Home or Work so you can say “remind me at Work”."
                    )
                    .listRowSeparator(.hidden)
                }
                ForEach(places) { place in
                    Button {
                        editingPlace = place
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).foregroundStyle(.primary)
                            Text("Radius \(Int(place.radius)) m · \(affectedReminders(for: place).count) reminder(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            requestDeletion(place)
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("addPlaceButton")
            }
            .sheet(isPresented: $showAdd) {
                PlaceEditView(place: nil)
            }
            .sheet(item: $editingPlace) { place in
                PlaceEditView(place: place)
            }
            .confirmationDialog(
                deletionWarningTitle,
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete place and its reminders' location condition", role: .destructive) {
                    confirmDeletion()
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                if let place = pendingDeletion {
                    let affected = affectedReminders(for: place)
                    if affected.isEmpty {
                        Text("No reminders use this place.")
                    } else {
                        Text(affected.map { "• \($0.content)" }.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    private var deletionWarningTitle: String {
        guard let place = pendingDeletion else { return "" }
        let count = affectedReminders(for: place).count
        return count == 0
            ? "Delete “\(place.name)”?"
            : "Deleting “\(place.name)” affects \(count) reminder\(count == 1 ? "" : "s")"
    }

    private func affectedReminders(for place: SavedPlace) -> [Reminder] {
        reminders.filter { $0.savedPlace?.id == place.id && !$0.isResolved }
    }

    private func requestDeletion(_ place: SavedPlace) {
        pendingDeletion = place
    }

    private func confirmDeletion() {
        guard let place = pendingDeletion else { return }
        for reminder in reminders where reminder.savedPlace?.id == place.id {
            geofence.stopMonitoring(reminder)
            reminder.savedPlace = nil
            reminder.triggerType = nil
            reminder.locationFired = false
            // A reminder must keep at least one condition; if the place was its
            // only condition, keep it visible in the list so the user re-homes it.
            RaceCoordinator.activate(reminder, geofence: geofence)
        }
        context.delete(place)
        try? context.save()
        pendingDeletion = nil
    }
}
