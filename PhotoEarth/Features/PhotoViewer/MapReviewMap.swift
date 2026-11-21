import SwiftUI
import MapKit
import Combine

struct MapReviewPin: Identifiable {
    let clusters: [MapReviewCluster]
    let point: CGPoint
    var id: String { clusters.map(\.id).sorted().joined(separator: "|") }
    var count: Int { clusters.reduce(0) { $0 + $1.count } }
    var assetID: String? { clusters.compactMap(\.assetID).first }
}

/// A settled grouping has a geographic anchor and stable photo identity.
/// Movement only reprojects these at most 32 anchors; it never reclusters or
/// requests new thumbnails until the next complete viewport query is ready.
struct MapReviewPinAnchor: Hashable {
    let clusters: [MapReviewCluster]
    let coordinate: GeoCoordinate
}

@MainActor final class MapReviewCamera: NSObject, ObservableObject, MKMapViewDelegate {
    let map = MKMapView(frame: .zero)
    @Published private(set) var grid: MapReviewGrid?
    @Published private(set) var revision = 0
    private(set) var snapshot: PhotoViewportSnapshot?
    @Published private(set) var supportsTouchPan = false
    @Published private(set) var remoteSymbolNames = SiriRemoteSymbolNames()
    var onSelect: (() -> Void)?
    private var controlsPresented = false
    private var selectGesture = RemoteSelectGestureRecognizer()
    private var selectSource: GlobeExperienceModel.SelectInputSource?
    private var selectPressed = false
    private var touchOwnedByPress = false
    @Published private(set) var style: PhotoMapStyle = .standard
    private var displayLink: CADisplayLink?
    private var pendingPan = CGPoint.zero
    private var publication: Task<Void, Never>?
    private var isStopped = false
    private var remoteInput: SiriRemoteInputController?
    private var hardwareOwnsDirections = false
    private var heldDirection = CGPoint.zero
    private var directionStartedAt = 0.0
    private var isTouching = false
    private var lastContactAt = -Double.infinity
    private lazy var photoPins = PhotoPinRenderer(map: map)

    override init() {
        super.init()
        map.preferredConfiguration = PhotoMapStyle.standard.configuration(realisticTerrain: false)
        map.overrideUserInterfaceStyle = .dark
        map.backgroundColor = .black
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.showsScale = false
        map.insetsLayoutMarginsFromSafeArea = false
        map.delegate = self
        map.layoutMargins = FullScreenMapLayout.margins
    }

    func toggleStyle() {
        let currentCamera = map.camera.copy() as! MKMapCamera
        invalidateViewport()
        style = style.toggled
        map.preferredConfiguration = style.configuration(realisticTerrain: false)
        map.setCamera(currentCamera, animated: false)
        publishGrid()
    }

    func start() {
        isStopped = false
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        if grid == nil { publishGrid() }
    }

    func stop() {
        isStopped = true
        displayLink?.invalidate(); displayLink = nil
        pendingPan = .zero
        endMovingInput()
        publication?.cancel()
    }

    func beginMovingInput() {
        guard remoteInput == nil else { return }
        let input = SiriRemoteInputController()
        input.onDirectionalAvailabilityChanged = { [weak self] in self?.hardwareOwnsDirections = $0 }
        input.onDirectionalChange = { [weak self] horizontal, vertical in
            guard let self else { return }
            guard !controlsPresented else { heldDirection = .zero; return }
            if horizontal != 0 || vertical != 0 { claimTouchForPhysicalPress() }
            let wasReleased = heldDirection == .zero
            heldDirection = CGPoint(x: horizontal, y: vertical)
            discardPendingPan()
            if wasReleased, heldDirection != .zero {
                directionStartedAt = CACurrentMediaTime()
                nudge(abs(horizontal) >= abs(vertical) ? (horizontal < 0 ? .left : .right) : (vertical > 0 ? .up : .down))
            }
        }
        input.onCenterPressChanged = { [weak self] in self?.receiveSelectPress($0, source: .hardware) }
        input.onCenterPressCancelled = { [weak self] in self?.cancelSelectPresses() }
        input.onSymbolNamesChanged = { [weak self] in self?.remoteSymbolNames = $0 }
        remoteInput = input
        input.start()
    }

    func endMovingInput() {
        remoteInput?.stop(); remoteInput = nil
        hardwareOwnsDirections = false; heldDirection = .zero
        discardPendingPan(republish: displayLink != nil)
        isTouching = false; touchOwnedByPress = false
        cancelSelectPresses()
    }

    func touchContact(_ touching: Bool) {
        isTouching = touching; lastContactAt = CACurrentMediaTime()
        if !touching { discardPendingPan(); touchOwnedByPress = false }
    }

    func fallbackNudge(_ direction: MoveCommandDirection) {
        // UIKit owns touch lifecycle. This delay suppresses a Focus command
        // generated by the completed swipe, never infers whether contact ended.
        guard !controlsPresented, !hardwareOwnsDirections, !isTouching, CACurrentMediaTime() - lastContactAt > 0.35 else { return }
        nudge(direction)
    }

    func fit(_ cluster: MapReviewCluster, animated: Bool) {
        let worldWidth = MKMapRect.world.size.width
        let minX = (cluster.west + 180) / 360 * worldWidth
        let maxX = (cluster.east + 180) / 360 * worldWidth
        let minY = MKMapPoint(CLLocationCoordinate2D(latitude: min(85, cluster.north), longitude: 0)).y
        let maxY = MKMapPoint(CLLocationCoordinate2D(latitude: max(-85, cluster.south), longitude: 0)).y
        let minimumSize = worldWidth * 0.008 / 360
        let width = max(minimumSize, maxX - minX), height = max(minimumSize, maxY - minY)
        let rect = MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 240, left: 140, bottom: 320, right: 140), animated: animated)
        publishGrid()
    }

    func show(center: GeoCoordinate, distance: Double) {
        invalidateViewport()
        map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                                  fromDistance: max(100, min(42_000_000, distance)), pitch: 0, heading: 0), animated: false)
        publishGrid()
    }

    func center(on coordinate: GeoCoordinate, animated: Bool) {
        let camera = map.camera.copy() as! MKMapCamera
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        camera.pitch = 0; camera.heading = 0
        invalidateViewport()
        map.setCamera(camera, animated: animated)
        publishGrid()
    }

    func zoom(inward: Bool, animated: Bool) {
        let camera = map.camera.copy() as! MKMapCamera
        camera.centerCoordinateDistance = max(100, min(42_000_000, camera.centerCoordinateDistance * exp(inward ? -0.34 : 0.34)))
        camera.pitch = 0; camera.heading = 0
        invalidateViewport()
        map.setCamera(camera, animated: animated)
        publishGrid()
    }

    func nudge(_ direction: MoveCommandDirection) {
        let span = map.region.span
        let center = map.centerCoordinate
        var latitude = center.latitude
        var longitude = center.longitude
        switch direction {
        case .left: longitude -= span.longitudeDelta * 0.035
        case .right: longitude += span.longitudeDelta * 0.035
        case .up: latitude += span.latitudeDelta * 0.035
        case .down: latitude -= span.latitudeDelta * 0.035
        default: return
        }
        self.center(on: GeoCoordinate(latitude: max(-85, min(85, latitude)),
                                      longitude: MapReviewGrid.normalizedLongitude(longitude)), animated: false)
    }

    func pan(dx: Double, dy: Double) {
        guard !isStopped, !touchOwnedByPress, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        invalidateViewport()
        pendingPan.x += dx; pendingPan.y += dy
    }

    /// A drag invalidates the old projection before the display frame moves
    /// the camera. Releasing or handing off input can discard that frame, so
    /// explicitly resample the stationary map without replaying its movement.
    private func discardPendingPan(republish: Bool = true) {
        pendingPan = .zero
        if republish, grid == nil { publishGrid() }
    }

    @objc private func tick() {
        var delta = pendingPan; pendingPan = .zero
        if !controlsPresented, heldDirection != .zero, CACurrentMediaTime() - directionStartedAt >= 0.18 {
            let gain = min(1, (CACurrentMediaTime() - directionStartedAt - 0.18) / 0.3)
            delta.x -= heldDirection.x * 0.028 * gain
            delta.y += heldDirection.y * 0.028 * gain
        }
        guard delta != .zero else { return }
        let region = map.region
        // UIKit downward motion is positive; move the geographic surface with
        // the finger. Physical arrow commands above retain camera semantics.
        center(on: GeoCoordinate(latitude: max(-85, min(85, region.center.latitude + delta.y * region.span.latitudeDelta * 0.5)),
                                 longitude: MapReviewGrid.normalizedLongitude(region.center.longitude - delta.x * region.span.longitudeDelta * 0.5)),
               animated: false)
    }

    func setControlsPresented(_ presented: Bool) {
        controlsPresented = presented
        heldDirection = .zero; discardPendingPan()
        cancelSelectPresses()
    }

    func setTouchPanAvailable(_ available: Bool) { supportsTouchPan = available }

    func claimTouchForPhysicalPress() {
        discardPendingPan()
        if isTouching { touchOwnedByPress = true }
    }

    func receiveSelectPress(_ pressed: Bool, source: GlobeExperienceModel.SelectInputSource) {
        guard remoteInput != nil, !controlsPresented else { return }
        if let selectSource, selectSource != source { return }
        if selectSource == nil {
            guard pressed else { return }
            selectSource = source
        }
        guard selectPressed != pressed else { return }
        selectPressed = pressed
        heldDirection = .zero
        if pressed { claimTouchForPhysicalPress() }
        let now = CACurrentMediaTime()
        let actions = pressed ? selectGesture.pressBegan(at: now) : selectGesture.pressEnded(at: now)
        if !actions.isEmpty { onSelect?() }
    }

    func cancelSelectPresses() {
        selectGesture.reset(); selectPressed = false; selectSource = nil
    }

    func invalidateViewport() {
        publication?.cancel()
        if grid != nil { grid = nil; snapshot = nil; revision += 1 }
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        guard !isStopped else { return }
        publication?.cancel()
        publication = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.invalidateViewport()
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { publishGrid() }

    func publishGrid() {
        guard !isStopped else { return }
        publication?.cancel()
        publication = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            guard !Task.isCancelled, let self, let snapshot = MapViewportSampler.photoSnapshot(in: map) else { return }
            grid = MapReviewGrid(viewport: snapshot.viewport, size: map.bounds.size)
            self.snapshot = snapshot
            revision += 1
        }
    }

    func point(_ coordinate: GeoCoordinate) -> CGPoint? { photoPins.point(coordinate) }
    func pins(_ clusters: [MapReviewCluster]) -> [MapReviewPin] { photoPins.pins(clusters) }
    func pinAnchors(_ clusters: [MapReviewCluster]) -> [MapReviewPinAnchor] { photoPins.pinAnchors(clusters) }
    func projectedPins(_ anchors: [MapReviewPinAnchor]) -> [MapReviewPin] { photoPins.projectedPins(anchors) }
    func displayPins(_ anchors: [MapReviewPinAnchor], isActive: Bool) { photoPins.displayPins(anchors, isActive: isActive) }
    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        photoPins.view(for: annotation)
    }

}

struct MapReviewMap: UIViewRepresentable {
    let camera: MapReviewCamera
    let anchors: [MapReviewPinAnchor]
    let isActive: Bool
    func makeUIView(context: Context) -> MKMapView { camera.map }
    func updateUIView(_ view: MKMapView, context: Context) { camera.displayPins(anchors, isActive: isActive) }
    static func dismantleUIView(_ view: MKMapView, coordinator: ()) { view.delegate = nil }
}

/// MapKit owns placement, clipping and camera animation in its own coordinate
/// space. No SwiftUI timer or screen-to-GPS round trip drives these views.
@MainActor final class MapReviewPhotoAnnotation: NSObject, MKAnnotation {
    private(set) var anchor: MapReviewPinAnchor
    private(set) var isActive: Bool
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    var pin: MapReviewPin { MapReviewPin(clusters: anchor.clusters, point: .zero) }

    init(anchor: MapReviewPinAnchor, isActive: Bool) {
        self.anchor = anchor; self.isActive = isActive
        coordinate = CLLocationCoordinate2D(latitude: anchor.coordinate.latitude, longitude: anchor.coordinate.longitude)
        super.init()
    }

    func update(_ anchor: MapReviewPinAnchor, isActive: Bool) {
        self.isActive = isActive
        if self.anchor.coordinate != anchor.coordinate { coordinate = CLLocationCoordinate2D(latitude: anchor.coordinate.latitude, longitude: anchor.coordinate.longitude) }
        self.anchor = anchor
    }
}

@MainActor final class MapReviewPhotoAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "map-review-photographic-pin"
    private let host = UIHostingController(rootView: MapReviewPinContent(assetID: nil, count: 0, isActive: false))
    override var canBecomeFocused: Bool { false }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 70, height: 70)
        canShowCallout = false; isUserInteractionEnabled = false
        displayPriority = .required
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.7; layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        isAccessibilityElement = true; accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ annotation: MapReviewPhotoAnnotation) {
        let pin = annotation.pin
        host.rootView = MapReviewPinContent(assetID: pin.assetID, count: pin.count, isActive: annotation.isActive)
        isHidden = !annotation.isActive
        accessibilityLabel = AppLocalization.photoCount(pin.count)
        accessibilityIdentifier = "map-review-pin-\(pin.id)"
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let annotation = annotation as? MapReviewPhotoAnnotation { configure(annotation) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        host.rootView = MapReviewPinContent(assetID: nil, count: 0, isActive: false)
        accessibilityIdentifier = nil; accessibilityLabel = nil
    }
}

private struct MapReviewPinContent: View {
    let assetID: String?
    let count: Int
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let assetID { PhotoAssetImage(assetID: assetID, targetSize: CGSize(width: 240, height: 240), isActive: isActive) }
                else { Image(systemName: "photo").foregroundStyle(.white) }
            }
            .frame(width: 70, height: 70).clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            if count > 1 {
                Text(AppLocalization.number(count)).font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .floatingSurface(in: Capsule())
                    .offset(x: 10, y: 5)
            }
        }
        .frame(width: 70, height: 70)
        .transaction { $0.animation = nil }
    }
}
