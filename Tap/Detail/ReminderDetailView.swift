import SwiftUI
import SwiftData
import MapKit

/// Detail/edit screen — the ONLY place a second condition can be added
/// (capture handles one condition; time+location combos are edit-only).
struct ReminderDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var geofence: GeofenceManager
    @Query private var savedPlaces: [SavedPlace]

    @Bindable var reminder: Reminder

    @State private var showTimeEditor = false
    @State private var showLocationEditor = false
    @State private var draftDate: Date = .now.addingTimeInterval(3600)

    var body: some View {
        Form {
            Section("Reminder") {
                TextField("What to remember", text: $reminder.content, axis: .vertical)
                Toggle(isOn: $reminder.isUrgent) {
                    Label("Urgent", systemImage: "flame.fill").foregroundStyle(.orange)
                }
            }

            timeSection
            locationSection

            if reminder.isRace {
                Section {
                    Label(
                        "Both conditions are set. Whichever happens first sends a soft ping; the second one delivers the full reminder.",
                        systemImage: "flag.checkered"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(reminder.isCompleted ? "Mark as not done" : "Mark as done") {
                    reminder.isCompleted.toggle()
                    persist()
                }
                Button("Delete reminder", role: .destructive) {
                    RaceCoordinator.deactivate(reminder, geofence: geofence)
                    context.delete(reminder)
                    try? context.save()
                    dismiss()
                }
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { persist() }
        .sheet(isPresented: $showTimeEditor) { timeEditor }
        .sheet(isPresented: $showLocationEditor) {
            LocationConditionEditor(reminder: reminder) { persist() }
        }
    }

    // MARK: - Time

    private var timeSection: some View {
        Section("Time") {
            if let date = reminder.fireDate {
                HStack {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    Spacer()
                    Button("Change") {
                        draftDate = date
                        showTimeEditor = true
                    }
                    .font(.callout)
                }
                Button("Remove time", role: .destructive) {
                    guard reminder.hasLocationCondition else { return }
                    reminder.fireDate = nil
                    reminder.timeFired = false
                    persist()
                }
                .disabled(!reminder.hasLocationCondition)
            } else {
                Button {
                    draftDate = .now.addingTimeInterval(3600)
                    showTimeEditor = true
                } label: {
                    Label("Add time", systemImage: "plus.circle")
                }
            }
        }
    }

    private var timeEditor: some View {
        NavigationStack {
            DatePicker("Remind me at", selection: $draftDate, in: Date.now...)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Set time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set") {
                            reminder.fireDate = draftDate
                            reminder.timeFired = false
                            showTimeEditor = false
                            persist()
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTimeEditor = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Location

    private var locationSection: some View {
        Section("Location") {
            if reminder.hasLocationCondition {
                if let coordinate = reminder.locationCoordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: reminder.locationRadius * 6,
                        longitudinalMeters: reminder.locationRadius * 6
                    ))) {
                        Marker(reminder.locationName ?? "Pinned spot", coordinate: coordinate)
                            .tint(Color.tapBlue)
                        MapCircle(center: coordinate, radius: reminder.locationRadius)
                            .foregroundStyle(Color.tapBlue.opacity(0.14))
                            .stroke(Color.tapBlue, lineWidth: 1.5)
                    }
                    .frame(height: 150)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets())
                    .id("\(coordinate.latitude)-\(coordinate.longitude)-\(reminder.locationRadius)")
                }
                HStack {
                    Label(
                        "\(reminder.triggerType == .leave ? "Leave" : "Arrive") · \(reminder.locationName ?? "Pinned spot")",
                        systemImage: "mappin.circle"
                    )
                    Spacer()
                    Button("Change") { showLocationEditor = true }
                        .font(.callout)
                }
                Button("Remove location", role: .destructive) {
                    guard reminder.hasTimeCondition else { return }
                    clearLocation()
                    persist()
                }
                .disabled(!reminder.hasTimeCondition)
            } else {
                Button {
                    showLocationEditor = true
                } label: {
                    Label("Add location", systemImage: "plus.circle")
                }
            }
        }
    }

    private func clearLocation() {
        geofence.stopMonitoring(reminder)
        reminder.savedPlace = nil
        reminder.adHocLatitude = nil
        reminder.adHocLongitude = nil
        reminder.adHocRadius = nil
        reminder.adHocName = nil
        reminder.triggerType = nil
        reminder.locationFired = false
    }

    private func persist() {
        try? context.save()
        RaceCoordinator.activate(reminder, geofence: geofence)
    }
}

// MARK: - Location condition editor (saved place OR ad-hoc pin + arrive/leave)

struct LocationConditionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var savedPlaces: [SavedPlace]

    @Bindable var reminder: Reminder
    var onSave: () -> Void

    @State private var trigger: LocationTriggerType = .arrive
    @State private var useAdHoc = false
    @State private var pin: CLLocationCoordinate2D?
    @State private var radius: Double = 150
    @State private var selectedPlaceID: UUID?
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 30.0444, longitude: 31.2357),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
    )

    var body: some View {
        NavigationStack {
            Form {
                Picker("Trigger", selection: $trigger) {
                    ForEach(LocationTriggerType.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Place type", selection: $useAdHoc) {
                    Text("Saved place").tag(false)
                    Text("Drop a pin").tag(true)
                }
                .pickerStyle(.segmented)

                if useAdHoc {
                    Section("Tap the map to drop a pin") {
                        MapReader { proxy in
                            Map(position: $cameraPosition) {
                                if let pin {
                                    Marker("Here", coordinate: pin)
                                    MapCircle(center: pin, radius: radius)
                                        .foregroundStyle(.blue.opacity(0.15))
                                        .stroke(.blue, lineWidth: 1)
                                }
                            }
                            .frame(height: 260)
                            .onTapGesture { screenPoint in
                                if let coord = proxy.convert(screenPoint, from: .local) {
                                    pin = coord
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())

                        VStack(alignment: .leading) {
                            Text("Radius: \(Int(radius)) m").font(.callout)
                            Slider(value: $radius, in: 50...1000, step: 25)
                        }
                    }
                } else {
                    Section("Saved places") {
                        if savedPlaces.isEmpty {
                            Text("No saved places yet — add them in the Places tab, or drop a pin instead.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(savedPlaces) { place in
                            Button {
                                selectedPlaceID = place.id
                            } label: {
                                HStack {
                                    Text(place.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedPlaceID == place.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { apply() }
                        .disabled(useAdHoc ? pin == nil : selectedPlaceID == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        trigger = reminder.triggerType ?? .arrive
        if let place = reminder.savedPlace {
            useAdHoc = false
            selectedPlaceID = place.id
        } else if let lat = reminder.adHocLatitude, let lon = reminder.adHocLongitude {
            useAdHoc = true
            pin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            radius = reminder.adHocRadius ?? 150
            cameraPosition = .region(MKCoordinateRegion(
                center: pin!,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    private func apply() {
        reminder.triggerType = trigger
        reminder.locationFired = false
        if useAdHoc, let pin {
            reminder.savedPlace = nil
            reminder.adHocLatitude = pin.latitude
            reminder.adHocLongitude = pin.longitude
            reminder.adHocRadius = radius
            reminder.adHocName = "Pinned spot"
        } else if let id = selectedPlaceID, let place = savedPlaces.first(where: { $0.id == id }) {
            reminder.savedPlace = place
            reminder.adHocLatitude = nil
            reminder.adHocLongitude = nil
            reminder.adHocRadius = nil
            reminder.adHocName = nil
        }
        onSave()
        dismiss()
    }
}
