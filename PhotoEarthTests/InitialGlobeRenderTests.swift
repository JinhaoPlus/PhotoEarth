import MapKit
import SwiftUI
import Testing
import UIKit
@testable import PhotoEarth

struct InitialGlobeRenderTests {
    @Test @MainActor
    func laidOutHomeWordmarkWaitsForItsOwnGlobeReveal() async throws {
        let flight = OpeningWordmarkFlight()
        let header = HomeWordmark(scene: .home)
            .environment(flight)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = UIHostingController(rootView: header)
        window.isHidden = false
        defer { window.isHidden = true }

        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(flight.destination == nil && !flight.finished)

        flight.revealedScene = .welcome
        try await Task.sleep(for: .milliseconds(100))
        #expect(flight.destination == nil && !flight.finished)

        flight.revealedScene = .home
        for _ in 0..<50 {
            if flight.destination != nil || flight.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(flight.destination != nil || flight.finished)
    }

    @Test @MainActor
    func reducedMotionShowsTheHomeWordmarkImmediatelyAndOnlyOnce() {
        let flight = OpeningWordmarkFlight()
        flight.land(at: CGPoint(x: 1720, y: 82), reduceMotion: true)
        #expect(flight.finished)
        #expect(flight.destination == nil)

        // Returning from a shelf can lay the header out again.
        flight.land(at: CGPoint(x: 1680, y: 82), reduceMotion: false)
        #expect(flight.destination == nil)
    }

    @Test @MainActor
    func revealRequiresAStableFullyRenderedSignalAndOnlyFiresOnce() async throws {
        var revealCount = 0
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        let controller = UIViewController()
        controller.view.frame = map.bounds
        controller.view.addSubview(map)
        let window = UIWindow(frame: map.bounds)
        window.rootViewController = controller
        window.isHidden = false
        map.layoutIfNeeded()

        let coordinator = MapKitEarthView.Coordinator(
            onViewportSettled: { _ in },
            onUserLocationUpdate: { _ in },
            onInitialRenderReady: { revealCount += 1 }
        )
        defer {
            coordinator.cancelPendingSnapshot()
            coordinator.cancelPendingInitialRender()
            window.isHidden = true
        }

        func waitFor(_ scene: InitialGlobeScene) {
            coordinator.update(
                map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
                camera: GlobeCameraState(center: .init(latitude: 20, longitude: 10)),
                isManipulating: false, showsUserLocation: false, settleRevision: 0,
                initialRenderScene: scene,
                onViewportSettled: { _ in }, onUserLocationUpdate: { _ in },
                onInitialRenderReady: { revealCount += 1 }
            )
        }
        waitFor(.welcome)

        coordinator.mapViewDidFinishRenderingMap(map, fullyRendered: true)
        try await Task.sleep(for: .milliseconds(150))
        coordinator.mapViewDidFinishRenderingMap(map, fullyRendered: false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(revealCount == 0)

        coordinator.mapViewDidFinishRenderingMap(map, fullyRendered: true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(revealCount == 1)

        coordinator.mapViewDidFinishRenderingMap(map, fullyRendered: true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(revealCount == 1)

        // Entering Home starts a separate wait, even when the camera already rendered.
        waitFor(.home)
        try await Task.sleep(for: .milliseconds(450))
        #expect(revealCount == 2)
    }
}
