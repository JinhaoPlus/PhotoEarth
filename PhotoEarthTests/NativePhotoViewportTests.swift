import Foundation
import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct NativePhotoViewportTests {
    @Test @MainActor
    func nativeProjectionRejectsVisibleHemispherePhotosOutsideTheScreenRectangle() async throws {
        let map = makeMap()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(MapViewportSampler.photoSnapshot(in: map))
        let center = coordinate(at: CGPoint(x: 960, y: 540), in: map)
        // Full-bleed map content extends beyond the legal ornament margins.
        let inside = coordinate(at: CGPoint(x: 24, y: 540), in: map)
        let outside = coordinate(at: CGPoint(x: 960, y: -120), in: map)
        let behind = GeoCoordinate(latitude: -center.latitude,
                                   longitude: GlobeCameraState.normalizedLongitude(center.longitude + 180))

        #expect(snapshot.viewport.contains(outside), "This fixture must pass the old conservative circle filter")
        #expect(snapshot.viewport.visibilityCap?.contains(outside) == true,
                "The excluded photo is on the front surface, rather than behind the globe")
        let outsideProjection = map.convert(
            CLLocationCoordinate2D(latitude: outside.latitude, longitude: outside.longitude), toPointTo: map
        )
        #expect(outsideProjection.x.isFinite && outsideProjection.y.isFinite)
        #expect(!map.bounds.contains(outsideProjection))

        let records = [
            photo("outside", at: outside),
            photo("behind", at: behind),
            photo("invalid", at: GeoCoordinate(latitude: .nan, longitude: 0)),
            photo("center", at: center),
            photo("inside", at: inside),
        ]
        let visible = try #require(snapshot.visibleCandidates(from: records))
        #expect(visible.map(\.id) == ["center", "inside"])
        #expect(!snapshot.containsCoordinate(outside))
        #expect(!snapshot.containsCoordinate(behind))
    }

    @Test(arguments: [false, true]) @MainActor
    func aNativeProjectionChangePermanentlyExpiresTheSnapshot(changeCamera: Bool) async throws {
        let map = makeMap()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(MapViewportSampler.photoSnapshot(in: map))
        let originalCamera = map.camera
        let originalBounds = map.bounds
        let record = photo("center", at: snapshot.viewport.center)
        #expect(snapshot.isCurrent())

        if changeCamera {
            map.setCamera(MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 22),
                fromDistance: GlobeCameraState.regionalDistance, pitch: 0, heading: 0
            ), animated: false)
        } else {
            map.bounds = CGRect(x: 0, y: 0, width: 1_600, height: 1_080)
        }
        #expect(!snapshot.isCurrent())
        #expect(snapshot.visibleCandidates(from: [record]) == nil)

        // Returning to the same apparent state must not resurrect work which
        // has already been rejected by this snapshot's generation.
        if changeCamera { map.setCamera(originalCamera, animated: false) }
        else { map.bounds = originalBounds }
        #expect(!snapshot.isCurrent())
    }

    @Test @MainActor
    func aNewContactInvalidatesTheCoordinatorSnapshotBeforeAnyCameraMovement() async throws {
        let map = makeMap()
        var delivered: PhotoViewportSnapshot?
        let coordinator = MapKitEarthView.Coordinator(
            onViewportSettled: { delivered = $0 }, onUserLocationUpdate: { _ in }
        )
        defer { coordinator.cancelPendingSnapshot() }
        let camera = GlobeCameraState(
            center: GeoCoordinate(latitude: 0, longitude: 20), distance: GlobeCameraState.regionalDistance
        )
        coordinator.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: camera, isManipulating: false, showsUserLocation: false, settleRevision: 0,
            onViewportSettled: { delivered = $0 }, onUserLocationUpdate: { _ in }
        )
        try await Task.sleep(for: .milliseconds(180))
        let snapshot = try #require(delivered)
        #expect(snapshot.isCurrent())

        coordinator.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: camera, isManipulating: true, showsUserLocation: false, settleRevision: 0,
            onViewportSettled: { _ in }, onUserLocationUpdate: { _ in }
        )
        #expect(!snapshot.isCurrent())
        #expect(snapshot.visibleCandidates(from: [photo("center", at: camera.center)]) == nil)
        coordinator.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: camera, isManipulating: false, showsUserLocation: false, settleRevision: 0,
            onViewportSettled: { _ in }, onUserLocationUpdate: { _ in }
        )
        #expect(!snapshot.isCurrent())
    }

    @Test @MainActor
    func theSnapshotDoesNotKeepItsCoordinatorAlive() async throws {
        let map = makeMap()
        var delivered: PhotoViewportSnapshot?
        var coordinator: MapKitEarthView.Coordinator? = MapKitEarthView.Coordinator(
            onViewportSettled: { delivered = $0 }, onUserLocationUpdate: { _ in }
        )
        weak var weakCoordinator = coordinator
        coordinator?.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 20),
                                     distance: GlobeCameraState.regionalDistance),
            isManipulating: false, showsUserLocation: false, settleRevision: 0,
            onViewportSettled: { delivered = $0 }, onUserLocationUpdate: { _ in }
        )
        try await Task.sleep(for: .milliseconds(180))
        let snapshot = try #require(delivered)
        #expect(snapshot.isCurrent())
        coordinator = nil
        #expect(weakCoordinator == nil)
        #expect(!snapshot.isCurrent())
    }

    @MainActor private func makeMap() -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        map.setCamera(MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 20),
            fromDistance: GlobeCameraState.regionalDistance, pitch: 0, heading: 0
        ), animated: false)
        map.layoutIfNeeded()
        return map
    }

    @MainActor private func coordinate(at point: CGPoint, in map: MKMapView) -> GeoCoordinate {
        let coordinate = map.convert(point, toCoordinateFrom: map)
        return GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func photo(_ id: String, at coordinate: GeoCoordinate) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: id, coordinate: coordinate, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 4_000, pixelHeight: 3_000, isFavorite: false
        )
    }
}
