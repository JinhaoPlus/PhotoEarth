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

    /// Merge neighboring SQL cells whose native screen projections overlap.
    /// Counts and member cells are preserved, including transitive overlaps.
    func pins(_ clusters: [MapReviewCluster]) -> [MapReviewPin] {
        var groups: [(clusters: [MapReviewCluster], points: [CGPoint])] = []
        for cluster in clusters {
            guard let point = point(cluster.coordinate) else { continue }
            let overlaps = groups.indices.filter { index in
                groups[index].points.contains { hypot($0.x - point.x, $0.y - point.y) < 100 }
            }
            var members = [cluster], points = [point]
            for index in overlaps.reversed() {
                members += groups[index].clusters; points += groups[index].points
                groups.remove(at: index)
            }
            groups.append((members, points))
        }
        if groups.count > 32 {
            // Keep the largest groups, then assign each remaining group to its
            // nearest retained anchor. At most 240 × 32 comparisons; avoid a
            // repeated all-pairs search for every one of 208 discarded groups.
            groups.sort {
                let lhs = $0.clusters.reduce(0) { $0 + $1.count }
                let rhs = $1.clusters.reduce(0) { $0 + $1.count }
                return lhs == rhs ? $0.clusters[0].cell < $1.clusters[0].cell : lhs > rhs
            }
            let remaining = Array(groups.dropFirst(32))
            groups = Array(groups.prefix(32))
            for other in remaining {
                let nearest = groups.indices.min { lhs, rhs in
                    let point = other.points[0]
                    let a = groups[lhs].points[0], b = groups[rhs].points[0]
                    return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
                }!
                groups[nearest].clusters += other.clusters
            }
        }
        return groups.map { MapReviewPin(clusters: $0.clusters, point: $0.points[0]) }

    }
}
