import Foundation

struct LocusBackup: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var exportedAt = Date()
    var favorites: [SavedPlace]
    var searchHistory: [SearchHistoryEntry]
    var preferences: BackupPreferences
    /// Saved routes. Optional so backups written before routes were included
    /// still decode (and simply restore nothing).
    var savedRoutes: [SavedRoute]? = nil

    func validated() throws -> LocusBackup {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BackupError.unsupportedVersion(schemaVersion)
        }
        guard favorites.count <= 10_000, searchHistory.count <= 1_000 else {
            throw BackupError.invalidContent
        }
        guard (savedRoutes?.count ?? 0) <= 200 else {
            throw BackupError.invalidContent
        }
        guard (savedRoutes ?? []).allSatisfy({ route in
            route.latitudes.count == route.longitudes.count
                && route.latitudes.count <= SavedRoute.maxStoredPoints
                && zip(route.latitudes, route.longitudes).allSatisfy { Self.valid(latitude: $0.0, longitude: $0.1) }
        }) else {
            throw BackupError.invalidContent
        }
        guard favorites.allSatisfy({ Self.valid(latitude: $0.latitude, longitude: $0.longitude) }),
              searchHistory.allSatisfy({ Self.valid(latitude: $0.latitude, longitude: $0.longitude) }) else {
            throw BackupError.invalidContent
        }
        return self
    }

    private static func valid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct BackupPreferences: Codable {
    var travelMode: String
    var speedMultiplier: Double
    var routeLoopEnabled: Bool
    var routeLoopCount: Int
    var mapStyleIndex: Int
    var targetSelectionMode: String
    var searchHistoryEnabled: Bool
    var autoFollowRoute: Bool
    var restoreLastMapView: Bool
    var appearanceMode: String?
    var zoomSliderEnabled: Bool?
    /// Optional so backups written before this field existed still decode.
    var altitudeEnabled: Bool?
    /// Selected elevation provider, plus the API keys of *every* provider (only
    /// some need one), so a restore on another device does not require
    /// re-entering keys for providers the user switches between.
    var elevationDataSource: String?
    var elevationAPIKeys: [String: String]?
    var locationJitterEnabled: Bool?
    var locationJitterRadius: Double?
    var locationUpdateInterval: Double?
    var locationUpdateJitter: Double?
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return L("不支持版本为 %@ 的 Locus 备份。", "\(version)")
        case .invalidContent:
            return L("备份包含无效或超出范围的数据。")
        }
    }
}
