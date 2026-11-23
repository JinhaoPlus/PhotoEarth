import Foundation

/// Geographic extent of the city's distinct shooting positions, unwrapped around the visit.
nonisolated struct CityLandingFrame {
    // Trim one extreme on each side per 20 distinct locations, independently on each axis.
    static let locationsPerTrim = 20

    let south: Double
    let north: Double
    let west: Double
    let east: Double

    var camera: GlobeCameraState {
        let latitude = (north + south) / 2
        let longitude = MapReviewGrid.normalizedLongitude((east + west) / 2)
        let metersPerDegree = Double.pi * 6_371_000 / 180
        let height = (north - south) * metersPerDegree
        let width = (east - west) * metersPerDegree * cos(latitude * .pi / 180)
        // Leave room for the photo strip under a top-down 16:9 tvOS map.
        let distance = max(height * 2.8, width * 1.6)
        return GlobeCameraState(center: .init(latitude: latitude, longitude: longitude),
                                distance: min(GlobeCameraState.regionalDistance, max(1_500, distance)))
    }

    /// Only the small bundled demo has photo records in memory.
    static func demo(coordinates: Set<GeoCoordinate>, reference: Double) -> Self? {
        guard !coordinates.isEmpty else { return nil }
        let grid = MapReviewGrid.world(around: reference)
        let latitudes = coordinates.map(\.latitude).sorted()
        let longitudes = coordinates.map { grid.unwrappedLongitude($0.longitude) }.sorted()
        let trim = coordinates.count / locationsPerTrim
        let last = coordinates.count - 1 - trim
        return Self(south: latitudes[trim], north: latitudes[last], west: longitudes[trim], east: longitudes[last])
    }
}
