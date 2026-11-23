import Combine
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class GlobeExperienceModel: ObservableObject {
    let nativeCameraFeedback = NativeGlobeCameraFeedback()
    let photoWallViewportCapture = PhotoWallViewportCapture()
    @Published private(set) var camera = GlobeCameraState().mapConstrained()
    @Published private(set) var presentation = GlobeScalePresentation()
    var mapStyle: PhotoMapStyle { presentation.style }
    @Published private(set) var visiblePhotoCount: Int?
    typealias NearPhotoQuery = @MainActor (PhotoViewportSnapshot, @MainActor ([PhotoAssetRecord]) -> Void) async throws -> ViewportPhotoBatch
    private var nearPhotoQuery: NearPhotoQuery?
    var displayedCamera: GlobeCameraState { nativeCameraFeedback.resolved(camera) }
    @Published private(set) var overviewFraming = 1.0
    @Published private(set) var zoomDirection = 0
    enum ZoomBoundary { case regional, global }
    @Published private(set) var zoomBoundary: ZoomBoundary?
    private var zoomBoundaryTask: Task<Void, Never>?
    private var lastZoomBoundaryTimestamp = -Double.infinity
    private var framingTransition: GlobeFramingTransition?
    private var suspendedFramingTarget: Double?
    private var resumeFramingOnSceneActivation = false
    @Published private(set) var isManipulating = false
    @Published private(set) var isRefreshingPhotos = false
    @Published private(set) var visiblePhotos: [PhotoAssetRecord] = []
    @Published private(set) var photoBatchReady = false
    @Published private(set) var photoQueryFailed = false
    @Published private(set) var settleRevision = 0
    @Published private(set) var cameraTransitionRevision = 0
    @Published private(set) var latestViewport: EarthViewport?
    @Published private(set) var supportsTouchPan = false
    @Published private(set) var remoteSymbolNames = SiriRemoteSymbolNames()

    enum SelectInputSource { case hardware, uiKit }

    private var remoteInput: SiriRemoteInputController?
    private var selectGesture = RemoteSelectGestureRecognizer()
    private var selectIsPressed = false
    private var selectInputSource: SelectInputSource?
    private var lastSelectInputTimestamp = -Double.infinity
    private var touchOwnedByPress = false
    private var hardwareOwnsDirections = false
    private var onSelectAction: ((RemoteSelectGestureRecognizer.Action) -> Void)?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: GlobeDisplayLinkProxy?
    private var directionalInput = CGVector.zero
    private var longitudeMotion = GlobeDampedAxis()
    private var latitudeMotion = GlobeDampedAxis()
    // Integrate valid contact samples into an unpublished target. Display frames
    // consume its latest value once, so a busy frame never discards finger travel
    // or changes the latitude-dependent gain by regrouping the same samples.
    private var pendingTouchCamera: GlobeCameraState?
    private var pendingSurfaceOrigin: GlobeCameraState?
    private var pendingNudge = CGVector.zero
    private var directionalHoldElapsed = 0.0
    private var isSurfaceTouching = false
    private var isTouchPanning = false
    private var lastSurfaceContactTimestamp = -Double.infinity
    private var cameraFlight: GlobeCameraFlight?
    private enum CityFlightPhase {
        case turning(landing: GlobeCameraState)
        case descending
    }
    @Published private var cityFlightPhase: CityFlightPhase?
    var isApproachingCity: Bool { cityFlightPhase != nil }
    var pendingCityLanding: GlobeCameraState? {
        guard case .turning(let landing) = cityFlightPhase else { return nil }
        return landing
    }
    private static let cityDescentDuration = 2.5
    private var cityOrbitDeadline: CFTimeInterval?
    var regionalBasemapTarget: GlobeCameraState? {
        guard let target = pendingCityLanding ?? cameraFlight?.destination else { return nil }
        if isApproachingCity {
            return GlobeCameraState(center: target.center, distance: GlobeCameraState.regionalDistance)
        }
        return target.distance == GlobeCameraState.regionalDistance ? target : nil
    }
    private var wantsDirectManipulation = false
    private var zoomControlsPresented = false
    private var isSceneActive = true
    private var lastFrameTimestamp: CFTimeInterval?
    private var homeDriftPhase = 0.0
    private var hasConfiguredInitialCamera = false
    private var photoQuery: ((EarthViewport, Int) async throws -> [PhotoAssetRecord])?
    private var photoQueryGeneration: UInt64 = 0
    private var queryTask: Task<Void, Never>?
    private var latestViewportCameraDistance: Double?
    private var latestViewportCamera: GlobeCameraState?
    private var lastQueriedViewport: EarthViewport?
    private var cachedPhotoCandidates: [PhotoAssetRecord] = []
    private var lastTouchInputTimestamp: CFTimeInterval = 0
    private var lastDirectionalInputTimestamp: CFTimeInterval = 0

    var currentViewport: EarthViewport {
        let camera = displayedCamera
        if let latestViewport, latestViewportCamera == camera { return latestViewport }
        let fallbackRadius = 55 * camera.navigationScale
        let visibility = EarthSurfaceVisibility(
            center: camera.center, distance: camera.distance, pitch: camera.presentationPitch, heading: 0
        )
        let horizon = MapEarthGeometry.surfaceVisibilityRadius(
            distance: camera.distance, pitch: camera.presentationPitch
        )
        guard let latestViewport, let latestViewportCameraDistance else {
            return EarthViewport(
                center: camera.center, angularRadius: min(fallbackRadius, horizon), visibilityCap: visibility
            )
        }
        return EarthViewport(
            center: camera.center,
            angularRadius: min(
                latestViewport.angularRadius * camera.navigationScale
                    / GlobeCameraState(distance: latestViewportCameraDistance).navigationScale,
                horizon
            ),
            visibilityCap: visibility
        )
    }

    func activate(
        initialCenter: GeoCoordinate?,
        startsAtCity: Bool = false,
        onSelectAction: ((RemoteSelectGestureRecognizer.Action) -> Void)? = nil,
        nearPhotoQuery: NearPhotoQuery? = nil,
        photoQuery: @escaping (EarthViewport, Int) async throws -> [PhotoAssetRecord]
    ) {
        if !hasConfiguredInitialCamera {
            if let initialCenter { camera = GlobeCameraState(center: initialCenter).mapConstrained() }
            overviewFraming = 0
            hasConfiguredInitialCamera = true
        }
        if startsAtCity { presentation.restoreAutomaticStyle() }
        self.nearPhotoQuery = nearPhotoQuery
        self.photoQuery = photoQuery
        self.onSelectAction = onSelectAction
        zoomControlsPresented = false
        wantsDirectManipulation = true
        guard isSceneActive else { return }
        startRemoteInput()
        if cameraFlight != nil {
            startDisplayLink()
        } else {
            settleRevision += 1
        }
    }

    func transitionCamera(
        to center: GeoCoordinate,
        distance: Double,
        animated: Bool = true,
        overviewFraming: Double? = nil,
        duration: Double = 0.9,
        usesGreatCircle: Bool = false
    ) {
        beginFlight(
            to: GlobeCameraState(center: center, distance: distance),
            duration: duration,
            animated: animated,
            framing: overviewFraming,
            usesGreatCircle: usesGreatCircle
        )
    }

    func approachCity(at center: GeoCoordinate, distance: Double, animated: Bool) {
        cityOrbitDeadline = nil
        let origin = displayedCamera
        let landing = GlobeCameraState(center: center, distance: distance).mapConstrained()
        let arc = GlobeMath.angularDistanceDegrees(from: origin.center, to: landing.center)
        if animated, arc > 0.05 {
            // Turn by the shorter longitude arc. Staying between the two
            // latitudes avoids MapKit squeezing a cross-polar flight out of orbit.
            let orbit = GlobeCameraState(center: landing.center, distance: origin.distance)
            beginFlight(to: orbit, duration: 0.55 + 1.65 * min(arc / 150, 1),
                        animated: true, framing: 0, cityPhase: .turning(landing: landing))
            if cameraFlight != nil { return }
        }
        beginFlight(to: landing, duration: Self.cityDescentDuration, animated: animated, framing: 0, cityPhase: .descending)
    }

    /// The offset traces a small arc around the original longitude. Keeping its
    /// phase through visits makes successive returns resume the same arc.
    func advanceHomeDrift(from renderedCamera: GlobeCameraState, elapsed: Double) -> GlobeCameraState? {
        guard elapsed.isFinite, elapsed > 0, camera == renderedCamera, isSceneActive, !wantsDirectManipulation,
              !isManipulating, cameraFlight == nil, !photoWallViewportCapture.isFrozen else { return nil }
        let previous = homeDriftPhase
        let turn = 2 * Double.pi
        let cycleDuration: TimeInterval = 64
        homeDriftPhase = (previous + turn * elapsed / cycleDuration).truncatingRemainder(dividingBy: turn)
        var next = camera
        next.rotate(longitudeDelta: 2.4 * (sin(homeDriftPhase) - sin(previous)), latitudeDelta: 0)
        camera = next
        return next
    }

    /// Explicit zoom controls own the only scale-changing input path.
    func zoomIn() { zoomByStep(-0.34) }
    func zoomOut() { zoomByStep(0.34) }

    var acceptsUIKitSelectPresses: Bool {
        wantsDirectManipulation && isSceneActive && !zoomControlsPresented
    }

    var acceptsTouchPan: Bool {
        wantsDirectManipulation && isSceneActive
    }

    func setTouchPanAvailable(_ available: Bool) {
        if supportsTouchPan != available { supportsTouchPan = available }
    }

    /// The dock owns button navigation while the globe keeps touch ownership.
    /// Changing dock visibility never suspends/restarts the touch lifecycle.
    func setZoomControlsPresented(_ presented: Bool) {
        guard zoomControlsPresented != presented else { return }
        zoomControlsPresented = presented
        cancelSelectPresses()
        clearDirectionalMotion()
    }

    /// A real press owns the rest of this contact, including queued drag input.
    /// UIKit's passive press observer also covers remotes outside Game Controller.
    func claimTouchForPhysicalPress() {
        pendingTouchCamera = nil
        pendingSurfaceOrigin = nil
        isTouchPanning = false
        if isSurfaceTouching { touchOwnedByPress = true }
    }

    func receiveSelectPress(
        _ pressed: Bool, source: SelectInputSource, at timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        guard wantsDirectManipulation, isSceneActive, timestamp.isFinite,
              timestamp >= 0, timestamp >= lastSelectInputTimestamp else { return }
        if zoomControlsPresented {
            if pressed { claimTouchForPhysicalPress() }
            return
        }
        // UIKit and Game Controller can deliver the same physical click in either
        // order. The first down edge owns the entire press sequence.
        // Do not disable UIKit just because a paired remote exposes a button:
        // CEC remotes and the Simulator may deliver their presses only via UIKit.
        if let selectInputSource, selectInputSource != source {
            guard !selectIsPressed, timestamp - lastSelectInputTimestamp > 0.12 else { return }
            self.selectInputSource = nil
        }
        if selectInputSource == nil {
            guard pressed else { return }
            selectInputSource = source
        }
        guard selectIsPressed != pressed else { return }
        lastSelectInputTimestamp = timestamp
        selectIsPressed = pressed
        clearDirectionalMotion()
        if pressed { claimTouchForPhysicalPress() }
        let actions = pressed ? selectGesture.pressBegan(at: timestamp) : selectGesture.pressEnded(at: timestamp)
        dispatchSelectActions(actions)
    }

    func cancelSelectPresses(source: SelectInputSource? = nil) {
        guard source == nil || source == selectInputSource else { return }
        selectGesture.reset()
        selectIsPressed = false
        selectInputSource = nil
    }

    private func dispatchSelectActions(_ actions: [RemoteSelectGestureRecognizer.Action]) {
        for action in actions {
            guard wantsDirectManipulation, isSceneActive, !zoomControlsPresented else { return }
            onSelectAction?(action)
        }
    }

    func capturePhotoWallViewport() -> PhotoViewportSnapshot? {
        let capture = photoWallViewportCapture.freeze()
        pauseDirectManipulation()
        if let capture {
            // Drop a camera state whose SwiftUI update had not yet reached the
            // screen. The renderer holds the captured native projection.
            camera = capture.camera
        }
        return capture?.snapshot
    }

    func pauseDirectManipulation() {
        wantsDirectManipulation = false
        zoomControlsPresented = false
        suspendMotion()
    }

    func resumeDirectManipulation() {
        photoWallViewportCapture.release()
        wantsDirectManipulation = true
        zoomControlsPresented = false
        guard isSceneActive else { return }
        startRemoteInput()
        if overviewFraming != 0 { suspendedFramingTarget = 0 }
        resumeFramingIfNeeded()
        settleRevision += 1
    }

    /// Scene changes preserve the current camera but never carry held keys or
    /// accumulated input across an interruption such as Control Center.
    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        if active {
            if wantsDirectManipulation {
                startRemoteInput()
                settleRevision += 1
            }
            if wantsDirectManipulation || resumeFramingOnSceneActivation {
                resumeFramingIfNeeded()
            }
            resumeFramingOnSceneActivation = false
        } else {
            // A wall/help layer may already have paused presentation. Returning
            // from Control Center must not unfreeze the map behind that layer.
            resumeFramingOnSceneActivation = framingTransition != nil
            presentation.discardPins()
            suspendMotion()
        }
    }

    func refreshPhotos() {
        presentation.discardPins()
        cancelPhotoQuery()
        lastQueriedViewport = nil
        cachedPhotoCandidates.removeAll()
        settleRevision += 1
    }

    func deactivate() {
        photoWallViewportCapture.release()
        wantsDirectManipulation = false
        suspendMotion()
        photoQuery = nil
        nearPhotoQuery = nil
        presentation.discardPins()
        onSelectAction = nil
        lastQueriedViewport = nil
        cachedPhotoCandidates.removeAll()
    }

    func nudge(_ direction: MoveCommandDirection, at now: CFTimeInterval = CACurrentMediaTime()) {
        guard wantsDirectManipulation, isSceneActive, !zoomControlsPresented, !hardwareOwnsDirections,
              !selectIsPressed else { return }
        // Hardware also generates SwiftUI move commands. One physical action
        // must not be applied twice. A swipe can pause before lift, so the last
        // movement timestamp alone cannot suppress its delayed focus command.
        guard now.isFinite, !isSurfaceTouching,
              now - lastSurfaceContactTimestamp > 0.35,
              now - lastTouchInputTimestamp > 0.24,
              now - lastDirectionalInputTimestamp > 0.24 else { return }
        var input = CGVector.zero
        switch direction {
        case .left: input.dx = -1
        case .right: input.dx = 1
        case .up: input.dy = 1
        case .down: input.dy = -1
        @unknown default: return
        }
        clearZoomBoundary()
        setZoomDirection(0)
        pendingNudge.dx += input.dx * 2.5 * rotationScale
        pendingNudge.dy += input.dy * 2.5 * rotationScale
        markInput()
    }

    func receiveViewport(_ snapshot: PhotoViewportSnapshot) {
        guard snapshot.isCurrent() else { return }
        let viewport = snapshot.viewport
        latestViewport = viewport
        latestViewportCameraDistance = displayedCamera.distance
        latestViewportCamera = displayedCamera
        guard wantsDirectManipulation, isSceneActive, !isManipulating else { return }
        let reusesCandidates = !shouldRefreshPhotos(for: viewport)
        cancelPhotoQuery()
        guard let photoQuery else { return }
        let generation = photoQueryGeneration
        let settledCamera = camera
        isRefreshingPhotos = true

        queryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(850))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.photoQueryGeneration == generation,
                  self.camera == settledCamera,
                  !self.isManipulating,
                  self.wantsDirectManipulation,
                  self.isSceneActive else { return }
            guard snapshot.isCurrent() else {
                retryPhotoSnapshot()
                return
            }
            if presentation.scale == .map, let nearPhotoQuery {
                do {
                    let batch = try await nearPhotoQuery(snapshot) { preview in
                        guard !Task.isCancelled, self.photoQueryGeneration == generation,
                              self.camera == settledCamera, self.presentation.scale == .map,
                              snapshot.isCurrent() else { return }
                        self.visiblePhotos = preview
                        self.photoBatchReady = true
                    }
                    guard !Task.isCancelled, photoQueryGeneration == generation,
                          camera == settledCamera, presentation.scale == .map else { return }
                    guard snapshot.isCurrent() else { retryPhotoSnapshot(); return }
                    presentation.publish(batch.clusters)
                    visiblePhotos = batch.preview
                    visiblePhotoCount = batch.count
                    photoBatchReady = true
                    isRefreshingPhotos = false
                    queryTask = nil
                } catch {
                    guard !Task.isCancelled, photoQueryGeneration == generation else { return }
                    guard snapshot.isCurrent() else { retryPhotoSnapshot(); return }
                    cancelPhotoQuery()
                    photoQueryFailed = true
                }
                return
            }
            let candidates: [PhotoAssetRecord]
            if reusesCandidates {
                candidates = cachedPhotoCandidates
            } else {
                do {
                    candidates = Array(try await photoQuery(viewport, MemoryPhotoSelection.candidateLimit)
                        .prefix(MemoryPhotoSelection.candidateLimit))
                } catch {
                    guard !Task.isCancelled, photoQueryGeneration == generation,
                          camera == settledCamera, snapshot.isCurrent() else { return }
                    photoQueryFailed = true
                    isRefreshingPhotos = false
                    queryTask = nil
                    return
                }
            }
            guard !Task.isCancelled, photoQueryGeneration == generation,
                  camera == settledCamera, !isManipulating,
                  wantsDirectManipulation, isSceneActive else { return }
            guard let onScreen = snapshot.visibleCandidates(from: candidates) else {
                retryPhotoSnapshot()
                return
            }
            if !reusesCandidates {
                // Keep the original cache footprint when reusing a nearby view.
                // Otherwise many small moves could drift arbitrarily far while
                // continuing to reuse the very first region's candidates.
                lastQueriedViewport = viewport
                cachedPhotoCandidates = candidates
            }
            // Selection and thumbnail loading happen only after native screen
            // filtering. A sparse view stays sparse; never fill it from offscreen.
            visiblePhotos = PhotoSelection.photos(
                from: onScreen, in: viewport, limit: MemoryPhotoSelection.resultLimit
            )
            photoBatchReady = true
            isRefreshingPhotos = false
            queryTask = nil
        }
    }

    func invalidateNativeProjection(settleRevision expiredRevision: Int) {
        guard expiredRevision == settleRevision, wantsDirectManipulation,
              isSceneActive, !isManipulating else { return }
        cancelPhotoQuery()
        latestViewport = nil
        latestViewportCamera = nil
        latestViewportCameraDistance = nil
        // The normal stationary snapshot path owns the single 850 ms debounce.
        // A new input or an already-expired query makes this receipt obsolete.
        settleRevision += 1
    }

    func updateScale(_ scale: GlobeScale) {
        guard scale != presentation.scale, !photoWallViewportCapture.isFrozen else { return }
        cancelPhotoQuery()
        presentation.enter(scale)
        settleRevision += 1
    }

    func toggleMapStyle() {
        guard !photoWallViewportCapture.isFrozen else { return }
        cancelPhotoQuery()
        latestViewport = nil
        latestViewportCamera = nil
        latestViewportCameraDistance = nil
        presentation.toggleStyle()
        settleRevision += 1
    }

    private func retryPhotoSnapshot() {
        cancelPhotoQuery()
        // Native projection/layout changed without a new input callback. Ask for
        // a fresh settled snapshot instead of presenting an unverified batch.
        settleRevision += 1
    }

    private var rotationScale: Double {
        displayedCamera.navigationScale
    }

    private var hasDirectionalInput: Bool {
        hypot(directionalInput.dx, directionalInput.dy) > 0.05
    }

    private func startRemoteInput() {
        guard remoteInput == nil else { return }
        let input = SiriRemoteInputController()
        input.onCenterPressChanged = { [weak self] pressed in
            self?.receiveSelectPress(pressed, source: .hardware)
        }
        input.onCenterPressCancelled = { [weak self] in self?.cancelSelectPresses(source: .hardware) }
        input.onDirectionalChange = { [weak self] horizontal, vertical in
            self?.setDirectionalInput(horizontal: horizontal, vertical: vertical)
        }
        input.onDirectionalAvailabilityChanged = { [weak self] available in
            self?.receiveDirectionalAvailability(available)
        }
        input.onSymbolNamesChanged = { [weak self] names in
            guard let self, remoteSymbolNames != names else { return }
            remoteSymbolNames = names
        }
        input.start()
        remoteInput = input
    }

    func receiveDirectionalAvailability(_ available: Bool) {
        hardwareOwnsDirections = available
    }

    func receiveTouchContact(_ touching: Bool, at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard wantsDirectManipulation, isSceneActive, timestamp.isFinite,
              touching != isSurfaceTouching else { return }
        isSurfaceTouching = touching
        lastSurfaceContactTimestamp = timestamp
        // Resting a thumb is not manipulation: keep the camera, frame clock,
        // current query and ready photo strip untouched until an accepted drag.
        if !touching {
            if isTouchPanning { clearDirectionalMotion() }
            isTouchPanning = false
            touchOwnedByPress = false
            // Keep the last real sample for the next display frame. There is no
            // velocity or extra animation to play after that sample is applied.
        }
    }

    func setDirectionalInput(horizontal: Double, vertical: Double) {
        guard wantsDirectManipulation, isSceneActive, !selectIsPressed,
              horizontal.isFinite, vertical.isFinite else { return }
        if zoomControlsPresented {
            if hypot(horizontal, vertical) > 0.05 { claimTouchForPhysicalPress() }
            return
        }
        let wasPressing = hasDirectionalInput
        let previousDirection = directionalInput
        let magnitude = hypot(horizontal, vertical)
        let normalization = max(magnitude, 1)
        let isInDeadZone = magnitude < (wasPressing ? 0.06 : 0.12)
        directionalInput = isInDeadZone ? .zero
            : CGVector(dx: horizontal / normalization, dy: vertical / normalization)
        lastDirectionalInputTimestamp = CACurrentMediaTime()
        if hasDirectionalInput {
            touchOwnedByPress = isSurfaceTouching
            clearZoomBoundary()
            setZoomDirection(0)
            isTouchPanning = false
            if !wasPressing || directionalInput != previousDirection {
                directionalHoldElapsed = 0
                longitudeMotion.velocity = 0
                latitudeMotion.velocity = 0
                pendingNudge.dx += directionalInput.dx * 2.5 * rotationScale
                pendingNudge.dy += directionalInput.dy * 2.5 * rotationScale
            }
            pendingTouchCamera = nil
            pendingSurfaceOrigin = nil
            markInput()
        } else {
            // A queued deliberate tap is applied once on the next frame. A
            // released hold contributes no extra velocity or completion tail.
            directionalHoldElapsed = 0
            longitudeMotion.velocity = 0
            latitudeMotion.velocity = 0
        }
    }

    func applyTouchPan(
        horizontalDelta: Double, verticalDelta: Double, at timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        guard wantsDirectManipulation, isSceneActive, !touchOwnedByPress,
              !hasDirectionalInput, horizontalDelta.isFinite, verticalDelta.isFinite,
              horizontalDelta != 0 || verticalDelta != 0 else { return }
        guard !selectIsPressed else { return }
        clearZoomBoundary()
        setZoomDirection(0)
        var target = pendingTouchCamera.map { rebasePendingSurface($0) } ?? displayedCamera
        let scale = target.navigationScale
        target.panWithTouchSurface(
            horizontalDelta: horizontalDelta, verticalDelta: verticalDelta,
            sensitivity: 84 * scale, verticalSensitivity: 36.48 * scale
        )
        target = nativeCameraFeedback.constrained(target.mapPanConstrained())
        pendingTouchCamera = target
        pendingSurfaceOrigin = displayedCamera
        isTouchPanning = true
        // Grabbing the map also consumes queued direction taps, including taps
        // that arrived between frames. They must not reappear as a post-swipe kick.
        clearDirectionalMotion()
        lastTouchInputTimestamp = timestamp
        markInput()
    }

    private func zoomByStep(_ delta: Double) {
        guard isSceneActive else { return }
        let origin = displayedCamera
        var destination = origin
        var initialLogarithmicVelocity = 0.0
        // Only repeated clicks in the same direction accumulate scale. A reverse
        // click starts at the visible camera, as does interruption of a flight
        // to another place; neither should unwind an invisible destination first.
        if let flight = cameraFlight,
           flight.origin.center == flight.destination.center,
           flight.destination.center == origin.center,
           (flight.destination.distance - origin.distance) * delta > 0 {
            destination.distance = flight.destination.distance
            initialLogarithmicVelocity = flight.logarithmicVelocity
        }
        destination.zoom(logarithmicDelta: delta)
        destination = nativeCameraFeedback.constrained(destination)
        let direction = delta < 0 ? -1 : 1
        guard !destination.isApproximatelyEqual(to: origin) else {
            showZoomBoundary(for: direction)
            return
        }
        // A second click at the same destination must not restart and prolong
        // the last few frames of an approach to the zoom boundary.
        if cameraFlight?.destination == destination { return }
        beginFlight(to: destination, duration: 0.32, animated: true,
                    initialLogarithmicVelocity: initialLogarithmicVelocity)
        if cameraFlight != nil {
            setZoomDirection(direction)
        } else {
            // Reduce Motion applies the destination synchronously and pauses the
            // frame clock, so it must finish feedback without waiting for a tick.
            showZoomBoundary(for: direction)
        }
    }

    private func beginFlight(
        to destination: GlobeCameraState, duration: Double, animated: Bool, framing: Double? = nil,
        initialLogarithmicVelocity: Double = 0,
        usesGreatCircle: Bool = false, cityPhase: CityFlightPhase? = nil
    ) {
        let origin = displayedCamera
        let destination = nativeCameraFeedback.constrained(destination)
        if cityFlightPhase != nil { cityFlightPhase = nil }
        resetInput()
        suspendedFramingTarget = nil
        let targetFraming = framing ?? framingTransition?.destination ?? overviewFraming
        framingTransition = nil
        cameraFlight = nil
        cancelPhotoQuery()
        hasConfiguredInitialCamera = true
        if animated, isSceneActive, !UIAccessibility.isReduceMotionEnabled,
           origin != destination || overviewFraming != targetFraming {
            if overviewFraming != targetFraming {
                framingTransition = GlobeFramingTransition(
                    origin: overviewFraming, destination: targetFraming, duration: duration
                )
            }
            if let cityPhase { cityFlightPhase = cityPhase }
            cameraFlight = GlobeCameraFlight(
                origin: origin, destination: destination, duration: duration,
                initialLogarithmicVelocity: initialLogarithmicVelocity,
                usesGreatCircle: usesGreatCircle
            )
            if !isManipulating { isManipulating = true }
            cameraTransitionRevision += 1
            startDisplayLink()
        } else {
            if camera != destination { camera = destination }
            overviewFraming = targetFraming
            isManipulating = false
            settleRevision += 1
            displayLink?.isPaused = true
            lastFrameTimestamp = nil
        }
    }

    private func setZoomDirection(_ direction: Int) {
        // Touch callbacks may exceed the camera frame rate. Publish only a mode
        // change; the repeated samples must not invalidate SwiftUI's map subtree.
        if zoomDirection != direction { zoomDirection = direction }
    }

    private func boundary(for direction: Int, at camera: GlobeCameraState) -> ZoomBoundary? {
        var candidate = camera
        candidate.zoom(logarithmicDelta: direction < 0 ? -0.01 : 0.01)
        candidate = nativeCameraFeedback.constrained(candidate)
        if candidate.isApproximatelyEqual(to: camera) { return direction < 0 ? .regional : .global }
        return nil
    }

    private func showZoomBoundary(for direction: Int) {
        guard let boundary = boundary(for: direction, at: displayedCamera) else { return }
        setZoomDirection(0)
        if zoomBoundary != boundary { zoomBoundary = boundary }
        lastZoomBoundaryTimestamp = CACurrentMediaTime()
        // One timer per visible hint, not one task per raw clickpad callback.
        guard zoomBoundaryTask == nil else { return }
        zoomBoundaryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = self.map { max(0, 1.4 - (CACurrentMediaTime() - $0.lastZoomBoundaryTimestamp)) } ?? 0
                guard delay > 0 else { break }
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            zoomBoundary = nil
            zoomBoundaryTask = nil
        }
    }

    private func clearZoomBoundary() {
        zoomBoundaryTask?.cancel()
        zoomBoundaryTask = nil
        if zoomBoundary != nil { zoomBoundary = nil }
    }

    private func markInput() {
        cameraFlight = nil
        if cityFlightPhase != nil { cityFlightPhase = nil }
        if !isManipulating {
            isManipulating = true
            // No settled query can start again until this gesture ends.
            cancelPhotoQuery()
        }
        startDisplayLink()
    }

    private func cancelPhotoQuery() {
        photoQueryGeneration &+= 1
        queryTask?.cancel()
        queryTask = nil
        if photoQueryFailed { photoQueryFailed = false }
        if visiblePhotoCount != nil { visiblePhotoCount = nil }
        if photoBatchReady { photoBatchReady = false }
        if !visiblePhotos.isEmpty { visiblePhotos = [] }
        if isRefreshingPhotos { isRefreshingPhotos = false }
    }

    private func clearDirectionalMotion() {
        directionalInput = .zero
        longitudeMotion.velocity = 0
        latitudeMotion.velocity = 0
        pendingNudge = .zero
        directionalHoldElapsed = 0
    }

    private func resetInput() {
        clearDirectionalMotion()
        clearZoomBoundary()
        pendingTouchCamera = nil
        pendingSurfaceOrigin = nil
        isTouchPanning = false
        setZoomDirection(0)
    }

    private func resumeFramingIfNeeded() {
        guard let target = suspendedFramingTarget else { return }
        suspendedFramingTarget = nil
        guard overviewFraming != target else { return }
        beginFlight(to: camera, duration: 0.35, animated: true, framing: target)
    }

    private func suspendMotion() {
        cancelSelectPresses()
        suspendedFramingTarget = framingTransition?.destination ?? suspendedFramingTarget
        remoteInput?.stop()
        remoteInput = nil
        resetInput()
        isSurfaceTouching = false
        touchOwnedByPress = false
        hardwareOwnsDirections = false
        cameraFlight = nil
        if cityFlightPhase != nil { cityFlightPhase = nil }
        framingTransition = nil
        isManipulating = false
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        lastFrameTimestamp = nil
        cancelPhotoQuery()
    }

    private func startDisplayLink() {
        guard isSceneActive else { return }
        if let displayLink {
            if displayLink.isPaused {
                lastFrameTimestamp = nil
                displayLink.isPaused = false
            }
            return
        }
        let proxy = GlobeDisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(GlobeDisplayLinkProxy.step(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
        lastFrameTimestamp = nil
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        let previousTimestamp = lastFrameTimestamp ?? displayLink.timestamp - 1.0 / 30.0
        let deltaTime = min(max(displayLink.timestamp - previousTimestamp, 0), 1.0 / 15.0)
        lastFrameTimestamp = displayLink.timestamp
        guard deltaTime > 0, isSceneActive else { return }
        advanceMotionFrame(elapsed: deltaTime, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    /// The frame boundary is deterministic so short physical presses and reduced
    /// motion can be verified without synthetic Game Controller hardware.
    func advanceMotionFrame(elapsed deltaTime: Double, reduceMotion: Bool) {
        guard deltaTime.isFinite, deltaTime > 0, isSceneActive else { return }

        if var framing = framingTransition {
            overviewFraming = reduceMotion ? framing.destination : framing.advance(by: deltaTime)
            framingTransition = framing.isComplete || reduceMotion ? nil : framing
        }

        if var flight = cameraFlight {
            let actual = displayedCamera
            if actual != camera {
                let destination = nativeCameraFeedback.constrained(flight.destination)
                if actual.isApproximatelyEqual(to: destination), framingTransition == nil {
                    if camera != actual { camera = actual }
                    finishFlight(reduceMotion: reduceMotion)
                    return
                }
                flight = GlobeCameraFlight(
                    origin: actual, destination: destination,
                    duration: max(0, flight.duration - flight.elapsed),
                    initialLogarithmicVelocity: flight.logarithmicVelocity,
                    usesGreatCircle: flight.usesGreatCircle
                )
            }
            let nextCamera = nativeCameraFeedback.constrained(
                reduceMotion ? flight.destination : flight.advance(by: deltaTime)
            )
            if nextCamera != camera { camera = nextCamera }
            if flight.isComplete || reduceMotion {
                cameraFlight = flight
                finishFlight(reduceMotion: reduceMotion)
            } else {
                cameraFlight = flight
            }
            return
        }

        var nextCamera = displayedCamera
        // One initial step per physical press, then continuous movement only
        // after a deliberate hold. Releasing the key clears both axes immediately.
        let previousHold = directionalHoldElapsed
        if hasDirectionalInput { directionalHoldElapsed += deltaTime }
        let movementInterval = hasDirectionalInput
            ? max(0, directionalHoldElapsed - 0.18) - max(0, previousHold - 0.18) : 0
        let targetSpeed = 38.0 * rotationScale
        let longitudeDelta: Double
        let latitudeDelta: Double
        if reduceMotion {
            longitudeMotion.velocity = 0
            latitudeMotion.velocity = 0
            longitudeDelta = directionalInput.dx * targetSpeed * movementInterval
            latitudeDelta = directionalInput.dy * targetSpeed * movementInterval
        } else {
            longitudeDelta = longitudeMotion.advance(
                toward: directionalInput.dx * targetSpeed, response: 10, elapsed: movementInterval
            )
            latitudeDelta = latitudeMotion.advance(
                toward: directionalInput.dy * targetSpeed, response: 10, elapsed: movementInterval
            )
        }
        nextCamera.translateSurface(
            eastDegrees: longitudeDelta + pendingNudge.dx,
            northDegrees: latitudeDelta + pendingNudge.dy
        )
        nextCamera = nextCamera.mapPanConstrained()
        if let pendingTouchCamera { nextCamera = rebasePendingSurface(pendingTouchCamera) }
        nextCamera = nativeCameraFeedback.constrained(nextCamera)
        pendingNudge = .zero
        pendingTouchCamera = nil
        pendingSurfaceOrigin = nil

        // Exactly one publication per display frame, regardless of how many
        // physical input callbacks arrived or which input modes were combined.
        if nextCamera != camera { camera = nextCamera }
        if abs(latitudeMotion.velocity) < 0.18 * rotationScale
            || abs(camera.center.latitude) >= MapCameraConstraints.maximumLatitude {
            latitudeMotion.velocity = 0
        }
        if abs(longitudeMotion.velocity) < 0.18 * rotationScale { longitudeMotion.velocity = 0 }

        if !hasDirectionalInput, !isTouchPanning, framingTransition == nil {
            finishMotion()
        }
    }

    private func rebasePendingSurface(_ target: GlobeCameraState) -> GlobeCameraState {
        guard let origin = pendingSurfaceOrigin else { return target }
        let actual = displayedCamera
        guard origin != actual else { return target }
        var rebased = actual
        rebased.rotate(longitudeDelta: GlobeCameraState.normalizedLongitude(target.center.longitude - origin.center.longitude),
                       latitudeDelta: target.center.latitude - origin.center.latitude)
        if target.distance < origin.distance {
            // Pan's polar envelope is an absolute limit, not a user zoom ratio.
            rebased.distance = min(actual.distance, target.distance)
        }
        return nativeCameraFeedback.constrained(rebased)
    }

    private func finishFlight(reduceMotion: Bool) {
        if let landing = pendingCityLanding {
            // Let the live satellite renderer finish the orbital view before
            // asking it to load finer zoom levels. Input still interrupts the flight.
            if !reduceMotion, nativeCameraFeedback.requested != nil,
               nativeCameraFeedback.renderedSatelliteCamera != camera {
                let now = CACurrentMediaTime()
                if cityOrbitDeadline == nil { cityOrbitDeadline = now + 0.85 }
                if let cityOrbitDeadline, now < cityOrbitDeadline { return }
            }
            beginFlight(to: landing, duration: Self.cityDescentDuration, animated: !reduceMotion, framing: 0, cityPhase: .descending)
            return
        }
        cameraFlight = nil
        if cityFlightPhase != nil { cityFlightPhase = nil }
        showZoomBoundary(for: zoomDirection)
        finishMotion()
    }

    private func finishMotion() {
        setZoomDirection(0)
        if isManipulating {
            isManipulating = false
            settleRevision += 1
        }
        displayLink?.isPaused = true
        lastFrameTimestamp = nil
    }

    private func shouldRefreshPhotos(for viewport: EarthViewport) -> Bool {
        guard let lastQueriedViewport else { return true }
        return viewport.differsMeaningfully(from: lastQueriedViewport)
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
