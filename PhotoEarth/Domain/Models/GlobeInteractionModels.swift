import Foundation

nonisolated struct GlobeCameraState: Equatable, Sendable {
    static let minimumDistance = 1_600_000.0
    static let maximumDistance = 42_000_000.0
    static let defaultDistance = 23_500_000.0

    var center: GeoCoordinate
    var distance: Double

    init(
        center: GeoCoordinate = GeoCoordinate(latitude: 24, longitude: 18),
        distance: Double = Self.defaultDistance
    ) {
        self.center = center
        self.distance = min(max(distance, Self.minimumDistance), Self.maximumDistance)
    }

    mutating func rotate(longitudeDelta: Double, latitudeDelta: Double) {
        center = GeoCoordinate(
            latitude: min(max(center.latitude + latitudeDelta, -84), 84),
            longitude: Self.normalizedLongitude(center.longitude + longitudeDelta)
        )
    }

    mutating func panWithTouchSurface(
        horizontalDelta: Double,
        verticalDelta: Double,
        sensitivity: Double
    ) {
        // Touching the inner pad directly "grabs" the globe. Moving a finger right
        // moves the visible surface right, which means looking farther west.
        rotate(
            longitudeDelta: -horizontalDelta * sensitivity,
            latitudeDelta: -verticalDelta * sensitivity * 0.76
        )
    }

    mutating func zoom(logarithmicDelta: Double) {
        distance = min(
            max(distance * exp(logarithmicDelta), Self.minimumDistance),
            Self.maximumDistance
        )
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = longitude.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

nonisolated struct EarthViewport: Equatable, Sendable {
    let center: GeoCoordinate
    let angularRadius: Double

    init(center: GeoCoordinate, angularRadius: Double) {
        self.center = center
        self.angularRadius = min(max(angularRadius, 2), 94)
    }
}

nonisolated struct PhotoQueryPage: Equatable, Sendable {
    let records: [PhotoAssetRecord]
    let nextOffset: Int?
}
