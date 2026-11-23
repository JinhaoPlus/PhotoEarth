import MapKit
import Testing
@testable import PhotoEarth

@MainActor struct GlobeScalePresentationTests {
    @Test func focusedCityWarmsBoundedSatelliteViewsAndLandingPreemptsObsoleteWork() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var callbacks: [@MainActor () -> Void] = []
        let handoff = MapStyleHandoff { _, finish in callbacks.append(finish) }
        defer { handoff.cancel() }
        let origin = GlobeCameraState(center: .init(latitude: 64, longitude: -22), distance: GlobeCameraState.orbitalDistance)
        let tokyo = GlobeCameraState(center: .init(latitude: 35, longitude: 140), distance: GlobeCameraState.regionalDistance)
        let other = GlobeCameraState(center: .init(latitude: -33, longitude: 151), distance: GlobeCameraState.regionalDistance)
        handoff.warmSatellite(to: tokyo, from: origin, in: map)
        handoff.warmSatellite(to: tokyo, from: origin, in: map)
        #expect(callbacks.count == 1)
        try #require(callbacks.count > 0)
        callbacks[0]()
        try #require(callbacks.count > 1)
        callbacks[1]()
        try #require(callbacks.count > 2)
        callbacks[2]()
        #expect(callbacks.count == 3)

        handoff.warmCity(tokyo, from: origin, in: map)
        #expect(callbacks.count == 4)
        var installed = false
        handoff.prepare(.init(map: .standard, flat: true), at: tokyo, in: map) { installed = true }
        handoff.warmCity(other, from: origin, in: map)
        try #require(callbacks.count > 3)
        callbacks[3]()
        #expect(!installed)
        handoff.prepare(.init(map: .standard, flat: true), at: other, in: map) { installed = true }
        try #require(callbacks.count > 4)
        callbacks[4]()
        #expect(!installed)
        try #require(callbacks.count > 5)
        callbacks[5]()
        #expect(installed)
        #expect(callbacks.count == 6)
    }

    @Test func streetRendererFollowsFlightAndWallKeepsItsVisibleProjection() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let resident = MKMapView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        host.view.addSubview(resident)
        window.isHidden = false
        let handoff = CityStreetMapTransition()
        defer { handoff.cancel(); window.isHidden = true }
        let city = GeoCoordinate(latitude: 64, longitude: -22)
        let regional = GlobeCameraState(center: city, distance: GlobeCameraState.regionalDistance)
        let landing = GlobeCameraState(center: city, distance: GlobeCameraState.cityFallbackDistance)
        var installs = 0
        handoff.prepare(regional, in: resident)
        handoff.blend(at: regional, flightFinished: false) { installs += 1 }
        handoff.blend(at: landing, flightFinished: false) { installs += 1 }
        #expect(installs == 0)
        let streets = try #require(handoff.visibleMap)
        #expect(abs(streets.camera.centerCoordinateDistance - landing.distance) < 1)
        let capture = PhotoWallViewportCapture()
        capture.attach(resident, cityStreets: handoff)
        let frozen = try #require(capture.freeze())
        #expect(abs(frozen.camera.distance - landing.distance) < 1)
        handoff.residentDidRenderStreets()
        #expect(handoff.visibleMap === streets && frozen.snapshot.isCurrent())
        capture.release()
        handoff.blend(at: landing, flightFinished: true) { installs += 1 }
        let deadline = ContinuousClock.now + .seconds(3)
        while installs == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(installs == 1)
        handoff.residentDidRenderStreets()
        #expect(!handoff.isPrepared)
        #expect(capture.freeze() != nil)
    }

    @Test func cityTurnsAtOrbitalScaleThenDescendsOverItsDestination() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let start = GeoCoordinate(latitude: 20, longitude: 170)
        let city = GeoCoordinate(latitude: 20, longitude: -140)
        let orbit = GlobeCameraState.orbitalDistance
        model.transitionCamera(to: start, distance: orbit, animated: false)
        model.approachCity(at: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        model.advanceMotionFrame(elapsed: 0.4, reduceMotion: false)
        #expect(model.camera.center != start && model.camera.center != city)
        #expect(abs(model.camera.distance - orbit) < 0.01)
        model.advanceMotionFrame(elapsed: 1.5, reduceMotion: false)
        #expect(model.camera.center == city)
        #expect(abs(model.camera.distance - orbit) < 0.01)
        model.advanceMotionFrame(elapsed: 1.25, reduceMotion: false)
        #expect(model.camera.center == city)
        #expect(abs(model.camera.distance - 1_000_000) < 1)
        model.advanceMotionFrame(elapsed: 0.25, reduceMotion: false)
        let firstMapDistance = model.camera.distance
        #expect(firstMapDistance < GlobeCameraState.regionalDistance)
        #expect(model.regionalBasemapTarget?.distance == GlobeCameraState.regionalDistance)
        model.advanceMotionFrame(elapsed: 0.1, reduceMotion: false)
        #expect(model.camera.distance < firstMapDistance)
        #expect(model.isApproachingCity)
        model.advanceMotionFrame(elapsed: 1, reduceMotion: false)
        #expect(model.camera == GlobeCameraState(center: city, distance: GlobeCameraState.cityFallbackDistance))
        #expect(!model.isApproachingCity)
    }

    @Test func zoomOutDuringStreetDescentCancelsCityLanding() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let city = GeoCoordinate(latitude: 35, longitude: 140)
        model.transitionCamera(to: city, distance: GlobeCameraState.orbitalDistance, animated: false)
        model.approachCity(at: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        model.advanceMotionFrame(elapsed: 1.5, reduceMotion: false)
        let nearDistance = model.camera.distance
        #expect(nearDistance < GlobeCameraState.regionalDistance && model.isApproachingCity)
        model.zoomOut()
        #expect(!model.isApproachingCity)
        model.advanceMotionFrame(elapsed: 1, reduceMotion: false)
        #expect(model.camera.distance > nearDistance)
        model.transitionCamera(to: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        #expect(!model.isApproachingCity)
    }

    @Test func cityDescentWaitsForTheDestinationOrbitWhenTilesAreLate() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let home = GlobeCameraState(center: .init(latitude: 35, longitude: 20), distance: GlobeCameraState.orbitalDistance)
        let city = GeoCoordinate(latitude: 35, longitude: 140)
        model.transitionCamera(to: home.center, distance: home.distance, animated: false)
        model.nativeCameraFeedback.record(requested: home, actual: home)
        model.nativeCameraFeedback.renderedSatelliteCamera = home
        model.approachCity(at: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        model.advanceMotionFrame(elapsed: 3, reduceMotion: false)
        #expect(model.pendingCityLanding != nil)
        #expect(model.camera.center == city)
        #expect(model.camera.distance == home.distance)
        model.nativeCameraFeedback.renderedSatelliteCamera = model.camera
        model.advanceMotionFrame(elapsed: 0.1, reduceMotion: false)
        #expect(model.pendingCityLanding == nil)
        model.advanceMotionFrame(elapsed: 2.5, reduceMotion: false)
        #expect(model.camera.distance == GlobeCameraState.cityFallbackDistance)
    }

    @Test func cityFlightCanBeInterruptedOrCompletedWithReducedMotion() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let city = GeoCoordinate(latitude: 35, longitude: 140)
        let home = GlobeCameraState(center: .init(latitude: 10, longitude: 20), distance: GlobeCameraState.orbitalDistance)
        model.transitionCamera(to: home.center, distance: home.distance, animated: false)
        model.approachCity(at: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        model.advanceMotionFrame(elapsed: 0.3, reduceMotion: false)
        model.pauseDirectManipulation()
        model.transitionCamera(to: home.center, distance: home.distance, animated: false)
        model.advanceMotionFrame(elapsed: 3, reduceMotion: false)
        #expect(model.camera == home)
        #expect(!model.isApproachingCity)

        model.approachCity(at: city, distance: GlobeCameraState.cityFallbackDistance, animated: true)
        model.advanceMotionFrame(elapsed: 0.1, reduceMotion: true)
        #expect(model.camera == GlobeCameraState(center: city, distance: GlobeCameraState.cityFallbackDistance))
        #expect(!model.isApproachingCity)
    }

    @Test func cityLandingAbsorbsMapKitRoundoffAndClearsPreviousStyleChoice() {
        let target = GlobeCameraState.regionalDistance
        let roundedUp = 800_000.0000000099
        #expect(GlobeScale(distance: roundedUp, requestedDistance: target) == .map)
        #expect(GlobeScale(distance: roundedUp, requestedDistance: roundedUp) == .globe)
        #expect(GlobeScale(distance: target + 1, requestedDistance: target) == .globe)

        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        model.updateScale(.map)
        model.toggleMapStyle()
        #expect(model.mapStyle == .satellite)
        model.activate(initialCenter: nil, startsAtCity: true) { _, _ in [] }
        #expect(model.mapStyle == .standard)
    }

    @Test func thresholdOwnsEqualityAndChangingBandsResetsOnlyTheManualStyle() {
        var state = GlobeScalePresentation()
        for distance in [801_000.0, 800_001, 800_000, 799_999, 799_000, 800_000, 800_001, 801_000] {
            state.enter(GlobeScale(distance: distance))
            #expect(state.scale == (distance <= 800_000 ? .map : .globe))
            #expect(state.style == (distance <= 800_000 ? .standard : .satellite))
            #expect(state.markers == (distance <= 800_000 ? .awaitingPhotos : .places))
        }
        state.toggleStyle()
        state.enter(.globe)
        #expect(state.style == .standard)
        state.enter(.map)
        state.toggleStyle()
        state.enter(.map)
        #expect(state.style == .satellite)
        state.publish([])
        guard case .photos(_, []) = state.markers else {
            Issue.record("An empty completed viewport must remove all place glows")
            return
        }
        state.discardPins()
        #expect(state.markers == .awaitingPhotos)
        state.enter(.globe)
        state.publish([])
        #expect(state.markers == .places)
    }

    @Test func lateNearQueryCannotReplaceGlowsAfterZoomingOut() async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var result: CheckedContinuation<ViewportPhotoBatch, Never>?
        let photo = PhotoAssetRecord(id: "preview", coordinate: .init(latitude: 0, longitude: 0),
                                     creationDate: .now, pixelWidth: 1200, pixelHeight: 800, isFavorite: false)
        model.activate(initialCenter: nil, nearPhotoQuery: { _, publishPreview in
            publishPreview([photo])
            let batch = await withCheckedContinuation { result = $0 }
            publishPreview([photo])
            return batch
        }) { _, _ in [] }
        model.updateScale(.map)
        model.receiveViewport(.init(viewport: model.currentViewport, isCurrent: { true }, containsCoordinate: { _ in true }))
        for _ in 0..<50 where result == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pending = try #require(result)
        #expect(model.isRefreshingPhotos && model.photoBatchReady && model.visiblePhotos == [photo])
        #expect(model.presentation.markers == .awaitingPhotos && model.visiblePhotoCount == nil)
        model.updateScale(.globe)
        pending.resume(returning: ViewportPhotoBatch(clusters: [], preview: []))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.presentation.markers == .places)
        #expect(model.visiblePhotoCount == nil)
        #expect(!model.photoBatchReady && model.visiblePhotos.isEmpty)
    }

    @Test func cancelledAndSupersededBasemapLoadsCannotChangeTheVisibleStyle() throws {
        var preparation = MapStyleHandoff.Preparation()
        let map = MapStyleHandoff.Style(map: .standard, flat: true)
        let globe = MapStyleHandoff.Style(map: .satellite, flat: false)
        let obsoleteRequest = preparation.begin(map)
        let obsolete = try #require(obsoleteRequest)
        let duplicate = preparation.begin(map)
        #expect(duplicate == nil)
        let currentRequest = preparation.begin(globe)
        let current = try #require(currentRequest)
        let obsoleteFinished = preparation.finish(obsolete)
        let currentFinished = preparation.finish(current)
        let duplicateFinish = preparation.finish(current)
        #expect(!obsoleteFinished)
        #expect(currentFinished)
        #expect(!duplicateFinish)
        let cancelledRequest = preparation.begin(map)
        let cancelled = try #require(cancelledRequest)
        preparation.cancel()
        let cancelledFinished = preparation.finish(cancelled)
        #expect(!cancelledFinished)
    }

    @Test func slowStylePrefetchHandsOffOnceAndIgnoresLateTiles() async throws {
        var callbacks: [@MainActor () -> Void] = []
        let handoff = MapStyleHandoff(prefetchBudget: .milliseconds(20)) { _, finish in callbacks.append(finish) }
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        var installed: [PhotoMapStyle] = []
        let camera = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 0), distance: 100_000)
        handoff.prepare(.init(map: .satellite, flat: false), at: camera, in: map) { installed.append(.satellite) }
        handoff.prepare(.init(map: .standard, flat: true), at: camera, in: map) { installed.append(.standard) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(installed == [.standard])
        for finish in callbacks { finish() }
        #expect(installed == [.standard] && !handoff.isPreparing)
    }

    @Test func nativeDistanceAndProjectionDriveBothMarkerLayersOnTheSameMap() async throws {
        let center = GeoCoordinate(latitude: 48.86, longitude: 2.35)
        let cover = GeoCoordinate(latitude: 48.861, longitude: 2.355)
        let place = TravelPlace(id: "paris", name: "Paris", country: "France",
                                coordinate: center, startDate: .now, endDate: .now, photoCount: 3, coverAssetID: nil)
        let cluster = MapReviewCluster(cell: .init(column: 0, row: 0), count: 3, coordinate: cover,
                                      south: cover.latitude, north: cover.latitude, west: cover.longitude,
                                      east: cover.longitude, assetID: "cover")
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        defer { coordinator.cancelPendingSnapshot() }
        var state = GlobeScalePresentation()
        var distance = 1_200_000.0
        func apply() {
            coordinator.update(map, places: [place], horizontalPresentationOffset: 0, contentRevision: 1,
                               camera: .init(center: center, distance: distance), isManipulating: false,
                               showsUserLocation: false, settleRevision: 0, mapStyle: state.style,
                               scalePresentation: state, onScaleChanged: { state.enter($0) },
                               onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
            map.layoutIfNeeded()
        }
        apply()
        #expect(map.annotations.count == 1)
        distance = GlobeCameraState.cityFallbackDistance
        apply()
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.scale == GlobeScale(distance: map.camera.centerCoordinateDistance))
        #expect(state.scale == .map)
        let cameraBeforeStyleChange = map.camera.copy() as! MKMapCamera
        apply()
        #expect((map.preferredConfiguration as? MKStandardMapConfiguration)?.elevationStyle == .flat)
        #expect(abs(map.camera.centerCoordinateDistance - cameraBeforeStyleChange.centerCoordinateDistance) < 100)
        #expect(map.annotations.count == 1)
        state.publish([cluster])
        apply()
        let pin = try #require(map.annotations.compactMap { $0 as? MapReviewPhotoAnnotation }.first)
        #expect(map.annotations.count == 1)
        #expect(pin.coordinate.latitude == cover.latitude)
        #expect(pin.coordinate.longitude == cover.longitude)
        state.publish([])
        apply()
        #expect(map.annotations.isEmpty)
        distance = 1_200_000
        apply()
        try await Task.sleep(for: .milliseconds(100))
        apply()
        #expect(state.scale == .globe)
        #expect(map.preferredConfiguration is MKImageryMapConfiguration)
        #expect(map.annotations.count == 1)
        #expect(map.annotations.allSatisfy { !($0 is MapReviewPhotoAnnotation) })
    }
}
