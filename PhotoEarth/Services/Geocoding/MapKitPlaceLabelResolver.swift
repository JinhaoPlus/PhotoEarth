import Combine
import MapKit

nonisolated struct PlaceDisplayLabel: Equatable, Sendable {
    let city: String
    let country: String?

    init(city: String, country: String?) {
        self.city = city
        self.country = country
    }

    init(place: TravelPlace) {
        city = place.name
        country = place.country
    }
}

/// A small offline safety net for the deterministic simulator fixture and a few
/// unambiguous city centers. Other coordinates still use MapKit.
nonisolated enum BundledPlaceFallbackCatalog {
    private struct Entry: Sendable {
        let coordinate: GeoCoordinate
        let label: PlaceDisplayLabel
    }

    private static let entries = [
        Entry(coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426), label: PlaceDisplayLabel(city: "雷克雅未克", country: "冰岛")),
        Entry(coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), label: PlaceDisplayLabel(city: "巴黎", country: "法国")),
        Entry(coordinate: GeoCoordinate(latitude: 35.6762, longitude: 139.6503), label: PlaceDisplayLabel(city: "东京", country: "日本")),
        Entry(coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), label: PlaceDisplayLabel(city: "纽约", country: "美国")),
        Entry(coordinate: GeoCoordinate(latitude: 1.3521, longitude: 103.8198), label: PlaceDisplayLabel(city: "新加坡", country: "新加坡")),
        Entry(coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784), label: PlaceDisplayLabel(city: "伊斯坦布尔", country: "土耳其")),
        Entry(coordinate: GeoCoordinate(latitude: -33.9249, longitude: 18.4241), label: PlaceDisplayLabel(city: "开普敦", country: "南非")),
        Entry(coordinate: GeoCoordinate(latitude: -22.9068, longitude: -43.1729), label: PlaceDisplayLabel(city: "里约热内卢", country: "巴西")),
        Entry(coordinate: GeoCoordinate(latitude: 51.1784, longitude: -115.5708), label: PlaceDisplayLabel(city: "班夫", country: "加拿大")),
        Entry(coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093), label: PlaceDisplayLabel(city: "悉尼", country: "澳大利亚")),
    ]

    static func label(
        near coordinate: GeoCoordinate,
        maximumDistanceKilometers: Double = 35
    ) -> PlaceDisplayLabel? {
        entries
            .map { entry in
                (entry, GlobeMath.distanceKilometers(from: coordinate, to: entry.coordinate))
            }
            .filter { $0.1 <= maximumDistanceKilometers }
            .min { $0.1 < $1.1 }?
            .0.label
    }
}

@MainActor
final class MapKitPlaceLabelResolver: ObservableObject {
    private var cache: [String: PlaceDisplayLabel] = [:]
    private var activeRequests: [MKReverseGeocodingRequest] = []

    func labels(for places: [TravelPlace]) async -> [String: PlaceDisplayLabel] {
        var result: [String: PlaceDisplayLabel] = [:]
        for place in places {
            if let cached = cache[place.id] {
                result[place.id] = cached
                continue
            }

            guard place.country == nil || place.name.hasPrefix("地点") else {
                continue
            }

            if let bundled = BundledPlaceFallbackCatalog.label(near: place.coordinate) {
                cache[place.id] = bundled
                result[place.id] = bundled
                continue
            }

            if let label = await reverseGeocodeWithRetry(place: place) {
                cache[place.id] = label
                result[place.id] = label
            }
        }
        return result
    }

    func cancel() {
        activeRequests.forEach { $0.cancel() }
        activeRequests.removeAll()
    }

    private func reverseGeocodeWithRetry(place: TravelPlace) async -> PlaceDisplayLabel? {
        for attempt in 0..<3 {
            if let label = await reverseGeocode(place: place) { return label }
            guard attempt < 2, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
        }
        return nil
    }

    private func reverseGeocode(place: TravelPlace) async -> PlaceDisplayLabel? {
        let location = CLLocation(
            latitude: place.coordinate.latitude,
            longitude: place.coordinate.longitude
        )
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "zh_CN")
        activeRequests.append(request)
        defer { activeRequests.removeAll { $0 === request } }

        let mapItems: [MKMapItem] = await withCheckedContinuation { continuation in
            request.getMapItems { items, _ in
                continuation.resume(returning: items ?? [])
            }
        }
        guard !Task.isCancelled,
              let mapItem = mapItems.first,
              let representations = mapItem.addressRepresentations else { return nil }
        let city = representations.cityName
            ?? representations.cityWithContext
            ?? mapItem.name
            ?? place.name
        return PlaceDisplayLabel(city: city, country: representations.regionName)
    }
}
