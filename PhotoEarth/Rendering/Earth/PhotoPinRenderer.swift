import MapKit

extension MapReviewGrid {
    init(viewport: EarthViewport, size: CGSize) {
        let bounds = PhotoSpatialBounds(viewport: viewport)
        let reference = viewport.center.longitude
        let world = MapReviewGrid.world(around: reference)
        let ranges = bounds.longitudeRanges.map { range -> (Double, Double) in
            let start = range.upperBound - range.lowerBound >= 360 ? reference - 180 : world.unwrappedLongitude(range.lowerBound)
            return (start, start + range.upperBound - range.lowerBound)
        }
        self.init(south: bounds.minimumLatitude, north: bounds.maximumLatitude,
            west: ranges.map { $0.0 }.min() ?? reference - 180,
            east: ranges.map { $0.1 }.max() ?? reference + 180, referenceLongitude: reference,
            columns: Int(size.width / 110), rows: Int(size.height / 110))
    }
}

/// The map delegate owns this renderer and supplies its existing map.
@MainActor final class PhotoPinRenderer {
    private unowned let map: MKMapView
    private var displayedAnchors: [MapReviewPinAnchor] = []
    private var pinRenderingActive = true
    private var annotationsByID: [String: MapReviewPhotoAnnotation] = [:]

    init(map: MKMapView) {
        self.map = map
        map.register(MapReviewPhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: MapReviewPhotoAnnotationView.reuseIdentifier)
    }

    func point(_ coordinate: GeoCoordinate) -> CGPoint? {
        let native = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let point = map.convert(native, toPointTo: map)
        guard point.x.isFinite, point.y.isFinite, map.bounds.contains(point) else { return nil }
        let inverse = map.convert(point, toCoordinateFrom: map)
        guard abs(inverse.latitude - coordinate.latitude) < 0.001,
              abs(MapReviewGrid.normalizedLongitude(inverse.longitude - coordinate.longitude)) < 0.001 else { return nil }
        return point
    }

    func pinAnchors(_ clusters: [MapReviewCluster]) -> [MapReviewPinAnchor] {
        pins(clusters).map { pin in
            // The first member supplies both the cover and its real GPS. An
            // average screen point can be ocean or empty space between visits.
            MapReviewPinAnchor(clusters: pin.clusters, coordinate: pin.clusters[0].coordinate)
        }
    }

    func displayPins(_ anchors: [MapReviewPinAnchor], isActive: Bool) {
        guard anchors != displayedAnchors || pinRenderingActive != isActive else { return }
        displayedAnchors = anchors; pinRenderingActive = isActive
        let ids = Set(anchors.map { MapReviewPin(clusters: $0.clusters, point: .zero).id })
        let removed = annotationsByID.keys.filter { !ids.contains($0) }
        map.removeAnnotations(removed.compactMap { annotationsByID.removeValue(forKey: $0) })
        for anchor in anchors {
            let id = MapReviewPin(clusters: anchor.clusters, point: .zero).id
            if let annotation = annotationsByID[id] {
                annotation.update(anchor, isActive: isActive)
                (map.view(for: annotation) as? MapReviewPhotoAnnotationView)?.configure(annotation)
            } else {
                let annotation = MapReviewPhotoAnnotation(anchor: anchor, isActive: isActive)
                annotationsByID[id] = annotation
                map.addAnnotation(annotation)
            }
        }
    }

    func view(for annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let annotation = annotation as? MapReviewPhotoAnnotation,
              let view = map.dequeueReusableAnnotationView(withIdentifier: MapReviewPhotoAnnotationView.reuseIdentifier,
                                                               for: annotation) as? MapReviewPhotoAnnotationView else { return nil }
        view.configure(annotation)
        return view
    }

    func projectedPins(_ anchors: [MapReviewPinAnchor]) -> [MapReviewPin] {
        anchors.compactMap { anchor in
            guard let point = point(anchor.coordinate) else { return nil }
            return MapReviewPin(clusters: anchor.clusters, point: point)
        }
    }

    /// Measure overlap from the visible cover, so a street of neighboring
    /// cells cannot chain together into one pin spanning the entire screen.
    func pins(_ clusters: [MapReviewCluster]) -> [MapReviewPin] {
        var groups: [MapReviewPin] = []
        func nearest(to point: CGPoint) -> (index: Int, distance: CGFloat)? {
            groups.indices.lazy.map { i in
                (index: i, distance: hypot(groups[i].point.x - point.x, groups[i].point.y - point.y))
            }.min { $0.distance < $1.distance }
        }
        let ordered = clusters.sorted {
            $0.count == $1.count ? $0.cell < $1.cell : $0.count > $1.count
        }
        for cluster in ordered {
            guard let point = point(cluster.coordinate) else { continue }
            if let anchor = nearest(to: point), anchor.distance < 100 {
                groups[anchor.index].clusters.append(cluster)
            } else {
                groups.append(MapReviewPin(clusters: [cluster], point: point))
            }
        }
        if groups.count > 32 {
            groups.sort {
                $0.count == $1.count ? $0.clusters[0].cell < $1.clusters[0].cell : $0.count > $1.count
            }
            let remaining = Array(groups.dropFirst(32))
            groups.removeLast(remaining.count)
            for other in remaining {
                if let anchor = nearest(to: other.point) {
                    groups[anchor.index].clusters += other.clusters
                }
            }
        }
        return groups
    }
}
