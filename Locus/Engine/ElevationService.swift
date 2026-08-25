import CoreLocation
import Foundation

enum ElevationService {
    private static let cacheCapacity = 2000
    private static let cacheKey = "locus.elevationCache"
    private static let cacheResolution: Double = 0.001

    // MARK: - Cache

    private static let caches = ElevationCaches()

    private final class ElevationCaches {
        var memory: [String: CLLocationDistance] = [:]
        let lock = UnfairLock()

        func value(forKey key: String) -> CLLocationDistance? {
            lock.lock()
            defer { lock.unlock() }
            return memory[key]
        }

        func set(value: CLLocationDistance, forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            if memory.count >= cacheCapacity, memory[key] == nil { return }
            memory[key] = value
        }
    }

    // MARK: - Public API

    static func elevation(at coordinate: CLLocationCoordinate2D) async -> CLLocationDistance? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let key = Self.cacheKey(for: coordinate)
        if let cached = caches.value(forKey: key) { return cached }
        guard let value = try? await fetch(coordinates: [coordinate]).first,
              value.isFinite else { return nil }
        caches.set(value: value, forKey: key)
        persistCache()
        return value
    }

    static func elevations(for coordinates: [CLLocationCoordinate2D], progress: ((Int, Int) -> Void)? = nil) async -> [CLLocationDistance?] {
        guard !coordinates.isEmpty else { return [] }
        progress?(0, coordinates.count)
        var results: [CLLocationDistance?] = []
        var uncachedIndices: [Int] = []
        var uncachedCoords: [CLLocationCoordinate2D] = []

        for (i, coord) in coordinates.enumerated() {
            guard CLLocationCoordinate2DIsValid(coord) else {
                results.append(nil)
                continue
            }
            let key = Self.cacheKey(for: coord)
            if let cached = caches.value(forKey: key) {
                results.append(cached)
            } else {
                results.append(nil)
                uncachedIndices.append(i)
                uncachedCoords.append(coord)
            }
        }

        let totalUncached = uncachedCoords.count
        let batchSize = UserDefaults.standard.elevationDataSource.maxBatchSize
        for chunkStart in stride(from: 0, to: totalUncached, by: batchSize) {
            let chunk = Array(uncachedCoords[chunkStart..<min(chunkStart + batchSize, totalUncached)])
            let fetched = (try? await fetch(coordinates: chunk)) ?? []

            for (offset, coord) in chunk.enumerated() {
                let idx = uncachedIndices[chunkStart + offset]
                if offset < fetched.count, fetched[offset].isFinite {
                    results[idx] = fetched[offset]
                    let key = Self.cacheKey(for: coord)
                    caches.set(value: fetched[offset], forKey: key)
                }
            }
            progress?(chunkStart + chunk.count, totalUncached)
        }

        persistCache()
        return results
    }

    static func warmCache(for coordinates: [CLLocationCoordinate2D]) {
        Task { _ = await elevations(for: coordinates) }
    }

    // MARK: - Fetch dispatcher

    private static func fetch(coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        guard !coordinates.isEmpty else { return [] }
        switch UserDefaults.standard.elevationDataSource {
        case .openMeteo: return try await fetchOpenMeteo(coordinates)
        case .kuonGEO: return try await fetchKuonGEO(coordinates)
        case .elevationApiEu: return try await fetchElevationApiEu(coordinates)
        case .openTopoData: return try await fetchOpenTopoData(coordinates)
        case .openTopography: return try await fetchOpenTopography(coordinates)
        case .esri: return try await fetchEsri(coordinates)
        case .googleMaps: return try await fetchGoogleMaps(coordinates)
        }
    }

    // MARK: - Open-Meteo

    private static func fetchOpenMeteo(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        let lats = coordinates.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")
        let lons = coordinates.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
        var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: lats),
            URLQueryItem(name: "longitude", value: lons),
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return decoded.elevation
    }

    // MARK: - KUON GEO (single-point, parallelized for batch)

    private static func fetchKuonGEO(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        try await withThrowingTaskGroup(of: (Int, CLLocationDistance).self) { group in
            for (i, coord) in coordinates.enumerated() {
                group.addTask {
                    let lat = String(format: "%.5f", coord.latitude)
                    let lon = String(format: "%.5f", coord.longitude)
                    guard var components = URLComponents(string: "https://kuongeo.com/api/elevation") else { return (i, 0) }
                    components.queryItems = [
                        URLQueryItem(name: "lat", value: lat),
                        URLQueryItem(name: "lon", value: lon),
                    ]
                    guard let url = components.url else { return (i, 0) }
                    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
                    let decoded = try JSONDecoder().decode(KuonGEOResponse.self, from: data)
                    return (i, decoded.elevation_m)
                }
            }
            var results = [CLLocationDistance?](repeating: nil, count: coordinates.count)
            for try await (i, elev) in group {
                results[i] = elev
            }
            return results.map { $0 ?? 0 }
        }
    }

    // MARK: - Elevation API EU

    private static func fetchElevationApiEu(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        let pts = coordinates.map { String(format: "[%.5f,%.5f]", $0.latitude, $0.longitude) }.joined(separator: ",")
        var components = URLComponents(string: "https://www.elevation-api.eu/v1/elevation")!
        components.queryItems = [URLQueryItem(name: "pts", value: "[[\(pts.dropFirst().dropLast())]]")]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        let decoded = try JSONDecoder().decode(ElevationApiEuResponse.self, from: data)
        return decoded.elevations
    }

    // MARK: - Open Topo Data

    private static func fetchOpenTopoData(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        let locations = coordinates.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: "|")
        var components = URLComponents(string: "https://api.opentopodata.org/v1/srtm30m")!
        components.queryItems = [URLQueryItem(name: "locations", value: locations)]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        let decoded = try JSONDecoder().decode(OpenTopoDataResponse.self, from: data)
        return decoded.results.map { $0.elevation }
    }

    // MARK: - Esri ArcGIS

    private static func fetchEsri(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        guard let apiKey = UserDefaults.standard.elevationAPIKey(for: .esri), !apiKey.isEmpty else { return [] }
        guard let url = URL(string: "https://elevation-api.arcgis.com/arcgis/rest/services/elevation-service/v1/elevation/at-many-points") else { return [] }
        let coords = coordinates.map { [round($0.longitude * 100000) / 100000, round($0.latitude * 100000) / 100000] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(EsriRequestBody(coordinates: coords))
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(EsriResponse.self, from: data)
        return decoded.result.points.map { $0.z }
    }

    // MARK: - OpenTopography

    private static func fetchOpenTopography(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        guard let apiKey = UserDefaults.standard.elevationAPIKey(for: .openTopography), !apiKey.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, CLLocationDistance).self) { group in
            for (i, coord) in coordinates.enumerated() {
                group.addTask {
                    let lat = String(format: "%.5f", coord.latitude)
                    let lon = String(format: "%.5f", coord.longitude)
                    var components = URLComponents(string: "https://portal.opentopography.org/API/globaldem")!
                    components.queryItems = [
                        URLQueryItem(name: "demtype", value: "COP30"),
                        URLQueryItem(name: "south", value: lat),
                        URLQueryItem(name: "north", value: lat),
                        URLQueryItem(name: "west", value: lon),
                        URLQueryItem(name: "east", value: lon),
                        URLQueryItem(name: "outputFormat", value: "JSON"),
                        URLQueryItem(name: "api_key", value: apiKey),
                    ]
                    guard let url = components.url else { return (i, 0) }
                    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
                    if let decoded = try? JSONDecoder().decode(OpenTopographyResponse.self, from: data) {
                        return (i, decoded.elevation ?? 0)
                    }
                    return (i, 0)
                }
            }
            var results = [CLLocationDistance](repeating: 0, count: coordinates.count)
            for try await (i, elev) in group {
                results[i] = elev
            }
            return results
        }
    }

    // MARK: - Google Maps

    private static func fetchGoogleMaps(_ coordinates: [CLLocationCoordinate2D]) async throws -> [CLLocationDistance] {
        guard let apiKey = UserDefaults.standard.elevationAPIKey(for: .googleMaps), !apiKey.isEmpty else { return [] }
        let locations = coordinates.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: "|")
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/elevation/json")!
        components.queryItems = [
            URLQueryItem(name: "locations", value: locations),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        let decoded = try JSONDecoder().decode(GoogleElevationResponse.self, from: data)
        return decoded.results.map { $0.elevation }
    }

    // MARK: - Persistence

    private static var lastPersistAt: Date?

    private static func persistCache() {
        if let last = lastPersistAt, Date().timeIntervalSince(last) < 10 { return }
        lastPersistAt = Date()
        let snapshot = caches.lock.withLock { caches.memory }
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
    }

    static func loadPersistedCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CLLocationDistance].self, from: data) else { return }
        caches.lock.withLock { caches.memory = decoded }
    }

    // MARK: - Helpers

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = round(coordinate.latitude / cacheResolution) * cacheResolution
        let lon = round(coordinate.longitude / cacheResolution) * cacheResolution
        return String(format: "%.4f,%.4f", lat, lon)
    }
}

// MARK: - Response types

private struct OpenMeteoResponse: Decodable {
    let elevation: [CLLocationDistance]
}

private struct KuonGEOResponse: Decodable {
    let elevation_m: CLLocationDistance
}

private struct ElevationApiEuResponse: Decodable {
    let elevations: [CLLocationDistance]
}

private struct OpenTopoDataResponse: Decodable {
    struct Result: Decodable {
        let elevation: CLLocationDistance
    }
    let results: [Result]
    let status: String
}

private struct EsriRequestBody: Encodable {
    let coordinates: [[Double]]
    let relativeTo = "meanSeaLevel"
    let f = "json"
}

private struct EsriResponse: Decodable {
    struct Result: Decodable {
        struct Point: Decodable {
            let z: CLLocationDistance
        }
        let points: [Point]
    }
    let result: Result
}

private struct OpenTopographyResponse: Decodable {
    let elevation: CLLocationDistance?
}

private struct GoogleElevationResponse: Decodable {
    struct Result: Decodable {
        let elevation: CLLocationDistance
    }
    let results: [Result]
    let status: String
}

// MARK: - Unfair lock shim for iOS 15

private final class UnfairLock {
    private var _lock = os_unfair_lock()
    func lock() { os_unfair_lock_lock(&_lock) }
    func unlock() { os_unfair_lock_unlock(&_lock) }
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}