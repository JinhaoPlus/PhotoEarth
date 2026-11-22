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
            AppLocalization.format("detail.explore_accessibility", defaultValue: "Explore Earth from this memory's location, %@", $0)
        } ?? AppLocalization.string("detail.explore_from_here", defaultValue: "Explore Earth from Here"))
        .accessibilityHint(AppLocalization.string("detail.explore_hint", defaultValue: "Opens the full-screen globe near this memory"))
        .accessibilityIdentifier("photo-location-globe")
    }
}

struct PhotoLocationMap: UIViewRepresentable {
    let destination: PhotoGlobeDestination
    enum Style { case detail, slideshow }
    let style: Style

    func makeUIView(context: Context) -> PhotoLocationMapView { PhotoLocationMapView(style: style) }
    func updateUIView(_ view: PhotoLocationMapView, context: Context) { view.configure(destination) }
    static func dismantleUIView(_ view: PhotoLocationMapView, coordinator: ()) { view.mapView.delegate = nil }
}

/// MapKit can omit annotation views in a newly embedded globe. This single
/// passive light uses its public projection after layout, outside MapKit's
/// annotation culling, and never substitutes a guessed screen coordinate.
final class PhotoLocationMapView: UIView, MKMapViewDelegate {
    let mapView = MKMapView(frame: .zero)
    let locationLight = UIImageView(image: TravelMapAnnotationView.photoImage)
    private var destination: PhotoGlobeDestination?
    private var appliedDestination: PhotoGlobeDestination?
    private var appliedSize = CGSize.zero

    private let style: PhotoLocationMap.Style

    init(style: PhotoLocationMap.Style) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
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

    func configure(_ destination: PhotoGlobeDestination) {
        guard self.destination != destination else { return }
        self.destination = destination
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
        if appliedDestination != destination || appliedSize != bounds.size {
            appliedDestination = destination
            appliedSize = bounds.size
            let camera = style == .detail ? destination.detailPreviewCamera : destination.previewCamera
            mapView.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: camera.center.latitude,
                                                                                longitude: camera.center.longitude),
                                         fromDistance: camera.distance, pitch: camera.presentationPitch, heading: 0), animated: false)
        }
        updateLight()
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { updateLight() }
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) { updateLight() }

    private func updateLight() {
        guard let destination, bounds.width > 0, bounds.height > 0 else { return }
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
