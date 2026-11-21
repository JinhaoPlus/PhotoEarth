import MapKit
import UIKit

/// Render only the host's approved travel markers. The map view supplies the native
/// projection check and regional legal ornaments. Satellite pixels come from MapKit.
@MainActor enum EarthShelfMapArtwork {
    static let size = CGSize(width: 1_440, height: 810)
    private(set) static var lastStage = "notRequested"
    private(set) static var renderingPath = "none"

    static func render(coordinates: [CLLocationCoordinate2D]) async -> Data? {
        lastStage = "waitingForActiveScene"
        renderingPath = "none"
        guard !Task.isCancelled, let anchor = coordinates.first, coordinates.count <= JourneyShelfSnapshot.globeMarkerLimit,
              coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow, !window.subviews.isEmpty else { return nil }

        // Never capture the user's window, current device location, home cards, or Photos.
        // A native map behind the app's opaque root supplies only its own map ornaments.
        let map = MKMapView(frame: CGRect(origin: .zero, size: size))
        let delegate = Markers()
        map.delegate = delegate
        map.preferredConfiguration = PhotoMapStyle.satellite.configuration()
        map.overrideUserInterfaceStyle = .dark
        map.showsUserLocation = false
        map.showsScale = false
        map.isUserInteractionEnabled = false
        map.accessibilityElementsHidden = true
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = UIEdgeInsets(top: 24, left: 80, bottom: 24, right: 80)
        window.insertSubview(map, at: 0)
        defer { map.delegate = nil; map.removeFromSuperview() }
        map.layoutIfNeeded()
        let home = GlobeCameraState(center: GeoCoordinate(latitude: anchor.latitude, longitude: anchor.longitude),
                                    distance: GlobeCameraState.orbitalDistance).mapConstrained()
        map.setCamera(home.nativeCamera, animated: false)
        let annotations = coordinates.map { point in
            let marker = MKPointAnnotation()
            marker.coordinate = point
            return marker
        }
        map.addAnnotations(annotations)
        map.layoutIfNeeded()

        lastStage = "requestingNativeSnapshot"
        let options = MKMapSnapshotter.Options()
        options.camera = map.camera.copy() as! MKMapCamera
        options.preferredConfiguration = PhotoMapStyle.satellite.configuration()
        options.size = size
        options.traitCollection = map.traitCollection.modifyingTraits { $0.displayScale = 1 }
        let request = MKMapSnapshotter(options: options)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            request.cancel()
        }
        defer { timeout.cancel() }
        let snapshot = await withTaskCancellationHandler {
            try? await request.start()
        } onCancel: { Task { @MainActor in request.cancel() } }
        guard !Task.isCancelled, scene.activationState == .foregroundActive else { return nil }
        lastStage = "checkingNativeProjection"
        guard let viewport = MapViewportSampler.photoSnapshot(in: map) else { return nil }

        let points = annotations.compactMap { annotation -> CGPoint? in
            let coordinate = annotation.coordinate
            let location = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard viewport.containsCoordinate(location) else { return nil }
            // An actual annotation's center can differ from convert() on a tilted globe.
            let point: CGPoint
            if let view = map.view(for: annotation), !view.isHidden, view.alpha > 0 {
                point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: map)
            } else if let snapshot {
                point = snapshot.point(for: coordinate)
            } else { return nil }
            return map.bounds.contains(point) ? point : nil
        }
        map.layoutIfNeeded()
        guard !points.isEmpty else { return nil }
        lastStage = "checkingNativeAttribution"
        let ornaments = legalOrnaments(in: map)
        guard !ornaments.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        if delegate.fullyRendered {
            let frame = renderer.image { _ in map.drawHierarchy(in: map.bounds, afterScreenUpdates: true) }
            if let image = frame.cgImage, hasSurfacePixels(image), let data = encode(frame) {
                renderingPath = "completeNativeMapView"
                return data
            }
        }
        guard let snapshot, let image = snapshot.image.cgImage, image.width >= 1_200, hasSurfacePixels(image) else { return nil }
        renderingPath = "nativeMapSnapshot"
        let combined = renderer.image { context in
            snapshot.image.draw(in: map.bounds)
            for point in points {
                let diameter = size.width / 1_920 * TravelMapAnnotationView.worldImage.size.width
                TravelMapAnnotationView.worldImage.draw(in: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                                                   width: diameter, height: diameter))
            }
            for (view, frame) in ornaments {
                let drawing = context.cgContext
                drawing.saveGState()
                drawing.translateBy(x: frame.minX, y: frame.minY)
                drawing.scaleBy(x: frame.width / view.bounds.width, y: frame.height / view.bounds.height)
                view.layer.render(in: drawing)
                drawing.restoreGState()
            }
        }
        return encode(combined)
    }

    static func hasSurfacePixels(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var buckets = Set<Int>()
            var surface = 0
            for row in 6..<26 {
                for col in 2..<30 {
                    let pixel = (row * side + col) * 4
                    let r = Int(memory[pixel]), g = Int(memory[pixel + 1]), b = Int(memory[pixel + 2])
                    if max(r, g, b) >= 22 { surface += 1 }
                    buckets.insert((r / 12) << 10 | (g / 12) << 5 | b / 12)
                }
            }
            return surface >= 50 && buckets.count >= 16
        }
    }

    private static func encode(_ combined: UIImage) -> Data? {
        lastStage = "encoding"
        for quality in [0.88, 0.78, 0.68, 0.58] {
            if let data = combined.jpegData(compressionQuality: quality), data.count <= JourneyShelfImageURL.globeByteLimit {
                lastStage = "encoded"
                return data
            }
        }
        return nil
    }

    private final class Markers: NSObject, MKMapViewDelegate {
        var fullyRendered = false
        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.image = TravelMapAnnotationView.worldImage
            view.displayPriority = .required
            return view
        }
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            self.fullyRendered = fullyRendered
        }
    }

    /// MKMapSnapshotter can omit the linked legal / supplier ornaments of MKMapView.
    /// Preserve the native views at their actual layout positions, without accessing
    /// any private MapKit classes, labels, strings or KVC. Skip the custom photo markers.
    private static func legalOrnaments(in map: MKMapView) -> [(UIView, CGRect)] {
        var result: [(UIView, CGRect)] = []
        func visit(_ view: UIView) {
            guard !(view is MKAnnotationView), !view.isHidden, view.alpha > 0, !view.bounds.isEmpty else { return }
            let frame = view.convert(view.bounds, to: map)
            let bottom = map.bounds.height
            let isFooter = frame.minY > bottom * 0.78 && frame.maxY <= bottom + 1
                && frame.width >= 10 && frame.width < map.bounds.width * 0.45 && frame.height >= 5
                && (frame.midX < map.bounds.width * 0.35 || frame.midX > map.bounds.width * 0.65)
            if isFooter {
                result.append((view, frame))
            } else {
                view.subviews.forEach(visit)
            }
        }
        map.subviews.forEach(visit)
        return result
    }
}
