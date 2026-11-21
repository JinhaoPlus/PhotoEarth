import Combine
import Foundation
import Testing
@testable import PhotoEarth

struct CityNavigationTests {
    @Test(arguments: [false, true]) @MainActor
    func toolbarZoomRunsWhileDirectManipulationIsPausedAndPublishesOnlyAtFrames(reduceMotion: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: GeoCoordinate(latitude: 25, longitude: 18),
                               distance: 12_000_000, animated: false, overviewFraming: 0)
        model.activate(initialCenter: nil) { _, _ in [] }
        model.pauseDirectManipulation()
        let initial = model.camera
        var publications = 0
        let observation = model.$camera.dropFirst().sink { _ in publications += 1 }

        model.zoomIn()
        #expect(publications == 0)
        // The tool owns input. A delayed direct-input sample cannot move its anchor.
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0.1)
        for frame in 1...12 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
            #expect(publications <= frame)
            #expect(model.camera.center == initial.center)
        }
        #expect(publications > 0)
        #expect(abs(model.camera.distance - initial.distance * exp(-0.34)) < 0.001)
        let settled = model.camera
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion) }
        #expect(model.camera == settled)
        observation.cancel()
    }

    @Test @MainActor func repeatedZoomPreservesVelocityAndReverseTakesOverOnItsFirstFrame() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: GeoCoordinate(latitude: 25, longitude: 18),
                               distance: 12_000_000, animated: false, overviewFraming: 0)
        model.zoomIn()
        model.advanceMotionFrame(elapsed: 0.16 - 0.000_1, reduceMotion: false)
        let before = log(model.camera.distance)
        model.advanceMotionFrame(elapsed: 0.000_1, reduceMotion: false)
        let retargetPoint = model.camera
        let incomingVelocity = (log(retargetPoint.distance) - before) / 0.000_1
        model.zoomIn()
        #expect(model.camera == retargetPoint)
        model.advanceMotionFrame(elapsed: 0.000_1, reduceMotion: false)
        let outgoingVelocity = (log(model.camera.distance) - log(retargetPoint.distance)) / 0.000_1
        #expect(abs(outgoingVelocity - incomingVelocity) < 0.005)

        let beforeReversal = model.camera
        model.zoomOut()
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera.distance > beforeReversal.distance)
        #expect(model.camera.center == beforeReversal.center)
        let reverseDestination = beforeReversal.distance * exp(0.34)
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(abs(model.camera.distance - reverseDestination) < 0.001)
    }

    @Test(arguments: [0.0, 35.68, 64.15, -33.87])
    @MainActor func toolbarZoomReachesRegionalBoundaryWithoutMovingTheCenter(latitude: Double) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let center = GeoCoordinate(latitude: latitude, longitude: 139.76)
        let initialDistance = GlobeCameraState.minimumDistance * 4
        model.transitionCamera(to: center, distance: initialDistance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == initialDistance && initialDistance > GlobeCameraState.minimumDistance)
        for _ in 0..<6 {
            model.zoomIn()
            for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        }
        #expect(model.camera.center == center)
        #expect(model.camera.distance == GlobeCameraState.minimumDistance)
        #expect(model.zoomBoundary == .regional)
        #expect(model.zoomDirection == 0)
        model.zoomOut()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == center)
        #expect(model.camera.distance > GlobeCameraState.minimumDistance)
        #expect(model.zoomBoundary == nil)
    }

    @Test @MainActor func toolbarZoomIsCenteredAndRepeatable() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let center = GeoCoordinate(latitude: 35.68, longitude: 139.76)
        let initialDistance = GlobeCameraState.minimumDistance * 8
        model.transitionCamera(to: center, distance: initialDistance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == initialDistance)
        #expect(initialDistance * exp(-0.68) > GlobeCameraState.minimumDistance)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(abs(model.camera.distance - initialDistance * exp(-0.34)) < 0.001)
        #expect(model.camera.center == center)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(abs(model.camera.distance - initialDistance * exp(-0.68)) < 0.001)
        #expect(model.camera.center == center)
    }

    @Test @MainActor func toolbarZoomInterruptsTravelAtTheCurrentlyDisplayedCenter() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: GeoCoordinate(latitude: -33.87, longitude: 151.21),
                               distance: GlobeCameraState.minimumDistance, overviewFraming: 0)
        model.advanceMotionFrame(elapsed: 0.3, reduceMotion: false)
        let displayed = model.camera
        #expect(displayed.distance * exp(-0.34) > GlobeCameraState.minimumDistance)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == displayed.center)
        #expect(abs(model.camera.distance - displayed.distance * exp(-0.34)) < 0.001)
    }

    @Test @MainActor func quickHorizontalSwipeKeepsItsAccumulatedTravel() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: GeoCoordinate(latitude: 0, longitude: 0),
                               distance: GlobeCameraState.defaultDistance, animated: false)
        model.activate(initialCenter: nil) { _, _ in [] }
        let expectedTravel = 21 * model.camera.navigationScale
        // Multiple callbacks within one display frame must retain ordinary swipe travel.
        model.applyTouchPan(horizontalDelta: 0.09, verticalDelta: 0)
        model.applyTouchPan(horizontalDelta: 0.08, verticalDelta: 0)
        model.applyTouchPan(horizontalDelta: 0.08, verticalDelta: 0)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(abs(model.camera.center.longitude + expectedTravel) < 0.001)
    }

    @Test func regionalDragKeepsLatitudeCompensationAndScalesDownFromOrbit() {
        func distance(at latitude: Double, cameraDistance: Double) -> Double {
            var camera = GlobeCameraState(
                center: GeoCoordinate(latitude: latitude, longitude: 10), distance: cameraDistance
            )
            #expect(camera.distance == cameraDistance, "Drag coverage must use a reachable camera distance")
            let origin = camera.center
            camera.panWithTouchSurface(horizontalDelta: 0.025, verticalDelta: 0,
                                       sensitivity: 84 * camera.navigationScale)
            #expect(camera.center.longitude < origin.longitude)
            #expect(camera.center.latitude == origin.latitude)
            return GlobeMath.distanceKilometers(from: origin, to: camera.center)
        }
        let regional = GlobeCameraState.minimumDistance
        let equatorial = distance(at: 0, cameraDistance: regional)
        #expect(equatorial > 0)
        #expect(equatorial < distance(at: 0, cameraDistance: GlobeCameraState.orbitalDistance))
        for latitude in [64.0, -34.0] {
            let relativeTravel = distance(at: latitude, cameraDistance: regional) / equatorial
            // Regional framing blends globe rotation and surface dragging. Its
            // latitude compensation must improve the uncorrected longitude scale
            // without making a high-latitude swipe faster than an equatorial one.
            #expect(relativeTravel > cos(latitude * .pi / 180))
            #expect(relativeTravel <= 1)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func blockedZoomLeavesCameraAndRefreshRevisionsStableThenReversesImmediately(atGlobalBoundary: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let distance = atGlobalBoundary ? model.camera.maximumMapDistance : GlobeCameraState.minimumDistance
        let direction = atGlobalBoundary ? 1.0 : -1.0
        model.transitionCamera(to: model.camera.center, distance: distance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == distance)
        let camera = model.camera
        let transitionRevision = model.cameraTransitionRevision
        let settleRevision = model.settleRevision

        for _ in 0..<100 {
            if atGlobalBoundary { model.zoomOut() } else { model.zoomIn() }
        }
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera == camera)
        #expect(model.cameraTransitionRevision == transitionRevision)
        #expect(model.settleRevision == settleRevision)
        #expect(!model.isManipulating)
        #expect(model.zoomDirection == 0)
        #expect(model.zoomBoundary == (atGlobalBoundary ? .global : .regional))

        if atGlobalBoundary { model.zoomIn() } else { model.zoomOut() }
        #expect(model.zoomBoundary == nil)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect((model.camera.distance - distance) * direction < 0)
        #expect(model.camera.center == camera.center)
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(abs(model.camera.distance - distance * exp(-direction * 0.34)) < 0.001)
        let reversedCamera = model.camera
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera == reversedCamera, "Blocked button presses must never replay after reversal")
    }

    @Test(arguments: [false, true]) @MainActor
    func centeredZoomReportsTheRegionalBoundaryWhenItsFlightFinishes(reduceMotion: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let initialDistance = GlobeCameraState.minimumDistance * 1.2
        model.transitionCamera(to: model.camera.center, distance: initialDistance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == initialDistance)
        let center = model.camera.center
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion) }
        #expect(model.camera.distance == GlobeCameraState.minimumDistance)
        #expect(model.camera.center == center)
        #expect(model.zoomBoundary == .regional)
        #expect(model.zoomDirection == 0)
        #expect(!model.isManipulating)
    }

    @Test @MainActor func zoomOutReversesAnApproachFromTheCurrentlyDisplayedDistance() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let initialDistance = GlobeCameraState.minimumDistance * 2
        model.transitionCamera(to: model.camera.center, distance: initialDistance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == initialDistance)
        model.zoomIn()
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        let displayed = model.camera
        #expect(displayed.distance > GlobeCameraState.minimumDistance && displayed.distance < initialDistance)
        model.zoomOut()
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera.distance > displayed.distance, "Reverse zoom must move out on its first frame")
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.distance > displayed.distance)
        #expect(model.camera.center == displayed.center)
        #expect(model.zoomBoundary == nil)
    }

    @Test @MainActor func presentationContinuesSmoothlyWhenInputInterruptsTheCameraFlight() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: model.camera.center, distance: 26_000_000,
                               animated: false, overviewFraming: 1)
        model.activate(initialCenter: nil) { _, _ in [] }
        model.transitionCamera(to: model.camera.center, distance: 23_500_000, overviewFraming: 0)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.overviewFraming > 0.98 && model.overviewFraming < 1)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        var previous = model.overviewFraming
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            #expect(model.overviewFraming <= previous)
            #expect(previous - model.overviewFraming < 0.07)
            previous = model.overviewFraming
        }
        #expect(model.overviewFraming == 0)
    }

    @Test @MainActor func interruptedPresentationStaysFrozenInWallAndResumesCentered() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.transitionCamera(to: model.camera.center, distance: 23_500_000, overviewFraming: 0)
        model.advanceMotionFrame(elapsed: 0.3, reduceMotion: false)
        model.pauseDirectManipulation()
        let frozenCamera = model.camera
        let frozenFraming = model.overviewFraming
        model.advanceMotionFrame(elapsed: 0.5, reduceMotion: false)
        #expect(model.camera == frozenCamera)
        #expect(model.overviewFraming == frozenFraming)
        model.setSceneActive(false)
        model.setSceneActive(true)
        model.advanceMotionFrame(elapsed: 0.5, reduceMotion: false)
        #expect(model.camera == frozenCamera)
        #expect(model.overviewFraming == frozenFraming)
        model.resumeDirectManipulation()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.overviewFraming == 0)
        #expect(model.camera == frozenCamera)
    }

    @Test func smallViewportRefreshToleranceTracksRelativeChanges() {
        // Pure spatial-query precision remains useful independently of the
        // product's larger regional camera boundary.
        let center = GeoCoordinate(latitude: 35.68, longitude: 139.76)
        let previous = EarthViewport(center: center, angularRadius: 0.01)
        #expect(previous.angularRadius == 0.01)
        #expect(!EarthViewport(center: center, angularRadius: 0.01001).differsMeaningfully(from: previous))
        #expect(EarthViewport(center: center, angularRadius: 0.005).differsMeaningfully(from: previous))
        #expect(EarthViewport(center: GeoCoordinate(latitude: 35.682, longitude: 139.76),
                              angularRadius: 0.01).differsMeaningfully(from: previous))
    }

    @Test func smallPolarBoundsContainTheEntireSphericalCap() {
        let viewport = EarthViewport(center: GeoCoordinate(latitude: 83, longitude: 179.99), angularRadius: 0.01)
        let bounds = PhotoSpatialBounds(viewport: viewport)
        #expect(bounds.longitudeRanges.count == 2)
        #expect(bounds.longitudeRanges.contains { $0.contains(-179.94) })
        #expect(bounds.maximumLatitude - bounds.minimumLatitude < 0.021)
    }

    @Test func smallSpatialQueriesExcludePhotosOutsideTheSphericalCap() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 35.68, longitude: 139.76)
        let photos = (0..<30).map { index in
            PhotoAssetRecord(id: "city-test-\(index)",
                             coordinate: GeoCoordinate(latitude: center.latitude + Double(index) * 0.002,
                                                       longitude: center.longitude),
                             creationDate: Date(timeIntervalSince1970: Double(index) * 60),
                             pixelWidth: 4_000, pixelHeight: 3_000, isFavorite: false)
        }
        try await store.save(TravelClusterer().makeIndex(records: photos))
        let viewport = EarthViewport(center: center, angularRadius: 0.005)
        let representatives = try await store.photos(in: viewport, limit: 18)
        let page = try await store.photoPage(in: viewport, offset: 0, limit: 48)
        let expected = Set(["city-test-0", "city-test-1", "city-test-2"])
        #expect(Set(representatives.map(\.id)) == expected)
        #expect(Set(page.records.map(\.id)) == expected)
        #expect(page.nextOffset == nil)
        let fixture = PhotoSpatialIndex(records: photos)
        #expect(Set(fixture.photos(in: viewport).map(\.id)) == expected)
    }
}
