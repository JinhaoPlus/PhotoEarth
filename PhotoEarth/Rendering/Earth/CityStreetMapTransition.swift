import MapKit

/// A temporary, read-only street renderer lets both basemaps follow the same
/// city flight while the resident map replaces its satellite renderer.
@MainActor
final class CityStreetMapTransition {
    private enum Phase { case preparing, blending, presenting, covering }
    private var phase = Phase.preparing
    private var streets: MKMapView?
    private var target: GlobeCameraState?
    private var displayedCamera: GlobeCameraState?
    var onResidentReady: (() -> Void)?
    private var flightFinished = false
    private var expiry: Task<Void, Never>?

    var isPrepared: Bool { streets != nil }
    var isVisible: Bool { phase != .preparing }
    var visibleMap: MKMapView? { isVisible ? streets : nil }

    func prepare(_ target: GlobeCameraState, in resident: MKMapView) {
        guard self.target != target, resident.window != nil, !resident.bounds.isEmpty else { return }
        cancel()
        let map = MKMapView(frame: resident.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.overrideUserInterfaceStyle = resident.overrideUserInterfaceStyle
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = resident.layoutMargins
        map.isUserInteractionEnabled = false
        map.accessibilityElementsHidden = true
        map.showsScale = false
        map.preferredConfiguration = PhotoMapStyle.standard.configuration(realisticTerrain: false)
        map.alpha = 0
        map.layer.zPosition = 1
        resident.addSubview(map)
        map.setCamera(target.nativeCamera, animated: false)
        streets = map
        self.target = target
        displayedCamera = target
    }

    func blend(at camera: GlobeCameraState, flightFinished: Bool, install: @escaping @MainActor () -> Void) {
        guard let streets else { return }
        self.flightFinished = flightFinished
        if displayedCamera != camera {
            streets.setCamera(camera.nativeCamera, animated: false)
            displayedCamera = camera
        }
        if phase == .presenting && flightFinished {
            installResident(install)
            return
        }
        guard phase == .preparing else { return }
        phase = .blending
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            streets.alpha = 1
        } completion: { [weak self, weak streets] completed in
            guard completed, let self, let streets, self.streets === streets else { return }
            self.phase = .presenting
            if self.flightFinished { self.installResident(install) }
        }
    }

    private func installResident(_ install: () -> Void) {
        // Changing the resident renderer can stall MapKit's drawing thread.
        // Keep that work out of the moving part of the flight.
        install()
        phase = .covering
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.residentDidRenderStreets()
        }
    }

    /// The wall owns the projection of this map until it releases its capture.
    func freeze() {
        expiry?.cancel()
        expiry = nil
        if phase == .covering { phase = .presenting }
        flightFinished = false
    }

    func residentDidRenderStreets() {
        guard phase == .covering else { return }
        let ready = onResidentReady
        cancel()
        ready?()
    }

    func cancel() {
        guard streets != nil else { return }
        expiry?.cancel()
        expiry = nil
        onResidentReady = nil
        let previous = streets
        streets = nil
        previous?.layer.removeAllAnimations()
        previous?.removeFromSuperview()
        target = nil
        displayedCamera = nil
        phase = .preparing
    }
}
