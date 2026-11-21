import Foundation
import simd

/// Exact integration of a first-order velocity response. Distance, acceleration,
/// and coasting remain the same when display frames arrive at uneven intervals.
nonisolated struct GlobeDampedAxis: Sendable {
    var velocity = 0.0

    mutating func advance(toward target: Double, response: Double, elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0, target.isFinite,
              response.isFinite, response > 0 else { return 0 }
        let decay = exp(-response * elapsed)
        let displacement = target * elapsed + (velocity - target) * (1 - decay) / response
        velocity = target + (velocity - target) * decay
        return displacement
    }
}

/// The application owns camera flights as well as direct manipulation. A flight
/// can be stopped at its currently displayed position without a second MapKit animation.
nonisolated struct GlobeCameraFlight: Sendable {
    let origin: GlobeCameraState
    let destination: GlobeCameraState
    let duration: Double
    let initialLogarithmicVelocity: Double
    let usesGreatCircle: Bool
    private(set) var elapsed = 0.0

    var isComplete: Bool { elapsed >= duration }

    init(
        origin: GlobeCameraState, destination: GlobeCameraState, duration: Double,
        initialLogarithmicVelocity: Double = 0,
        usesGreatCircle: Bool = false
    ) {
        self.origin = origin
        self.usesGreatCircle = usesGreatCircle
        self.destination = destination
        let delta = log(destination.distance / origin.distance)
        let velocity = initialLogarithmicVelocity.isFinite && delta * initialLogarithmicVelocity > 0
            ? initialLogarithmicVelocity : 0
        self.initialLogarithmicVelocity = velocity
        // A cubic with terminal velocity zero stays monotone when its initial
        // tangent is at most three times its secant. Shorten time, never cut the
        // inherited velocity, if a native limit leaves only a small distance.
        self.duration = max(0, min(duration,
            velocity == 0 ? duration : 3 * abs(delta / velocity)))
    }

    var logarithmicVelocity: Double {
        guard duration > 0, !isComplete else { return 0 }
        let t = elapsed / duration
        let delta = log(destination.distance / origin.distance)
        return 6 * t * (1 - t) * delta / duration
            + (3 * t * t - 4 * t + 1) * initialLogarithmicVelocity
    }

    mutating func advance(by interval: Double) -> GlobeCameraState {
        guard interval.isFinite, interval >= 0 else { return origin }
        elapsed = min(elapsed + interval, duration)
        guard duration > 0, !isComplete else { return destination }
        let fraction = elapsed / duration
        let eased = fraction * fraction * (3 - 2 * fraction)
        let longitudeDelta = GlobeCameraState.normalizedLongitude(
            destination.center.longitude - origin.center.longitude
        )
        return GlobeCameraState(
            center: usesGreatCircle ? Self.sphericalCenter(origin.center, destination.center, fraction: eased) : GeoCoordinate(
                latitude: origin.center.latitude
                    + (destination.center.latitude - origin.center.latitude) * eased,
                longitude: origin.center.longitude + longitudeDelta * eased
            ),
            distance: exp(log(origin.distance)
                + (log(destination.distance) - log(origin.distance)) * eased
                + fraction * pow(1 - fraction, 2) * duration * initialLogarithmicVelocity)
        )
    }

    private static func sphericalCenter(_ origin: GeoCoordinate, _ destination: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        func vector(_ point: GeoCoordinate) -> SIMD3<Double> {
            let latitude = point.latitude * .pi / 180, longitude = point.longitude * .pi / 180
            return SIMD3(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
        }
        let a = vector(origin), b = vector(destination)
        let dot = min(1, max(-1, simd_dot(a, b)))
        let v: SIMD3<Double>
        if dot > 0.999999 {
            v = simd_normalize(a + (b - a) * fraction)
        } else if dot < -0.999999 {
            let axis = abs(a.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
            let tangent = simd_normalize(simd_cross(axis, a))
            v = a * cos(.pi * fraction) + tangent * sin(.pi * fraction)
        } else {
            let angle = acos(dot)
            v = (a * sin((1 - fraction) * angle) + b * sin(fraction * angle)) / sin(angle)
        }
        return GeoCoordinate(latitude: atan2(v.z, sqrt(v.x * v.x + v.y * v.y)) * 180 / .pi,
                             longitude: atan2(v.y, v.x) * 180 / .pi)
    }
}

/// Presentation translation shares the camera's frame clock, leaving the map's
/// bounds and tile projection unchanged while the overview composition opens.
nonisolated struct GlobeFramingTransition: Sendable {
    let origin: Double
    let destination: Double
    let duration: Double
    private(set) var elapsed = 0.0
    var isComplete: Bool { elapsed >= duration }

    mutating func advance(by interval: Double) -> Double {
        guard interval.isFinite, interval >= 0 else { return origin }
        elapsed = min(elapsed + interval, duration)
        guard duration > 0, !isComplete else { return destination }
        let t = elapsed / duration
        return origin + (destination - origin) * t * t * (3 - 2 * t)
    }
}
