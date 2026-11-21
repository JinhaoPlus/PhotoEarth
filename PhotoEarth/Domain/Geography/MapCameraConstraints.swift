import Foundation

/// A conservative presentation envelope inside MapKit's globe projection.
/// Product zoom limits are outer bounds, not a promise that MapKit accepts them
/// at every latitude. The native renderer remains the final authority.
nonisolated enum MapCameraConstraints {
    static let maximumLatitude = 83.0
    static let equatorialDistance = 20_000_000.0
    static let polarDistancePerDegree = 400_000.0

    static func maximumDistance(at latitude: Double) -> Double {
        let latitude = min(abs(latitude.isFinite ? latitude : 0), maximumLatitude)
        // The first bound stays inside the globe's latitude-dependent maximum
        // scale; the second avoids the polar normalization that reverses north/
        // south motion. Both bounds are continuous. These margins are verified
        // with native camera sweeps, and actual readback handles tighter limits.
        let orbital = equatorialDistance * cos(latitude * .pi / 180)
        let polar = GlobeCameraState.regionalDistance
            + polarDistancePerDegree * (maximumLatitude - latitude)
        return max(GlobeCameraState.regionalDistance,
                   min(GlobeCameraState.maximumDistance, orbital, polar))
    }

}

extension GlobeCameraState {
    var maximumMapDistance: Double { MapCameraConstraints.maximumDistance(at: center.latitude) }

    /// Flights and explicit zoom preserve their geographic destination.
    nonisolated func mapConstrained() -> Self {
        let latitude = min(max(center.latitude, -MapCameraConstraints.maximumLatitude),
                           MapCameraConstraints.maximumLatitude)
        return Self(center: GeoCoordinate(latitude: latitude, longitude: center.longitude),
                    distance: min(distance, MapCameraConstraints.maximumDistance(at: latitude)))
    }

    /// Pan keeps the geographic direction, while scale narrows continuously
    /// inside the polar envelope. Clipping latitude at a fixed zoom would make
    /// the whole-globe view unable to rotate north/south at all.
    func mapPanConstrained() -> Self {
        mapConstrained()
    }

    func isApproximatelyEqual(to other: Self) -> Bool {
        abs(center.latitude - other.center.latitude) < 0.000_001
            && abs(Self.normalizedLongitude(center.longitude - other.center.longitude)) < 0.000_001
            && abs(distance - other.distance) < max(0.1, distance * 0.000_000_1)
    }
}

/// Readback is stored without publishing SwiftUI state from updateUIView.
/// Only the matching submitted generation may influence the next motion frame.
@MainActor
final class NativeGlobeCameraFeedback {
    var renderedSatelliteCamera: GlobeCameraState?
    private(set) var requested: GlobeCameraState?
    private(set) var actual: GlobeCameraState?
    private var limitedCenter: GeoCoordinate?
    private var maximumDistance: Double?
    private var minimumDistance: Double?

    func record(requested: GlobeCameraState, actual: GlobeCameraState) {
        self.requested = requested
        self.actual = actual.isApproximatelyEqual(to: requested) ? requested : actual
        if let limitedCenter, !sameCenter(limitedCenter, actual.center) {
            self.limitedCenter = nil
            maximumDistance = nil
            minimumDistance = nil
        }
        guard sameCenter(requested.center, actual.center) else { return }
        if actual.distance < requested.distance * 0.999 {
            limitedCenter = actual.center
            maximumDistance = actual.distance
        } else if actual.distance > requested.distance * 1.001 {
            limitedCenter = actual.center
            minimumDistance = actual.distance
        }
    }

    func resolved(_ camera: GlobeCameraState) -> GlobeCameraState {
        guard requested == camera, let actual else { return camera }
        return actual
    }

    func constrained(_ camera: GlobeCameraState) -> GlobeCameraState {
        var result = camera.mapConstrained()
        if let limitedCenter, sameCenter(limitedCenter, result.center) {
            if let maximumDistance { result.distance = min(result.distance, maximumDistance) }
            if let minimumDistance { result.distance = max(result.distance, minimumDistance) }
        }
        return result
    }

    func reset() {
        renderedSatelliteCamera = nil
        requested = nil
        actual = nil
        limitedCenter = nil
        maximumDistance = nil
        minimumDistance = nil
    }

    private func sameCenter(_ first: GeoCoordinate, _ second: GeoCoordinate) -> Bool {
        abs(first.latitude - second.latitude) < 0.000_01
            && abs(GlobeCameraState.normalizedLongitude(first.longitude - second.longitude)) < 0.000_01
    }
}
