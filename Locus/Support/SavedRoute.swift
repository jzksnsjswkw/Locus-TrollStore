import CoreLocation
import Foundation

/// A saved route: the polyline plus enough metadata to recognise it again.
///
/// Stored in `UserDefaults` alongside favorites and search history. That is
/// deliberate: this build is signed without a data container, so writing to the
/// container is refused by the sandbox, while `UserDefaults` goes through
/// `cfprefsd` (a system daemon that does the IO on our behalf) and works
/// normally. Keeping routes out of the filesystem also means no new
/// permissions are needed to save them.
struct SavedRoute: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
    /// Flattened coordinates so the payload stays JSON-friendly. For a
    /// hand-drawn route these are the sampled display line.
    var latitudes: [Double]
    var longitudes: [Double]
    /// Original hand-drawn vertices, when `source == .drawn`.
    ///
    /// The displayed polyline is resampled to one point every 10 m, which loses
    /// the corners the user actually placed. Re-editing needs those vertices
    /// back, so they are stored separately. Optional so routes saved before this
    /// field existed still decode.
    var rawLatitudes: [Double]? = nil
    var rawLongitudes: [Double]? = nil
    /// Where it came from, for the list subtitle.
    var source: Source = .imported

    enum Source: String, Codable {
        case imported
        case drawn
        case planned

        var label: String {
            switch self {
            case .imported: return L("导入")
            case .drawn: return L("手绘")
            case .planned: return L("规划")
            }
        }
    }

    var coordinates: [CLLocationCoordinate2D] {
        zip(latitudes, longitudes).map {
            CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
        }
    }

    var pointCount: Int { latitudes.count }

    /// Straight-line length in metres, useful as a list subtitle without
    /// re-deriving a polyline.
    var distance: CLLocationDistance {
        let points = coordinates
        guard points.count > 1 else { return 0 }
        var total: CLLocationDistance = 0
        for (a, b) in zip(points, points.dropFirst()) {
            total += CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        return total
    }

    var distanceText: String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        let measurement = Measurement(value: distance, unit: UnitLength.meters)
        return formatter.string(from: measurement)
    }

    /// Vertices to use when the route is re-opened for editing: the original
    /// drawing when available, otherwise the stored line.
    var editableVertices: [CLLocationCoordinate2D] {
        if let rawLatitudes, let rawLongitudes,
           rawLatitudes.count == rawLongitudes.count,
           rawLatitudes.count > 1 {
            return zip(rawLatitudes, rawLongitudes).map {
                CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
            }
        }
        return coordinates
    }

    init(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        source: Source = .imported,
        rawVertices: [CLLocationCoordinate2D]? = nil
    ) {
        self.name = name
        self.latitudes = coordinates.map(\.latitude)
        self.longitudes = coordinates.map(\.longitude)
        if let rawVertices, rawVertices.count > 1 {
            self.rawLatitudes = rawVertices.map(\.latitude)
            self.rawLongitudes = rawVertices.map(\.longitude)
        }
        self.source = source
    }

    static let storageKey = "locus.savedRoutes"
    /// Payload guard: a route with more points than this is almost certainly a
    /// bad parse, and UserDefaults is not meant for large blobs.
    static let maxStoredPoints = 20_000
    static let maxStoredRoutes = 50

    static func load() -> [SavedRoute] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ routes: [SavedRoute]) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum SavedRouteError: LocalizedError {
    case empty
    case tooManyPoints(Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return L("当前没有可保存的轨迹。")
        case .tooManyPoints(let count):
            return L("轨迹包含 %@ 个点，超过可保存上限 %@ 个。", "\(count)", "\(SavedRoute.maxStoredPoints)")
        }
    }
}
