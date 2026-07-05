import Foundation
import SwiftData
import CoreLocation

@Model
final class SavedPlace {
    @Attribute(.unique) var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double = 150) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
