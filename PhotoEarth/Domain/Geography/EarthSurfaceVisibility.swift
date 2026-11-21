import Foundation

/// The surface cap visible from the camera's actual eye position. At nonzero
/// pitch its center differs from the look-at coordinate, so a circle around the
/// look-at point alone includes ground hidden behind the planet.
nonisolated struct EarthSurfaceVisibility: Equatable, Sendable {
    let center: GeoCoordinate
    let angularRadius: Double

    init(center: GeoCoordinate, distance: Double, pitch: Double, heading: Double) {
        guard center.isValid, distance.isFinite, distance > 0,
              pitch.isFinite, heading.isFinite else {
            // Invalid camera metadata must not silently discard otherwise valid
            // viewport results. The primary viewport cap still bounds the query.
            self.center = GeoCoordinate(latitude: 0, longitude: 0)
            angularRadius = 180
            return
        }

        let radius = 6_371_000.0
        let latitude = center.latitude * .pi / 180
        let longitude = center.longitude * .pi / 180
        let tilt = min(max(pitch, 0), 85) * .pi / 180
        let bearing = heading.truncatingRemainder(dividingBy: 360) * .pi / 180
        let axialDistance = radius + distance * cos(tilt)
        let lateralDistance = distance * sin(tilt)
        let eyeRadius = hypot(axialDistance, lateralDistance)
        let axialWeight = axialDistance / eyeRadius
        let lateralWeight = lateralDistance / eyeRadius

        let normal = SIMD3(cos(latitude) * cos(longitude),
                           cos(latitude) * sin(longitude), sin(latitude))
        let north = SIMD3(-sin(latitude) * cos(longitude),
                          -sin(latitude) * sin(longitude), cos(latitude))
        let east = SIMD3(-sin(longitude), cos(longitude), 0.0)
        let forward = north * cos(bearing) + east * sin(bearing)
        // A camera looking north is south of its look-at point.
        let eyeDirection = normal * axialWeight - forward * lateralWeight
        self.center = GeoCoordinate(
            latitude: asin(min(max(eyeDirection.z, -1), 1)) * 180 / .pi,
            longitude: atan2(eyeDirection.y, eyeDirection.x) * 180 / .pi
        )
        angularRadius = acos(min(max(radius / eyeRadius, 0), 1)) * 180 / .pi
    }

    func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard coordinate.isValid else { return false }
        return GlobeMath.angularDistanceDegrees(from: center, to: coordinate)
            <= angularRadius + 0.000_000_001
    }
}
