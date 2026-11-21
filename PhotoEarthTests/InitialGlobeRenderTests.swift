import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct InitialGlobeRenderTests {
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

        coordinator.update(
            map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
            camera: GlobeCameraState(center: .init(latitude: 20, longitude: 10)),
            isManipulating: false, showsUserLocation: false, settleRevision: 0,
            waitsForInitialRender: true,
            onViewportSettled: { _ in }, onUserLocationUpdate: { _ in },
            onInitialRenderReady: { revealCount += 1 }
        )

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
    }
}
