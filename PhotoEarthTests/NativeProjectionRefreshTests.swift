import Foundation
import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct NativeProjectionRefreshTests {
    @Test(arguments: ["camera", "bounds", "pitch"]) @MainActor
    func readyPhotosExpireOnceWhenOnlyTheNativeProjectionChanges(change: String) async throws {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.apply()
        try await waitUntil { fixture.model.photoBatchReady }
        #expect(fixture.state.queries == 1)
        #expect(fixture.state.snapshots == 1)
        let originalRevision = fixture.model.settleRevision

        // Unchanged native callbacks must not restart either snapshot delivery
        // or the one 850 ms query debounce after the batch is already ready.
        fixture.sendNativeCallbacks()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.state.invalidations == 0)
        #expect(fixture.model.photoBatchReady)
        #expect(fixture.state.queries == 1)

        switch change {
        case "bounds":
            fixture.map.bounds = CGRect(x: 0, y: 0, width: 1_600, height: 1_080)
            // updateUIView can observe new native bounds before a region event.
            fixture.apply()
        case "pitch":
            let camera = fixture.map.camera.copy() as! MKMapCamera
            camera.pitch = 0
            fixture.map.setCamera(camera, animated: false)
        default:
            fixture.map.setCamera(MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 40),
                fromDistance: 2_000_000, pitch: 0, heading: 0
            ), animated: false)
        }
        fixture.sendNativeCallbacks()
        #expect(fixture.model.photoBatchReady,
                "A delegate called inside updateUIView must not publish model state synchronously")

        try await waitUntil { !fixture.model.photoBatchReady }
        #expect(fixture.model.visiblePhotos.isEmpty)
        #expect(fixture.state.invalidations == 1)
        #expect(fixture.model.settleRevision == originalRevision + 1)
        #expect(fixture.state.queries == 1)
        #expect(fixture.state.snapshots == 1)

        // Simulate the SwiftUI update caused by the new settle revision. It
        // delivers one fresh native snapshot, using the normal debounce path.
        fixture.apply()
        try await waitUntil { fixture.model.photoBatchReady }
        #expect(fixture.state.snapshots == 2)
        #expect(fixture.state.queries <= 2, "Nearby bounds/pitch changes may reuse private candidates")
        if change == "camera" { #expect(fixture.state.queries == 2) }
        let queryCount = fixture.state.queries
        fixture.sendNativeCallbacks()
        fixture.apply()
        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.state.invalidations == 1)
        #expect(fixture.state.snapshots == 2)
        #expect(fixture.state.queries == queryCount)
        #expect(fixture.model.settleRevision == originalRevision + 1)
        #expect(fixture.model.photoBatchReady)

        fixture.model.invalidateNativeProjection(settleRevision: originalRevision)
        #expect(fixture.model.photoBatchReady, "A delayed receipt cannot invalidate a newer ready batch")
    }

    @Test @MainActor
    func aNewInputPreemptsQueuedNativeInvalidationAndRefreshesOnlyAfterSettling() async throws {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.apply()
        try await waitUntil { fixture.model.photoBatchReady }
        let originalRevision = fixture.model.settleRevision
        let nativeCamera = fixture.map.camera.copy() as! MKMapCamera
        nativeCamera.pitch = 0
        fixture.map.setCamera(nativeCamera, animated: false)
        fixture.sendNativeCallbacks()

        // Before the queued callback publishes anything, direct manipulation
        // takes ownership. Its own invalidation/settle sequence wins.
        fixture.model.receiveTouchContact(true)
        fixture.model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        fixture.apply()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.state.invalidations == 0)
        #expect(!fixture.model.photoBatchReady)
        #expect(fixture.model.settleRevision == originalRevision)
        #expect(fixture.state.queries == 1)
        #expect(fixture.state.snapshots == 1)

        fixture.model.receiveTouchContact(false)
        try await Task.sleep(for: .milliseconds(160))
        fixture.model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        fixture.apply()
        try await waitUntil { fixture.model.photoBatchReady }
        #expect(fixture.state.invalidations == 0)
        #expect(fixture.model.settleRevision == originalRevision + 1)
        #expect(fixture.state.snapshots == 2)
        #expect(fixture.state.queries <= 2)
    }

    @MainActor private func makeFixture() -> ProjectionRefreshFixture {
        let state = ProjectionRefreshState()
        let model = GlobeExperienceModel()
        let center = GeoCoordinate(latitude: 0, longitude: 20)
        model.activate(initialCenter: nil) { _, _ in
            state.queries += 1
            return [PhotoAssetRecord(
                id: "synthetic-ready-photo", coordinate: center,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                pixelWidth: 1_200, pixelHeight: 800, isFavorite: false
            )]
        }
        model.transitionCamera(to: center, distance: 2_000_000, animated: false)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        let coordinator = MapKitEarthView.Coordinator(
            onViewportSettled: { snapshot in
                state.snapshots += 1
                model.receiveViewport(snapshot)
            },
            onUserLocationUpdate: { _ in },
            onViewportInvalidated: { revision in
                state.invalidations += 1
                model.invalidateNativeProjection(settleRevision: revision)
            }
        )
        map.delegate = coordinator
        return ProjectionRefreshFixture(model: model, map: map, coordinator: coordinator, state: state)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Native projection refresh did not finish within its bounded snapshot/debounce window")
    }
}

@MainActor private final class ProjectionRefreshState {
    var queries = 0
    var snapshots = 0
    var invalidations = 0
}

@MainActor private struct ProjectionRefreshFixture {
    let model: GlobeExperienceModel
    let map: MKMapView
    let coordinator: MapKitEarthView.Coordinator
    let state: ProjectionRefreshState

    func apply() {
        coordinator.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: model.camera, isManipulating: model.isManipulating,
            showsUserLocation: false, settleRevision: model.settleRevision,
            nativeCameraFeedback: model.nativeCameraFeedback,
            onViewportSettled: { snapshot in
                state.snapshots += 1
                model.receiveViewport(snapshot)
            },
            onUserLocationUpdate: { _ in },
            onViewportInvalidated: { revision in
                state.invalidations += 1
                model.invalidateNativeProjection(settleRevision: revision)
            }
        )
        map.layoutIfNeeded()
    }

    func sendNativeCallbacks() {
        for _ in 0..<5 {
            coordinator.mapViewDidChangeVisibleRegion(map)
            coordinator.mapView(map, regionDidChangeAnimated: false)
            coordinator.mapViewDidFinishRenderingMap(map, fullyRendered: true)
        }
    }

    func close() {
        map.delegate = nil
        coordinator.cancelPendingSnapshot()
        model.deactivate()
    }
}
