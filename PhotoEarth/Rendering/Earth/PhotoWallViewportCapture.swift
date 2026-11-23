import MapKit

/// The wall freezes the actual MKMapView at Select, independently of the
/// debounced filmstrip snapshot and any unsubmitted application camera state.
@MainActor
final class PhotoWallViewportCapture {
    struct Capture {
        let snapshot: PhotoViewportSnapshot
        let camera: GlobeCameraState
    }

    private weak var mapView: MKMapView?
    private weak var cityStreets: CityStreetMapTransition?
    private var generation = UUID()
    private(set) var isFrozen = false

    func attach(_ mapView: MKMapView, cityStreets: CityStreetMapTransition? = nil) {
        self.cityStreets = cityStreets
        guard self.mapView !== mapView else { return }
        release()
        self.mapView = mapView
    }

    func grid(for viewport: EarthViewport) throws -> MapReviewGrid {
        guard let mapView, !mapView.bounds.isEmpty else { throw PhotoWallSelectionError.unavailableViewport }
        return MapReviewGrid(viewport: viewport, size: mapView.bounds.size)
    }

    func freeze() -> Capture? {
        guard let mapView = cityStreets?.visibleMap ?? mapView else { return nil }
        generation = UUID()
        let generation = generation
        isFrozen = true
        guard let snapshot = MapViewportSampler.photoSnapshot(in: mapView, isCurrent: { [weak self] in
            self?.isFrozen == true && self?.generation == generation
        }) else { release(); return nil }
        cityStreets?.freeze()
        let native = mapView.camera
        return Capture(snapshot: snapshot, camera: GlobeCameraState(
            center: GeoCoordinate(latitude: native.centerCoordinate.latitude, longitude: native.centerCoordinate.longitude),
            distance: native.centerCoordinateDistance
        ))
    }

    func release() {
        isFrozen = false
        generation = UUID()
    }
}
