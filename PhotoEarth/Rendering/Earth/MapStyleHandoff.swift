import MapKit
import SwiftUI

/// Fetch the destination style through MapKit before releasing the working
/// basemap. There is one resident MKMapView and at most one pending snapshot.
/// A still of the outgoing map bridges the renderer change at a stationary camera.
@MainActor
final class MapStyleHandoff {
    struct Style: Equatable {
        let map: PhotoMapStyle
        let flat: Bool
    }

    struct Preparation {
        private(set) var pending: (style: Style, id: UUID)?

        mutating func begin(_ style: Style) -> UUID? {
            guard pending?.style != style else { return nil }
            let id = UUID()
            pending = (style, id)
            return id
        }

        mutating func finish(_ id: UUID) -> Bool {
            guard pending?.id == id else { return false }
            pending = nil
            return true
        }

        mutating func cancel() { pending = nil }
    }

    private var preparation = Preparation()
    private var snapshotter: MKMapSnapshotter?
    private(set) var cityTarget: GlobeCameraState?
    private var satelliteTarget: GlobeCameraState?
    private var installCity: (() -> Void)?
    private var prefetchDeadline: Task<Void, Never>?
    private let prefetchBudget: Duration
    private let startSnapshot: (MKMapSnapshotter, @escaping @MainActor () -> Void) -> Void

    init(prefetchBudget: Duration = .seconds(2),
         startSnapshot: @escaping (MKMapSnapshotter, @escaping @MainActor () -> Void) -> Void = { request, done in
             request.start { _, _ in done() }
         }) {
        self.prefetchBudget = prefetchBudget
        self.startSnapshot = startSnapshot
    }

    private var outgoingView: UIView?
    private var revealDeadline: Task<Void, Never>?
    var isPreparing: Bool { preparation.pending != nil }
    var isWaitingToInstall: Bool { isPreparing && (satelliteTarget == nil || installCity != nil) }

    func holdSatelliteFrame(in map: MKMapView) {
        discardFrame()
        let bounds = map.bounds
        guard map.window != nil, bounds.width > 0, bounds.height > 0 else { return }
        // snapshotView can follow MapKit's replacement render surface and
        // show its orbital fallback. Copy the displayed pixels before switching.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var captured = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            captured = map.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard captured else { return }
        let frame = UIImageView(image: image)
        frame.layer.zPosition = 1
        frame.isUserInteractionEnabled = false
        frame.accessibilityElementsHidden = true
        frame.frame = map.bounds
        map.addSubview(frame)
        outgoingView = frame
        // A failed native tile request must still release the outgoing image.
        revealDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.revealMap()
        }
    }

    func revealMap() {
        guard let frame = outgoingView, revealDeadline != nil else { return }
        revealDeadline?.cancel()
        revealDeadline = nil
        if UIAccessibility.isReduceMotionEnabled {
            discardFrame()
            return
        }
        UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            frame.alpha = 0
        } completion: { [weak self] _ in
            frame.removeFromSuperview()
            if self?.outgoingView === frame { self?.outgoingView = nil }
        }
    }

    func discardFrame() {
        revealDeadline?.cancel()
        revealDeadline = nil
        outgoingView?.removeFromSuperview()
        outgoingView = nil
    }

    func warmCity(_ target: GlobeCameraState, from origin: GlobeCameraState, in map: MKMapView) {
        installCity = nil
        guard cityTarget != target else { return }
        if satelliteTarget != target { warmSatellite(to: target, from: origin, in: map) }
        cityTarget = target
        if !isPreparing { warmStreets(at: target, in: map) }
    }

    func warmSatellite(to target: GlobeCameraState, from origin: GlobeCameraState, in map: MKMapView) {
        guard satelliteTarget != target || cityTarget != nil else { return }
        cancel()
        satelliteTarget = target
        // Match the on-screen orbit and a scale on the way down. Long turns
        // also expose a hemisphere between home and the city.
        let orbit = GlobeCameraState(center: target.center, distance: origin.distance).mapConstrained()
        var cameras = [orbit]
        if GlobeMath.angularDistanceDegrees(from: origin.center, to: target.center) > 45 {
            var rotation = GlobeCameraFlight(origin: origin, destination: orbit, duration: 1)
            cameras.append(rotation.advance(by: 0.5).mapConstrained())
        }
        if orbit.distance > target.distance {
            // The last part of the descent exposes a finer imagery level
            // before the street map takes over.
            var descent = GlobeCameraFlight(origin: orbit, destination: target, duration: 1)
            cameras.append(descent.advance(by: 2.0 / 3).mapConstrained())
        }
        warmSatelliteFrames(cameras[...], to: target, in: map)
    }

    private func warmSatelliteFrames(_ cameras: ArraySlice<GlobeCameraState>, to target: GlobeCameraState, in map: MKMapView) {
        guard satelliteTarget == target else { return }
        guard let camera = cameras.first else {
            if cityTarget == target { warmStreets(at: target, in: map) }
            return
        }
        load(Style(map: .satellite, flat: false), camera: camera.nativeCamera, in: map,
             width: min(map.bounds.width, 1920)) { [weak self, weak map] in
            guard let self, let map else { return }
            self.warmSatelliteFrames(cameras.dropFirst(), to: target, in: map)
        }
    }

    private func warmStreets(at target: GlobeCameraState, in map: MKMapView) {
        load(Style(map: .standard, flat: true), camera: target.nativeCamera, in: map) { [weak self] in
            self?.installCity?()
            self?.installCity = nil
        }
    }

    func prepare(_ style: Style, at camera: GlobeCameraState? = nil, in map: MKMapView, ready: @escaping () -> Void) {
        if let camera, cityTarget == camera, style == Style(map: .standard, flat: true),
           preparation.pending?.style.map != .satellite {
            if isPreparing { installCity = ready } else { ready() }
            return
        }
        if satelliteTarget != nil { cancel() }
        load(style, camera: map.camera, in: map, ready: ready)
    }

    private func load(_ style: Style, camera: MKMapCamera, in map: MKMapView, width: CGFloat = 640, ready: @escaping () -> Void) {
        guard let receipt = preparation.begin(style) else { return }
        prefetchDeadline?.cancel()
        snapshotter?.cancel()
        let options = MKMapSnapshotter.Options()
        options.camera = camera.copy() as! MKMapCamera
        options.size = CGSize(width: max(1, width), height: max(1, width * map.bounds.height / max(map.bounds.width, 1)))
        options.traitCollection = map.traitCollection
        options.preferredConfiguration = style.map.configuration(realisticTerrain: !style.flat)
        let request = MKMapSnapshotter(options: options)
        snapshotter = request
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.preparation.finish(receipt) else { return }
            self.prefetchDeadline?.cancel()
            self.prefetchDeadline = nil
            self.snapshotter?.cancel()
            self.snapshotter = nil
            ready()
        }
        // A slow speculative snapshot should not postpone the live map's own tile requests.
        prefetchDeadline = Task { [prefetchBudget] in
            do { try await Task.sleep(for: prefetchBudget) } catch { return }
            finish()
        }
        startSnapshot(request, finish)
    }

    func cancel() {
        satelliteTarget = nil
        cityTarget = nil
        installCity = nil
        preparation.cancel()
        prefetchDeadline?.cancel()
        prefetchDeadline = nil
        snapshotter?.cancel()
        snapshotter = nil
    }
}


/// Cold native tiles can take substantially longer than photos or the camera.
/// Leave navigation available and identify the missing layer during that wait.
@MainActor
final class MapImageryStatus {
    private var delay: Task<Void, Never>?
    private weak var indicator: UIView?

    func start(in map: MKMapView) {
        guard delay == nil, indicator == nil else { return }
        delay = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let map else { return }
            delay = nil
            guard map.window != nil else { return }
            let indicator = UIHostingConfiguration {
                Text(AppLocalization.string("globe.basemap.loading", defaultValue: "Loading map imagery…"))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .floatingSurface(in: Capsule())
                    .accessibilityIdentifier("earth-basemap-loading")
            }
            .margins(.all, 0)
            .makeContentView()
            indicator.isUserInteractionEnabled = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            map.addSubview(indicator)
            self.indicator = indicator
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: map.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 25)
            ])
        }
    }

    func finish() {
        delay?.cancel()
        delay = nil
        indicator?.removeFromSuperview()
        indicator = nil
    }
}
