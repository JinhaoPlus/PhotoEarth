import MapKit
import SwiftUI

/// The detail button owns focus and hit testing; its geographic preview is decorative.
struct PhotoLocationGlobe: View {
    let destination: PhotoGlobeDestination
    let placeTitle: String?
    var isFocused = false
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            PhotoLocationMap(destination: destination, style: .detail)
                .frame(width: 208, height: 152)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(isFocused ? 0.95 : 0.2), lineWidth: isFocused ? 3 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
                .shadow(color: .black.opacity(0.65), radius: 24, y: 10)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(placeTitle.map {
            AppLocalization.format("detail.explore_accessibility", defaultValue: "Explore the globe from %@", $0)
        } ?? AppLocalization.string("detail.explore_from_here", defaultValue: "Explore the Globe from Here"))
        .accessibilityHint(AppLocalization.string("detail.explore_hint", defaultValue: "Opens the full-screen globe at the capture location."))
        .accessibilityIdentifier("photo-location-globe")
    }
}

struct PhotoLocationMap: UIViewRepresentable {
    let destination: PhotoGlobeDestination
    enum Style { case detail, slideshow }
    let style: Style
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> PhotoLocationMapView { PhotoLocationMapView(style: style) }
    func updateUIView(_ view: PhotoLocationMapView, context: Context) {
        view.configure(destination, isVisible: isVisible, allowsMotion: !reduceMotion)
    }
    static func dismantleUIView(_ view: PhotoLocationMapView, coordinator: ()) {
        view.stopFlight()
        view.mapView.delegate = nil
    }
}

/// MapKit can omit annotation views in a newly embedded globe. This single
/// passive light uses its public projection after layout, outside MapKit's
/// annotation culling, and never substitutes a guessed screen coordinate.
final class PhotoLocationMapView: UIView, MKMapViewDelegate {
    let mapView = MKMapView(frame: .zero)
    let locationLight = UIImageView(image: TravelMapAnnotationView.photoImage)
    private var destination: PhotoGlobeDestination?
    private var framedPhoto: (coordinate: GeoCoordinate, camera: GlobeCameraState)?
    private var needsReposition = false
    private var appliedSize = CGSize.zero
    private var isPreviewVisible = true
    private var allowsMotion = false
    private var flight: GlobeCameraFlight?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private let style: PhotoLocationMap.Style

    init(style: PhotoLocationMap.Style) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        mapView.preferredConfiguration = PhotoMapStyle.standard.configuration(realisticTerrain: false)
        mapView.overrideUserInterfaceStyle = .dark
        mapView.backgroundColor = .black
        mapView.isUserInteractionEnabled = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        mapView.delegate = self
        locationLight.isUserInteractionEnabled = false
        locationLight.isAccessibilityElement = false
        locationLight.isHidden = true
        addSubview(mapView)
        addSubview(locationLight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ destination: PhotoGlobeDestination, isVisible: Bool, allowsMotion: Bool) {
        guard self.destination != destination || isPreviewVisible != isVisible || self.allowsMotion != allowsMotion else { return }
        if flight != nil, !isVisible || !allowsMotion {
            stopFlight()
            needsReposition = true
        }
        self.destination = destination
        self.allowsMotion = allowsMotion
        isPreviewVisible = isVisible
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let destination else { return }
        // Fit the whole native map, including its attribution, into the detail button.
        // The GPS light is a sibling and keeps its normal size.
        let scale: CGFloat = style == .detail ? 0.8 : 1
        mapView.transform = CGAffineTransform(scaleX: scale, y: scale)
        mapView.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        mapView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Prepare the first frame immediately. During a chapter title or the
        // controls, hold the previous camera until the inset is visible again.
        if (isPreviewVisible || framedPhoto == nil),
           framedPhoto?.coordinate != destination.coordinate || appliedSize != bounds.size || needsReposition {
            let camera: GlobeCameraState
            if let framedPhoto, framedPhoto.coordinate == destination.coordinate {
                camera = framedPhoto.camera
            } else {
                camera = destination.miniatureCamera(from: framedPhoto?.coordinate)
            }
            let animate = allowsMotion && appliedSize == bounds.size && window != nil
            framedPhoto = (destination.coordinate, camera)
            appliedSize = bounds.size
            needsReposition = false
            moveCamera(to: camera, animated: animate)
        }
        updateLight()
    }

    private func moveCamera(to target: GlobeCameraState, animated: Bool) {
        stopFlight()
        guard animated else { applyCamera(target); return }
        let native = mapView.camera
        let origin = GlobeCameraState(center: GeoCoordinate(latitude: native.centerCoordinate.latitude,
                                                            longitude: native.centerCoordinate.longitude),
                                      distance: native.centerCoordinateDistance)
        // Local moves follow the photo dissolve. Long arcs have a little more
        // time to turn, and can be interrupted at the displayed position.
        let angle = GlobeMath.angularDistanceDegrees(from: origin.center, to: target.center)
        let duration = style == .detail ? 0.32 : 0.72 + 0.65 * min(1, angle / 120)
        flight = GlobeCameraFlight(origin: origin, destination: target, duration: duration, usesGreatCircle: true)
        lastFrameTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(advanceFlight(_:)))
        link.preferredFramesPerSecond = 30
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceFlight(_ link: CADisplayLink) {
        guard var active = flight else { return }
        let now = link.targetTimestamp
        let camera = active.advance(by: max(0, now - lastFrameTime)).mapConstrained()
        lastFrameTime = now
        flight = active
        applyCamera(camera)
        updateLight()
        if active.isComplete { stopFlight() }
    }

    private func applyCamera(_ camera: GlobeCameraState) {
        let center = CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude)
        mapView.setCamera(MKMapCamera(lookingAtCenter: center,
                                     fromDistance: camera.distance, pitch: camera.presentationPitch, heading: 0),
                          animated: false)
    }

    func stopFlight() {
        displayLink?.invalidate()
        displayLink = nil
        flight = nil
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { updateLight() }
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) { updateLight() }

    private func updateLight() {
        guard isPreviewVisible, let destination, bounds.width > 0, bounds.height > 0 else {
            locationLight.isHidden = true
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude)
        let point = mapView.convert(coordinate, toPointTo: self)
        guard point.x.isFinite, point.y.isFinite, bounds.insetBy(dx: 12, dy: 12).contains(point) else {
            locationLight.isHidden = true
            return
        }
        let inverse = mapView.convert(point, toCoordinateFrom: self)
        let roundTrip = GeoCoordinate(latitude: inverse.latitude, longitude: inverse.longitude)
        guard roundTrip.isValid, GlobeMath.angularDistanceDegrees(from: destination.coordinate, to: roundTrip) < 0.01 else {
            locationLight.isHidden = true
            return
        }
        locationLight.center = point
        locationLight.isHidden = false
    }
}
