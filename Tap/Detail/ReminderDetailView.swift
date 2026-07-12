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

    @State private var showLocationEditor = false
    @State private var showOnlyConditionAlert = false

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
        .sheet(isPresented: $showLocationEditor) {
            LocationConditionEditor(reminder: reminder) { persist() }
        }
        .alert("This is the only condition", isPresented: $showOnlyConditionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A reminder needs a time or a place to fire. Add the other condition first, or delete the whole reminder below.")
        }
    }

    // MARK: - Time

    private var timeSection: some View {
        Section("Time") {
            if reminder.hasTimeCondition {
                DatePicker(
                    "Remind me at",
                    selection: fireDateBinding,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                Button("Remove time", role: .destructive) {
                    if reminder.hasLocationCondition {
                        reminder.fireDate = nil
                        reminder.timeFired = false
                        persist()
                    } else {
                        showOnlyConditionAlert = true
                    }
                }
            } else {
                HStack(spacing: 8) {
                    quickTimeButton("In 1 hour", date: .now.addingTimeInterval(3600))
                    quickTimeButton("Tonight", date: tonight)
                    quickTimeButton("Tomorrow 9 AM", date: tomorrowMorning)
                }
                Button {
                    setFireDate(.now.addingTimeInterval(3600))
                } label: {
                    Label("Pick date & time", systemImage: "calendar.badge.clock")
                }
            }
        }
    }

    /// Non-optional bridge so the inline DatePicker can edit the optional date.
    private var fireDateBinding: Binding<Date> {
        Binding(
            get: { reminder.fireDate ?? .now.addingTimeInterval(3600) },
            set: { setFireDate($0) }
        )
    }

    private func quickTimeButton(_ label: String, date: Date) -> some View {
        Button(label) { setFireDate(date) }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }

    private func setFireDate(_ date: Date) {
        reminder.fireDate = date
        reminder.timeFired = false
        persist()
    }

    private var tonight: Date {
        let today8pm = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
        return today8pm > .now ? today8pm : today8pm.addingTimeInterval(86400)
    }

    private var tomorrowMorning: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
                    if reminder.hasTimeCondition {
                        clearLocation()
                        persist()
                    } else {
                        showOnlyConditionAlert = true
                    }
                }
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
