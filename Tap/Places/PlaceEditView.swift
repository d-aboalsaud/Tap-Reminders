import SwiftUI
import SwiftData
import MapKit

struct PlaceEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let place: SavedPlace?

    @State private var name = ""
    @State private var pin: CLLocationCoordinate2D?
    @State private var radius: Double = 150
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 30.0444, longitude: 31.2357),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Home, Work, Gym…", text: $name)
                }
                Section("Tap the map to set the location") {
                    MapReader { proxy in
                        Map(position: $cameraPosition) {
                            if let pin {
                                Marker(name.isEmpty ? "Place" : name, coordinate: pin)
                                MapCircle(center: pin, radius: radius)
                                    .foregroundStyle(.blue.opacity(0.15))
                                    .stroke(.blue, lineWidth: 1)
                            }
                        }
                        .frame(height: 280)
                        .onTapGesture { screenPoint in
                            if let coord = proxy.convert(screenPoint, from: .local) {
                                pin = coord
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())

                    VStack(alignment: .leading) {
                        Text("Geofence radius: \(Int(radius)) m").font(.callout)
                        Slider(value: $radius, in: 50...1000, step: 25)
                    }
                }
            }
            .navigationTitle(place == nil ? "New place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || pin == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        guard let place else { return }
        name = place.name
        pin = place.coordinate
        radius = place.radius
        cameraPosition = .region(MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
    }

    private func save() {
        guard let pin else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let place {
            place.name = trimmed
            place.latitude = pin.latitude
            place.longitude = pin.longitude
            place.radius = radius
        } else {
            context.insert(SavedPlace(name: trimmed, latitude: pin.latitude, longitude: pin.longitude, radius: radius))
        }
        try? context.save()
        dismiss()
    }
}
