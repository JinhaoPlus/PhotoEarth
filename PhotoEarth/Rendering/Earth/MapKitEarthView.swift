import MapKit
import SwiftUI
import UIKit

struct MapKitEarthView: UIViewRepresentable {
    let places: [TravelPlace]
    let contentRevision: Int
    let camera: GlobeCameraState
    let cameraTransitionRevision: Int
    let isManipulating: Bool
    let showsUserLocation: Bool
    let settleRevision: Int
    let onViewportSettled: (EarthViewport) -> Void
    let onUserLocationUpdate: (GeoCoordinate) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onViewportSettled: onViewportSettled,
            onUserLocationUpdate: onUserLocationUpdate
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isUserInteractionEnabled = false
        mapView.showsScale = false
        mapView.showsUserLocation = showsUserLocation
        mapView.layoutMargins = UIEdgeInsets(top: 42, left: 48, bottom: 238, right: 48)
        mapView.register(
            TravelMapAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: TravelMapAnnotationView.reuseIdentifier
        )
        context.coordinator.update(
            mapView,
            places: places,
            contentRevision: contentRevision,
            camera: camera,
            cameraTransitionRevision: cameraTransitionRevision,
            isManipulating: isManipulating,
            showsUserLocation: showsUserLocation,
            settleRevision: settleRevision,
            onViewportSettled: onViewportSettled,
            onUserLocationUpdate: onUserLocationUpdate
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(
            mapView,
            places: places,
            contentRevision: contentRevision,
            camera: camera,
            cameraTransitionRevision: cameraTransitionRevision,
            isManipulating: isManipulating,
            showsUserLocation: showsUserLocation,
            settleRevision: settleRevision,
            onViewportSettled: onViewportSettled,
            onUserLocationUpdate: onUserLocationUpdate
        )
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastContentRevision = -1
        private var lastCamera: GlobeCameraState?
        private var lastCameraTransitionRevision = -1
        private var lastSettleRevision = -1
        private var isManipulating = false
        private var onViewportSettled: (EarthViewport) -> Void
        private var onUserLocationUpdate: (GeoCoordinate) -> Void
        private var lastUserLocation: GeoCoordinate?

        init(
            onViewportSettled: @escaping (EarthViewport) -> Void,
            onUserLocationUpdate: @escaping (GeoCoordinate) -> Void
        ) {
            self.onViewportSettled = onViewportSettled
            self.onUserLocationUpdate = onUserLocationUpdate
        }

        func update(
            _ mapView: MKMapView,
            places: [TravelPlace],
            contentRevision: Int,
            camera: GlobeCameraState,
            cameraTransitionRevision: Int,
            isManipulating: Bool,
            showsUserLocation: Bool,
            settleRevision: Int,
            onViewportSettled: @escaping (EarthViewport) -> Void,
            onUserLocationUpdate: @escaping (GeoCoordinate) -> Void
        ) {
            self.onViewportSettled = onViewportSettled
            self.onUserLocationUpdate = onUserLocationUpdate
            if lastContentRevision != contentRevision {
                lastContentRevision = contentRevision
                updateMapContent(mapView, places: places)
            }
            if mapView.showsUserLocation != showsUserLocation {
                mapView.showsUserLocation = showsUserLocation
            }

            if lastCamera != camera {
                lastCamera = camera
                let mapCamera = MKMapCamera(
                    lookingAtCenter: CLLocationCoordinate2D(
                        latitude: camera.center.latitude,
                        longitude: camera.center.longitude
                    ),
                    fromDistance: camera.distance,
                    pitch: 0,
                    heading: 0
                )
                let isTransition = lastCameraTransitionRevision >= 0
                    && lastCameraTransitionRevision != cameraTransitionRevision
                mapView.setCamera(
                    mapCamera,
                    animated: isTransition && !UIAccessibility.isReduceMotionEnabled
                )
            }
            lastCameraTransitionRevision = cameraTransitionRevision

            if self.isManipulating != isManipulating {
                self.isManipulating = isManipulating
                updateMovingAppearance(in: mapView)
            }

            if lastSettleRevision != settleRevision {
                lastSettleRevision = settleRevision
                scheduleViewportSnapshot(from: mapView, revision: settleRevision)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard annotation is TravelMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: TravelMapAnnotationView.reuseIdentifier,
                for: annotation
            ) as? TravelMapAnnotationView
            view?.configure(isMoving: isManipulating)
            return view
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = userLocation.location,
                  location.horizontalAccuracy >= 0 else { return }
            let coordinate = GeoCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            guard coordinate.isValid, coordinate != lastUserLocation else { return }
            lastUserLocation = coordinate
            onUserLocationUpdate(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(red: 0.29, green: 0.88, blue: 1, alpha: 0.68)
            renderer.lineWidth = 2.2
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.alpha = isManipulating ? 0.34 : 1
            return renderer
        }

        private func updateMapContent(_ mapView: MKMapView, places: [TravelPlace]) {
            mapView.removeAnnotations(
                mapView.annotations.filter { $0 is TravelMapAnnotation }
            )
            mapView.addAnnotations(places.map(TravelMapAnnotation.init))

            mapView.removeOverlays(mapView.overlays)
            let routePlaces = Array(places.suffix(80))
            let routes = zip(routePlaces, routePlaces.dropFirst()).map { start, end in
                var coordinates = [
                    start.coordinate.clLocationCoordinate,
                    end.coordinate.clLocationCoordinate,
                ]
                return MKGeodesicPolyline(coordinates: &coordinates, count: coordinates.count)
            }
            mapView.addOverlays(routes, level: .aboveLabels)
        }

        private func updateMovingAppearance(in mapView: MKMapView) {
            for annotation in mapView.annotations {
                (mapView.view(for: annotation) as? TravelMapAnnotationView)?
                    .configure(isMoving: isManipulating)
            }
            for overlay in mapView.overlays {
                mapView.renderer(for: overlay)?.alpha = isManipulating ? 0.34 : 1
            }
        }

        private func scheduleViewportSnapshot(from mapView: MKMapView, revision: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak mapView] in
                guard let self, let mapView, self.lastSettleRevision == revision else { return }
                let bounds = mapView.bounds
                guard bounds.width > 1, bounds.height > 1 else {
                    self.scheduleViewportSnapshot(from: mapView, revision: revision)
                    return
                }

                let region = mapView.region
                let center = GeoCoordinate(
                    latitude: mapView.camera.centerCoordinate.latitude,
                    longitude: mapView.camera.centerCoordinate.longitude
                )
                let longitudeScale = max(abs(cos(center.latitude * .pi / 180)), 0.2)
                let latitudeRadius = abs(region.span.latitudeDelta) * 0.56
                let longitudeRadius = abs(region.span.longitudeDelta) * 0.5 * longitudeScale
                let viewport = EarthViewport(
                    center: center,
                    angularRadius: max(latitudeRadius, longitudeRadius)
                )
                self.onViewportSettled(viewport)
            }
        }
    }
}

nonisolated enum MapPlaceLOD {
    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    static func representatives(
        from places: [TravelPlace],
        limit: Int
    ) -> [TravelPlace] {
        guard limit > 0, places.count > limit else { return places }
        let sorted = places.sorted {
            if $0.endDate == $1.endDate { return $0.id < $1.id }
            return $0.endDate > $1.endDate
        }
        var countByCell: [Cell: Int] = [:]
        var selectedIDs = Set<String>()
        selectedIDs.reserveCapacity(limit)

        for place in sorted {
            let cell = Cell(
                latitude: Int(floor((place.coordinate.latitude + 90) / 2)),
                longitude: Int(floor((place.coordinate.longitude + 180) / 2))
            )
            guard countByCell[cell, default: 0] < 2 else { continue }
            countByCell[cell, default: 0] += 1
            selectedIDs.insert(place.id)
            if selectedIDs.count == limit { break }
        }

        return places.filter { selectedIDs.contains($0.id) }
    }
}

private final class TravelMapAnnotation: NSObject, MKAnnotation {
    let placeID: String
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(place: TravelPlace) {
        placeID = place.id
        coordinate = place.coordinate.clLocationCoordinate
        title = place.name
    }
}

private final class TravelMapAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "travel-place"

    private let haloLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        haloLayer.frame = bounds
        haloLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8)).cgPath
        coreLayer.frame = bounds
        coreLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 20, dy: 20)).cgPath
    }

    func configure(isMoving: Bool) {
        let accent = UIColor(red: 0.28, green: 0.9, blue: 1, alpha: 1)
        haloLayer.strokeColor = accent.withAlphaComponent(isMoving ? 0.3 : 0.62).cgColor
        haloLayer.lineWidth = isMoving ? 1.5 : 2.2
        haloLayer.fillColor = accent.withAlphaComponent(isMoving ? 0.04 : 0.1).cgColor
        haloLayer.shadowColor = accent.cgColor
        haloLayer.shadowOpacity = isMoving ? 0.34 : 0.82
        haloLayer.shadowRadius = isMoving ? 5 : 10
        coreLayer.fillColor = accent.withAlphaComponent(isMoving ? 0.58 : 1).cgColor
        coreLayer.shadowColor = accent.cgColor
        coreLayer.shadowOpacity = isMoving ? 0.38 : 1
        coreLayer.shadowRadius = isMoving ? 3 : 6
        alpha = isMoving ? 0.68 : 1
    }

    private func setupLayers() {
        frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        backgroundColor = .clear
        isOpaque = false
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .defaultHigh
        layer.addSublayer(haloLayer)
        layer.addSublayer(coreLayer)
    }
}

private extension GeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
