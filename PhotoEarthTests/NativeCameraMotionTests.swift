import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct NativeCameraMotionTests {
    @Test func presentationEnvelopeIsContinuousAndPreservesDestinations() {
        var previousMaximum = MapCameraConstraints.maximumDistance(at: 0)
        for step in 1...830 {
            let latitude = Double(step) / 10
            let maximum = MapCameraConstraints.maximumDistance(at: latitude)
            #expect(maximum <= previousMaximum)
            #expect(previousMaximum - maximum < 40_001)
            let target = GlobeCameraState(center: .init(latitude: latitude, longitude: 20),
                                          distance: GlobeCameraState.maximumDistance).mapConstrained()
            #expect(target.center.latitude == latitude)
            #expect(target.distance == maximum)
            #expect(target.distance >= GlobeCameraState.minimumDistance)
            previousMaximum = maximum
        }
    }

    @Test @MainActor func nativeReadbackIsTheNextZoomOriginAndStaleReceiptIsIgnored() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 20, longitude: 20), distance: 8_000_000, animated: false)
        let requested = model.camera
        let native = GlobeCameraState(center: requested.center, distance: 6_000_000)
        model.nativeCameraFeedback.record(requested: requested, actual: native)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(abs(model.camera.distance - 6_000_000 * exp(-0.34)) < 0.001)
        #expect(model.camera.center == native.center)
        // This receipt belongs to the old eight-megametre submission.
        model.nativeCameraFeedback.record(requested: requested, actual: native)
        #expect(model.displayedCamera == model.camera)
    }

    @Test @MainActor func nativeLimitStopsOutwardRequestsAndReverseImmediatelyMoves() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 0, longitude: 20), distance: 8_000_000, animated: false)
        let requested = model.camera
        let actual = GlobeCameraState(center: requested.center, distance: 6_000_000)
        model.nativeCameraFeedback.record(requested: requested, actual: actual)
        model.zoomOut()
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == actual)
        model.zoomIn()
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera.distance < actual.distance)
        #expect(model.camera.center == actual.center)
    }

    @Test @MainActor func pendingPanIsRebasedOnceIfNativeReadbackArrivesBeforeTheFrame() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 20, longitude: 20), distance: 8_000_000, animated: false)
        model.activate(initialCenter: nil) { _, _ in [] }
        let requested = model.camera
        model.applyTouchPan(horizontalDelta: 0.05, verticalDelta: 0)
        var expectedPan = requested
        expectedPan.panWithTouchSurface(horizontalDelta: 0.05, verticalDelta: 0,
                                       sensitivity: 84 * requested.navigationScale)
        let actual = GlobeCameraState(center: requested.center, distance: 6_000_000)
        model.nativeCameraFeedback.record(requested: requested, actual: actual)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(abs(model.camera.distance - actual.distance) < 0.001)
        #expect(abs(model.camera.center.longitude - expectedPan.center.longitude) < 0.00001)
        let settled = model.camera
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == settled)
    }

    @Test @MainActor func delayedNativeReadbackDoesNotApplyThePolarPanEnvelopeTwice() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 70, longitude: 20), distance: 6_000_000, animated: false)
        model.activate(initialCenter: nil) { _, _ in [] }
        let requested = model.camera
        model.applyTouchPan(horizontalDelta: 0, verticalDelta: -5 / (36.48 * requested.navigationScale))
        model.nativeCameraFeedback.record(requested: requested,
                                          actual: GlobeCameraState(center: requested.center, distance: 5_000_000))
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(abs(model.camera.center.latitude - 75) < 0.00001)
        #expect(abs(model.camera.distance - 4_000_000) < 0.001)
    }

    @Test @MainActor func runtimeZoomLimitEndsTheFlightWithoutAnEmptyAnimation() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 0, longitude: 20), distance: 6_000_000, animated: false)
        model.zoomOut()
        model.advanceMotionFrame(elapsed: 0.16, reduceMotion: false)
        let requested = model.camera
        let actual = GlobeCameraState(center: requested.center, distance: 6_000_000)
        model.nativeCameraFeedback.record(requested: requested, actual: actual)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == actual)
        #expect(!model.isManipulating)
        #expect(model.zoomDirection == 0)
        #expect(model.zoomBoundary == .global)
    }

    @Test(arguments: [0.0, 30.0, 45.0, 50.0]) @MainActor
    func nativeFarZoomAcceptsTheWholeContinuousPitchTransition(latitude: Double) async throws {
        let map = makeMap()
        try await Task.sleep(for: .milliseconds(30))
        for step in 0...15 {
            let normalizedDistance = 14_000_000 + Double(step) * 400_000
            let camera = GlobeCameraState(center: .init(latitude: latitude, longitude: 20),
                                          distance: normalizedDistance * cos(latitude * .pi / 180)).mapConstrained()
            map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: latitude, longitude: 20),
                                     fromDistance: camera.distance, pitch: camera.presentationPitch, heading: 0), animated: false)
            map.layoutIfNeeded()
            #expect(abs(map.camera.pitch - camera.presentationPitch) < 0.01)
        }
    }

    @Test(arguments: [-1.0, 1.0]) @MainActor
    func nativePolarDragKeepsItsDirectionAndImmediatelyReverses(sign: Double) async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: 68 * sign, longitude: 20),
                               distance: GlobeCameraState.orbitalDistance, animated: false)
        model.activate(initialCenter: nil) { _, _ in [] }
        let map = makeMap()
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        apply(model, to: map, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(30))
        var previousLatitude = map.camera.centerCoordinate.latitude
        for _ in 0..<40 {
            model.applyTouchPan(horizontalDelta: 0, verticalDelta: -0.12 * sign)
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            apply(model, to: map, coordinator: coordinator)
            let actual = map.camera
            #expect((actual.centerCoordinate.latitude - previousLatitude) * sign >= -0.00001)
            #expect(abs(actual.centerCoordinate.latitude - model.camera.center.latitude) < 0.00001)
            #expect(abs(actual.centerCoordinateDistance / model.camera.distance - 1) < 0.001)
            previousLatitude = actual.centerCoordinate.latitude
        }
        model.applyTouchPan(horizontalDelta: 0, verticalDelta: 0.12 * sign)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        apply(model, to: map, coordinator: coordinator)
        #expect((map.camera.centerCoordinate.latitude - previousLatitude) * sign < 0)
        coordinator.cancelPendingSnapshot()
    }

    @Test(arguments: [0.0, 64.15, 80.0]) @MainActor
    func eachToolbarZoomActuallyMovesTheNativeCameraAtItsFarthestView(latitude: Double) async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: .init(latitude: latitude, longitude: 20),
                               distance: GlobeCameraState.maximumDistance, animated: false)
        let map = makeMap()
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        apply(model, to: map, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(30))
        let initial = map.camera.centerCoordinateDistance
        model.zoomIn()
        for _ in 0..<12 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            apply(model, to: map, coordinator: coordinator)
        }
        #expect(map.camera.centerCoordinateDistance < initial * 0.9)
        #expect(abs(map.camera.centerCoordinate.latitude - latitude) < 0.00001)
        #expect(abs(map.camera.centerCoordinateDistance - max(initial * exp(-0.34), GlobeCameraState.minimumDistance)) < 1)
        coordinator.cancelPendingSnapshot()
    }

    @MainActor private func makeMap() -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        return map
    }

    @MainActor private func apply(_ model: GlobeExperienceModel, to map: MKMapView,
                                  coordinator: MapKitEarthView.Coordinator) {
        coordinator.update(map, places: [], horizontalPresentationOffset: 0,
                           contentRevision: 0, camera: model.camera, isManipulating: true,
                           showsUserLocation: false, settleRevision: 0,
                           nativeCameraFeedback: model.nativeCameraFeedback,
                           onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        map.layoutIfNeeded()
    }
}
