import Foundation

enum ElevationDataSource: String, CaseIterable, Codable, Identifiable {
    case openMeteo
    case kuonGEO
    case elevationApiEu
    case openTopoData
    case esri
    case openTopography
    case googleMaps

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openMeteo: return "Open-Meteo"
        case .kuonGEO: return "KUON GEO"
        case .elevationApiEu: return "Elevation API EU"
        case .openTopoData: return "Open Topo Data"
        case .openTopography: return "OpenTopography"
        case .esri: return "Esri ArcGIS"
        case .googleMaps: return "Google Elevation"
        }
    }

    var recommendationTag: String? {
        switch self {
        case .openMeteo: return L("推荐 快速")
        case .kuonGEO: return L("推荐 高精度")
        case .elevationApiEu: return L("推荐")
        case .openTopoData: return L("高精度")
        case .openTopography: return nil
        case .esri: return L("高精度")
        case .googleMaps: return nil
        }
    }

    var pickerLabel: String {
        if let tag = recommendationTag {
            return "\(displayName)（\(tag)）"
        }
        return displayName
    }

    var resolution: String {
        switch self {
        case .openMeteo: return "90m（Copernicus DEM）"
        case .kuonGEO: return "~17.6m（Mapzen/Tilezen）"
        case .elevationApiEu: return "~90m（Copernicus DEM）"
        case .openTopoData: return "30m（SRTM）"
        case .openTopography: return "30m（COP30）"
        case .esri: return "30m（TopoBathy）"
        case .googleMaps: return "30m（SRTM）"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openMeteo, .kuonGEO, .elevationApiEu, .openTopoData: return false
        case .openTopography, .esri, .googleMaps: return true
        }
    }

    var registerURL: URL? {
        switch self {
        case .openMeteo, .kuonGEO, .elevationApiEu, .openTopoData: return nil
        case .openTopography: return URL(string: "https://opentopography.org/developers/")
        case .esri: return URL(string: "https://developers.arcgis.com/documentation/mapping-apis-and-services/security/api-keys/")
        case .googleMaps: return URL(string: "https://developers.google.com/maps/documentation/elevation/start")
        }
    }

    var maxBatchSize: Int {
        switch self {
        case .openMeteo: return 100
        case .kuonGEO: return 10
        case .elevationApiEu: return 100
        case .openTopoData: return 100
        case .openTopography: return 10
        case .esri: return 100
        case .googleMaps: return 512
        }
    }

    var description: String {
        switch self {
        case .openMeteo: return L("%@ · %@ · 免费", "\(pickerLabel)", "\(resolution)")
        case .kuonGEO: return L("%@ · %@ · 免费无限制", "\(pickerLabel)", "\(resolution)")
        case .elevationApiEu: return L("%@ · %@ · 免费，10次/秒", "\(pickerLabel)", "\(resolution)")
        case .openTopoData: return L("%@ · %@ · 免费，限速 1次/秒、1000次/天", "\(pickerLabel)", "\(resolution)")
        case .openTopography: return L("%@ · %@ · 需 Key，免费 限 50次/天", "\(pickerLabel)", "\(resolution)")
        case .esri: return L("%@ · %@ · 需 Key，免费 5万次/月", "\(pickerLabel)", "\(resolution)")
        case .googleMaps: return L("Google 官方 Elevation API · %@ · 按量付费", "\(resolution)")
        }
    }
}

// MARK: - UserDefaults persistence keys

extension UserDefaults {
    static let elevationDataSourceKey = "elevation.dataSource"
    static let elevationAPIKeyPrefix = "elevation.apiKey."

    var elevationDataSource: ElevationDataSource {
        get {
            guard let raw = string(forKey: Self.elevationDataSourceKey),
                  let source = ElevationDataSource(rawValue: raw) else { return .openMeteo }
            return source
        }
        set { set(newValue.rawValue, forKey: Self.elevationDataSourceKey) }
    }

    func elevationAPIKey(for source: ElevationDataSource) -> String? {
        string(forKey: Self.elevationAPIKeyPrefix + source.rawValue)
    }

    func setElevationAPIKey(_ key: String?, for source: ElevationDataSource) {
        set(key, forKey: Self.elevationAPIKeyPrefix + source.rawValue)
    }
}