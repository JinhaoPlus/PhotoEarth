import Foundation
import Testing
@testable import PhotoEarth

struct GlobeMotionTests {
    @Test @MainActor func directionNoiseDoesNotStartCameraDrift() {
        let model = GlobeExperienceModel()
        model.activate(initialCenter: nil) { _, _ in [] }
        defer { model.deactivate() }
        let initial = model.camera
        model.setDirectionalInput(horizontal: 0.03, vertical: 0.03)
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        }
        #expect(model.camera == initial)
        #expect(!model.isManipulating)
    }

    @Test(arguments: [false, true]) @MainActor
    func physicalTapBetweenDisplayFramesStillMovesACompleteStep(reduceMotion: Bool) {
        let model = GlobeExperienceModel()
        model.activate(initialCenter: nil) { _, _ in [] }
        defer { model.deactivate() }
        let longitude = model.camera.center.longitude
        let expectedTravel = 2.5 * model.camera.navigationScale
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        }
        #expect(abs(model.camera.center.longitude - longitude - expectedTravel) < 0.02)
    }

    @Test func coastingDistanceIsIndependentOfFrameRate() {
        func distance(frames: Int) -> Double {
            var axis = GlobeDampedAxis(velocity: 38)
            return (0..<frames).reduce(0) { result, _ in
                result + axis.advance(toward: 0, response: 12, elapsed: 1 / Double(frames))
            }
        }
        let reference = distance(frames: 30)
        #expect(abs(distance(frames: 15) - reference) < 0.000_001)
        #expect(abs(distance(frames: 60) - reference) < 0.000_001)
        #expect(reference < 3.2)
    }

    @Test func accelerationSurvivesUnevenFrameIntervals() {
        var even = GlobeDampedAxis()
        let evenDistance = (0..<30).reduce(0.0) { result, _ in
            result + even.advance(toward: 38, response: 10, elapsed: 1.0 / 30)
        }
        var uneven = GlobeDampedAxis()
        let unevenDistance = (0..<10).reduce(0.0) { result, _ in
            result + uneven.advance(toward: 38, response: 10, elapsed: 1.0 / 60)
                + uneven.advance(toward: 38, response: 10, elapsed: 1.0 / 30)
                + uneven.advance(toward: 38, response: 10, elapsed: 1.0 / 20)
        }
        #expect(abs(unevenDistance - evenDistance) < 0.000_001)
        #expect(abs(uneven.velocity - even.velocity) < 0.000_001)
    }

    @Test func flightCrossesDateLineAlongShortPathAndUsesLogarithmicZoom() {
        let origin = GlobeCameraState(
            center: GeoCoordinate(latitude: 20, longitude: 175), distance: 4_000_000
        )
        let destination = GlobeCameraState(
            center: GeoCoordinate(latitude: 40, longitude: -175), distance: 16_000_000
        )
        var flight = GlobeCameraFlight(origin: origin, destination: destination, duration: 1)
        let midpoint = flight.advance(by: 0.5)
        #expect(midpoint.center.latitude == 30)
        #expect(abs(midpoint.center.longitude) == 180)
        #expect(abs(midpoint.distance - 8_000_000) < 0.001)
        #expect(flight.advance(by: 0.5) == destination)
        #expect(flight.isComplete)
    }

    @Test func fastZoomRetargetKeepsVelocityWithoutOvershootingAShortRemainingDistance() {
        let origin = GlobeCameraState(distance: GlobeCameraState.minimumDistance * 1.0625)
        let destination = GlobeCameraState(center: origin.center, distance: GlobeCameraState.minimumDistance)
        var flight = GlobeCameraFlight(origin: origin, destination: destination, duration: 0.32,
                                       initialLogarithmicVelocity: -4)
        #expect(flight.logarithmicVelocity == -4)
        #expect(flight.duration < 0.32)
        var previous = origin.distance
        for _ in 0..<40 {
            let camera = flight.advance(by: 0.002)
            #expect(camera.distance <= previous)
            #expect(camera.distance >= destination.distance)
            previous = camera.distance
        }
        #expect(flight.isComplete)
        #expect(previous == destination.distance)
        #expect(flight.logarithmicVelocity == 0)
    }

    @Test func cameraRejectsNonfiniteInputWithoutPoisoningMapKit() {
        var camera = GlobeCameraState()
        let previous = camera
        camera.rotate(longitudeDelta: .nan, latitudeDelta: 2)
        camera.zoom(logarithmicDelta: .infinity)
        #expect(camera == previous)
        let recovered = GlobeCameraState(
            center: GeoCoordinate(latitude: .nan, longitude: .infinity), distance: .nan
        )
        #expect(recovered.center.isValid)
        #expect(recovered.distance == GlobeCameraState.defaultDistance)
    }

    @Test @MainActor func cancelledViewportQueryCanRetryInTheSameRegion() async throws {
        let model = GlobeExperienceModel()
        let probe = QueryProbe()
        let viewport = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 40)
        model.activate(initialCenter: viewport.center) { _, _ in
            await probe.didStart()
            try? await Task.sleep(for: .seconds(5))
            return []
        }
        defer { model.deactivate() }
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: viewport, isCurrent: { true }, containsCoordinate: { viewport.contains($0) }
        ))
        try await waitForCallCount(1, probe: probe)
        model.pauseDirectManipulation()
        model.resumeDirectManipulation()
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: viewport, isCurrent: { true }, containsCoordinate: { viewport.contains($0) }
        ))
        try await waitForCallCount(2, probe: probe)
        #expect(await probe.callCount == 2)
    }

    private func waitForCallCount(_ count: Int, probe: QueryProbe) async throws {
        for _ in 0..<100 {
            if await probe.callCount >= count { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Viewport query did not start within its debounce window")
    }
}

private actor QueryProbe {
    private(set) var callCount = 0
    func didStart() { callCount += 1 }
}
