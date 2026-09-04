import Combine
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class GlobeExperienceModel: ObservableObject {
    @Published private(set) var camera = GlobeCameraState()
    @Published private(set) var isManipulating = false
    @Published private(set) var isRefreshingPhotos = false
    @Published private(set) var visiblePhotos: [PhotoAssetRecord] = []
    @Published private(set) var settleRevision = 0
    @Published private(set) var cameraTransitionRevision = 0
    @Published private(set) var latestViewport: EarthViewport?

    private var remoteInput: SiriRemoteInputController?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: GlobeDisplayLinkProxy?
    private var directionalInput = CGVector.zero
    private var rotationVelocity = CGVector.zero
    private var zoomVelocity = 0.0
    private var pendingZoomDelta = 0.0
    private var pendingTouchPan = CGVector.zero
    private var isRingTouching = false
    private var lastFrameTimestamp: CFTimeInterval?
    private var lastInputTimestamp = CACurrentMediaTime()
    private var hasConfiguredInitialCamera = false
    private var photoQuery: ((EarthViewport, Int) async -> [PhotoAssetRecord])?
    private var photoQueryGeneration = UUID()
    private var queryTask: Task<Void, Never>?
    private var latestViewportCameraDistance: Double?
    private var lastQueriedViewport: EarthViewport?
    private var lastTouchInputTimestamp: CFTimeInterval = 0

    var currentViewport: EarthViewport {
        let fallbackRadius = 55 * camera.distance / GlobeCameraState.defaultDistance
        guard let latestViewport, let latestViewportCameraDistance else {
            return EarthViewport(center: camera.center, angularRadius: fallbackRadius)
        }
        return EarthViewport(
            center: camera.center,
            angularRadius: latestViewport.angularRadius * camera.distance / latestViewportCameraDistance
        )
    }

    func activate(
        initialCenter: GeoCoordinate?,
        photoQuery: @escaping (EarthViewport, Int) async -> [PhotoAssetRecord]
    ) {
        if !hasConfiguredInitialCamera {
            if let initialCenter { camera.center = initialCenter }
            hasConfiguredInitialCamera = true
        }
        self.photoQuery = photoQuery
        startDisplayLink()
        startRemoteInput()
        settleRevision += 1
    }

    func transitionCamera(
        to center: GeoCoordinate,
        distance: Double,
        animated: Bool = true
    ) {
        camera = GlobeCameraState(center: center, distance: distance)
        hasConfiguredInitialCamera = true
        if animated { cameraTransitionRevision += 1 }
        settleRevision += 1
    }

    func pauseDirectManipulation() {
        remoteInput?.stop()
        remoteInput = nil
        directionalInput = .zero
        rotationVelocity = .zero
        zoomVelocity = 0
        pendingZoomDelta = 0
        pendingTouchPan = .zero
        isRingTouching = false
        isManipulating = false
        queryTask?.cancel()
        queryTask = nil
        isRefreshingPhotos = false
    }

    func resumeDirectManipulation() {
        startDisplayLink()
        startRemoteInput()
        settleRevision += 1
    }

    func refreshPhotos() {
        lastQueriedViewport = nil
        settleRevision += 1
    }

    func deactivate() {
        remoteInput?.stop()
        remoteInput = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        queryTask?.cancel()
        queryTask = nil
        photoQuery = nil
    }

    func nudge(_ direction: MoveCommandDirection) {
        // A touch swipe can also be translated into a SwiftUI move command after
        // the finger lifts. The analog pan already handled that gesture.
        guard CACurrentMediaTime() - lastTouchInputTimestamp > 0.24 else { return }
        let impulse = 30.0 * rotationScale
        switch direction {
        case .left:
            rotationVelocity.dx -= impulse
        case .right:
            rotationVelocity.dx += impulse
        case .up:
            rotationVelocity.dy += impulse
        case .down:
            rotationVelocity.dy -= impulse
        @unknown default:
            return
        }
        markInput()
    }

    func receiveViewport(_ viewport: EarthViewport) {
        latestViewport = viewport
        latestViewportCameraDistance = camera.distance
        guard !isManipulating else { return }
        guard shouldRefreshPhotos(for: viewport) else {
            isRefreshingPhotos = false
            return
        }
        queryTask?.cancel()
        let generation = UUID()
        photoQueryGeneration = generation
        guard let photoQuery else { return }
        isRefreshingPhotos = false

        queryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(850))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.photoQueryGeneration == generation,
                  !self.isManipulating else { return }
            lastQueriedViewport = viewport
            isRefreshingPhotos = true
            let photos = await photoQuery(viewport, 18)
            guard !Task.isCancelled, self.photoQueryGeneration == generation else { return }
            visiblePhotos = photos
            isRefreshingPhotos = false
        }
    }

    private var rotationScale: Double {
        min(max(sqrt(camera.distance / GlobeCameraState.defaultDistance), 0.22), 1.35)
    }

    private func startRemoteInput() {
        guard remoteInput == nil else { return }
        let input = SiriRemoteInputController()
        input.onDirectionalChange = { [weak self] horizontal, vertical in
            self?.setDirectionalInput(horizontal: horizontal, vertical: vertical)
        }
        input.onTouchPan = { [weak self] horizontalDelta, verticalDelta in
            self?.applyTouchPan(
                horizontalDelta: horizontalDelta,
                verticalDelta: verticalDelta
            )
        }
        input.onRingRotation = { [weak self] angleDelta in
            self?.applyRingRotation(angleDelta)
        }
        input.onRingTouchChanged = { [weak self] touching in
            self?.isRingTouching = touching
            if touching {
                self?.markInput()
            } else {
                self?.lastInputTimestamp = CACurrentMediaTime()
            }
        }
        input.start()
        remoteInput = input
    }

    private func setDirectionalInput(horizontal: Double, vertical: Double) {
        directionalInput = CGVector(dx: horizontal, dy: vertical)
        if abs(horizontal) > 0.05 || abs(vertical) > 0.05 {
            markInput()
        } else {
            lastInputTimestamp = CACurrentMediaTime()
        }
    }

    private func applyRingRotation(_ angleDelta: Double) {
        // atan2 grows counterclockwise. A clockwise movement is negative and therefore zooms in.
        pendingZoomDelta += angleDelta * 0.92
        lastTouchInputTimestamp = CACurrentMediaTime()
        markInput()
    }

    private func applyTouchPan(
        horizontalDelta: Double,
        verticalDelta: Double
    ) {
        pendingTouchPan.dx += horizontalDelta
        pendingTouchPan.dy += verticalDelta
        rotationVelocity = .zero
        lastTouchInputTimestamp = CACurrentMediaTime()
        markInput()
    }

    private func markInput() {
        lastInputTimestamp = CACurrentMediaTime()
        if !isManipulating {
            isManipulating = true
        }
        photoQueryGeneration = UUID()
        queryTask?.cancel()
        isRefreshingPhotos = false
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = GlobeDisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(GlobeDisplayLinkProxy.step(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        let previousTimestamp = lastFrameTimestamp ?? displayLink.timestamp
        let deltaTime = min(max(displayLink.timestamp - previousTimestamp, 0), 1.0 / 15.0)
        lastFrameTimestamp = displayLink.timestamp
        guard deltaTime > 0 else { return }

        let hasDirectionalInput = abs(directionalInput.dx) > 0.05 || abs(directionalInput.dy) > 0.05
        if hasDirectionalInput {
            let targetSpeed = 38.0 * rotationScale
            let target = CGVector(
                dx: directionalInput.dx * targetSpeed,
                dy: directionalInput.dy * targetSpeed
            )
            let blend = 1 - exp(-10 * deltaTime)
            rotationVelocity.dx += (target.dx - rotationVelocity.dx) * blend
            rotationVelocity.dy += (target.dy - rotationVelocity.dy) * blend
        } else if UIAccessibility.isReduceMotionEnabled {
            rotationVelocity = .zero
        } else {
            let decay = exp(-4.6 * deltaTime)
            rotationVelocity.dx *= decay
            rotationVelocity.dy *= decay
        }

        if pendingZoomDelta != 0 {
            let applied = min(max(pendingZoomDelta, -0.18), 0.18)
            pendingZoomDelta -= applied
            zoomVelocity = applied / deltaTime * 0.16
            var nextCamera = camera
            nextCamera.zoom(logarithmicDelta: applied)
            camera = nextCamera
        } else if abs(zoomVelocity) > 0.001, !UIAccessibility.isReduceMotionEnabled {
            var nextCamera = camera
            nextCamera.zoom(logarithmicDelta: zoomVelocity * deltaTime)
            camera = nextCamera
            zoomVelocity *= exp(-7.5 * deltaTime)
        } else {
            zoomVelocity = 0
        }

        if abs(pendingTouchPan.dx) > 0.0001 || abs(pendingTouchPan.dy) > 0.0001 {
            var nextCamera = camera
            nextCamera.panWithTouchSurface(
                horizontalDelta: pendingTouchPan.dx,
                verticalDelta: pendingTouchPan.dy,
                sensitivity: 52 * rotationScale
            )
            camera = nextCamera
            pendingTouchPan = .zero
        }

        if abs(rotationVelocity.dx) > 0.01 || abs(rotationVelocity.dy) > 0.01 {
            var nextCamera = camera
            nextCamera.rotate(
                longitudeDelta: rotationVelocity.dx * deltaTime,
                latitudeDelta: rotationVelocity.dy * deltaTime
            )
            camera = nextCamera
        }

        let motionIsQuiet = !hasDirectionalInput
            && !isRingTouching
            && abs(rotationVelocity.dx) < 0.08
            && abs(rotationVelocity.dy) < 0.08
            && abs(zoomVelocity) < 0.001
            && abs(pendingZoomDelta) < 0.001
            && abs(pendingTouchPan.dx) < 0.0001
            && abs(pendingTouchPan.dy) < 0.0001
        if isManipulating,
           motionIsQuiet,
           CACurrentMediaTime() - lastInputTimestamp >= 0.45 {
            rotationVelocity = .zero
            zoomVelocity = 0
            isManipulating = false
            settleRevision += 1
        }
    }

    private func shouldRefreshPhotos(for viewport: EarthViewport) -> Bool {
        guard let lastQueriedViewport else { return true }
        let centerDelta = GlobeMath.angularDistanceDegrees(
            from: lastQueriedViewport.center,
            to: viewport.center
        )
        let radiusDelta = abs(lastQueriedViewport.angularRadius - viewport.angularRadius)
        let centerTolerance = max(0.7, viewport.angularRadius * 0.055)
        let radiusTolerance = max(0.6, viewport.angularRadius * 0.08)
        return centerDelta > centerTolerance || radiusDelta > radiusTolerance
    }

}

@MainActor
private final class GlobeDisplayLinkProxy: NSObject {
    weak var owner: GlobeExperienceModel?

    init(owner: GlobeExperienceModel) {
        self.owner = owner
    }

    @objc func step(_ displayLink: CADisplayLink) {
        owner?.tick(displayLink)
    }
}
