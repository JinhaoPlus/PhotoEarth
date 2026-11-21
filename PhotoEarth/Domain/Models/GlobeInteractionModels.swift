import Foundation

nonisolated struct GlobeCameraState: Equatable, Sendable {
    static let minimumDistance = 100.0
    static let regionalDistance = 800_000.0
    static let maximumDistance = 42_000_000.0
    static let defaultDistance = 23_500_000.0
    /// Home and exploration share one close orbital composition. Keep the
    /// original reference distance above for the already-tuned gesture gain.
    static let orbitalDistance = 10_000_000.0

    var center: GeoCoordinate
    var distance: Double

    init(
        center: GeoCoordinate = GeoCoordinate(latitude: 24, longitude: 18),
        distance: Double = Self.defaultDistance
    ) {
        self.center = GeoCoordinate(
            latitude: center.latitude.isFinite ? min(max(center.latitude, -84), 84) : 0,
            longitude: center.longitude.isFinite ? Self.normalizedLongitude(center.longitude) : 0
        )
        self.distance = distance.isFinite
            ? min(max(distance, Self.minimumDistance), Self.maximumDistance)
            : Self.defaultDistance
    }

    mutating func rotate(longitudeDelta: Double, latitudeDelta: Double) {
        guard longitudeDelta.isFinite, latitudeDelta.isFinite else { return }
        center = GeoCoordinate(
            latitude: min(max(center.latitude + latitudeDelta, -84), 84),
            longitude: Self.normalizedLongitude(center.longitude + longitudeDelta)
        )
    }

    /// Perspective-scaled travel has no world-scale floor. A gesture covers a
    /// comparable part of the screen from orbit down to regional terrain.
    var navigationScale: Double {
        atan(distance / 6_371_000) / atan(Self.defaultDistance / 6_371_000)
    }

    var presentationPitch: Double {
        func smooth(_ value: Double) -> Double {
            let t = min(max(value, 0), 1)
            return t * t * (3 - 2 * t)
        }
        // The native tvOS globe currently supports 35 degrees. Ease into a
        // straight-down regional view and back to a whole globe when zooming far out.
        let approachingOrbit = smooth(log(distance / Self.regionalDistance) / log(3_500_000.0 / Self.regionalDistance))
        // The native globe flattens abruptly close to its latitude-scaled
        // maximum distance. Finish our own continuous tilt before that boundary.
        // Native MapKit disables pitch around 60° latitude. Ease out before
        // that boundary so a north/south drag cannot abruptly flatten the globe.
        let approachingPole = smooth((abs(center.latitude) - 45) / 10)
        guard approachingPole < 1 else { return 0 }
        let latitudeScale = cos(center.latitude * .pi / 180)
        // Keep the home orbit's latitude transition independent of far zoom.
        // Overlapping both fades at 10 Mm makes a polar drag flatten too quickly.
        let farStart = max(Self.orbitalDistance, 14_500_000 * latitudeScale)
        let farEnd = 19_000_000 * latitudeScale
        let leavingOrbit = smooth(log(distance / farStart) / log(farEnd / farStart))
        return 35 * approachingOrbit * (1 - leavingOrbit) * (1 - approachingPole)
    }

    mutating func translateSurface(eastDegrees: Double, northDegrees: Double) {
        // Longitude degrees become shorter toward the poles. Compensate at map
        // scale, blending away in orbit where the spherical silhouette dominates.
        let mapWeight = 1 / (1 + pow(distance / 1_000_000, 2))
        let longitudeCompensation = 1 + mapWeight * (
            1 / max(cos(center.latitude * .pi / 180), 0.1045) - 1
        )
        rotate(longitudeDelta: eastDegrees * longitudeCompensation, latitudeDelta: northDegrees)
    }

    mutating func panWithTouchSurface(
        horizontalDelta: Double,
        verticalDelta: Double,
        sensitivity: Double,
        verticalSensitivity: Double? = nil
    ) {
        // Dragging anywhere on the touch surface "grabs" the globe. Moving a finger right
        // moves the visible surface right, which means looking farther west.
        translateSurface(
            eastDegrees: -horizontalDelta * sensitivity,
            northDegrees: -verticalDelta * (verticalSensitivity ?? sensitivity * 0.76)
        )
    }

    mutating func zoom(logarithmicDelta: Double) {
        guard logarithmicDelta.isFinite else { return }
        let logarithmicDistance = min(
            max(log(distance) + logarithmicDelta, log(Self.minimumDistance)),
            log(Self.maximumDistance)
        )
        if logarithmicDistance <= log(Self.minimumDistance) {
            distance = Self.minimumDistance
        } else if logarithmicDistance >= log(Self.maximumDistance) {
            distance = Self.maximumDistance
        } else {
            distance = exp(logarithmicDistance)
        }
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = longitude.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

nonisolated struct EarthViewport: Equatable, Sendable {
    static let minimumAngularRadius = 0.0005
    let center: GeoCoordinate
    let angularRadius: Double
    let visibilityCap: EarthSurfaceVisibility?

    init(
        center: GeoCoordinate,
        angularRadius: Double,
        visibilityCap: EarthSurfaceVisibility? = nil
    ) {
        self.center = center
        self.angularRadius = angularRadius.isFinite
            ? min(max(angularRadius, Self.minimumAngularRadius), 94) : 94
        self.visibilityCap = visibilityCap
    }

    func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard coordinate.isValid,
              GlobeMath.angularDistanceDegrees(from: center, to: coordinate) <= angularRadius else {
            return false
        }
        return visibilityCap?.contains(coordinate) ?? true
    }

    func differsMeaningfully(from previous: EarthViewport) -> Bool {
        let centerDelta = GlobeMath.angularDistanceDegrees(from: previous.center, to: center)
        let radiusDelta = abs(previous.angularRadius - angularRadius)
        let centerTolerance = max(Self.minimumAngularRadius * 0.1, angularRadius * 0.055)
        let radiusTolerance = max(Self.minimumAngularRadius * 0.1, angularRadius * 0.08)
        if centerDelta > centerTolerance || radiusDelta > radiusTolerance { return true }
        switch (visibilityCap, previous.visibilityCap) {
        case (nil, nil):
            return false
        case let (current?, previous?):
            return GlobeMath.angularDistanceDegrees(from: previous.center, to: current.center) > centerTolerance
                || abs(current.angularRadius - previous.angularRadius) > radiusTolerance
        default:
            return true
        }
    }
}

nonisolated struct PhotoQueryPage: Equatable, Sendable {
    let records: [PhotoAssetRecord]
    let nextOffset: Int?
}
