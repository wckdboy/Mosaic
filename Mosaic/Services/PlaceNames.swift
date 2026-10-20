import CoreLocation
import Foundation

// Reverse geocoding is optional and only used to name photobook chapters. The media
// itself never leaves the device; a rounded coordinate is sent to Apple's geocoder,
// and the result is cached locally. A failed lookup is harmless and is not cached.
actor PlaceNameService {
    static let shared = PlaceNameService()
    private var cache: [String: String] = [:]
    private var loaded = false
    private let url: URL

    init() {
        let root = URL.applicationSupportDirectory.appending(path: "Mosaic", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appending(path: "place-names.json")
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            cache = decoded
        }
        loaded = true
    }

    func name(latitude: Double, longitude: Double) async -> String? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        let key = Self.key(latitude: latitude, longitude: longitude)
        if let cached = cache[key] { return cached }
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude))
            guard let placemark = placemarks.first else { return nil }
            let name =
                placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
            guard let name, !name.isEmpty else { return nil }
            cache[key] = name
            persist()
            return name
        } catch {
            return nil
        }
    }

    /// Names up to `limit` distinct places from the set of chapter coordinates.
    /// Rounding to roughly a kilometre keeps one city from costing dozens of lookups.
    func names(
        for coordinates: [(latitude: Double, longitude: Double)], limit: Int = 16
    ) async -> [String: String] {
        var seen: [String: String] = [:]
        var lookups = 0
        for coordinate in coordinates {
            let key = Self.key(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let cached = cache[key] {
                seen[key] = cached
                continue
            }
            guard lookups < limit else { break }
            lookups += 1
            if let name = await name(
                latitude: coordinate.latitude, longitude: coordinate.longitude)
            {
                seen[key] = name
            }
        }
        return seen
    }

    func cachedName(latitude: Double, longitude: Double) -> String? {
        cache[Self.key(latitude: latitude, longitude: longitude)]
    }

    static func key(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    private func persist() {
        guard loaded else { return }
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Place names are decorative chapter titles, not user data.
        }
    }
}
