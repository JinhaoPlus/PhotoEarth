import Foundation
import simd

nonisolated enum GlobeMath {
    static let earthRadius: Float = 1.58

    static func cartesian(
        coordinate: GeoCoordinate,
        radius: Float = earthRadius
    ) -> SIMD3<Float> {
        let latitude = Float(coordinate.latitude * .pi / 180)
        let longitude = Float(coordinate.longitude * .pi / 180)
        let cosLatitude = cos(latitude)

        return SIMD3(
            radius * cosLatitude * sin(longitude),
            radius * sin(latitude),
            radius * cosLatitude * cos(longitude)
        )
    }

    static func distanceKilometers(from lhs: GeoCoordinate, to rhs: GeoCoordinate) -> Double {
        let earthRadiusKilometers = 6_371.0
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let lhsLatitude = lhs.latitude * .pi / 180
        let rhsLatitude = rhs.latitude * .pi / 180

        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(lhsLatitude) * cos(rhsLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusKilometers * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func angularDistanceDegrees(from lhs: GeoCoordinate, to rhs: GeoCoordinate) -> Double {
        distanceKilometers(from: lhs, to: rhs) / 6_371.0 * 180 / .pi
    }

    static func centroid(of coordinates: [GeoCoordinate]) -> GeoCoordinate {
        guard !coordinates.isEmpty else { return GeoCoordinate(latitude: 0, longitude: 0) }

        let vectors = coordinates.map { coordinate -> SIMD3<Double> in
            let latitude = coordinate.latitude * .pi / 180
            let longitude = coordinate.longitude * .pi / 180
            return SIMD3(
                cos(latitude) * cos(longitude),
                cos(latitude) * sin(longitude),
                sin(latitude)
            )
        }
        let sum = vectors.reduce(SIMD3<Double>.zero, +)
        let normalized = simd_normalize(sum)
        return GeoCoordinate(
            latitude: asin(normalized.z) * 180 / .pi,
            longitude: atan2(normalized.y, normalized.x) * 180 / .pi
        )
    }
}
