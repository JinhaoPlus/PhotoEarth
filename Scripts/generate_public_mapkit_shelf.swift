// swiftc -parse-as-library Scripts/generate_public_mapkit_shelf.swift -o /tmp/photoearth-mapkit-art
import AppKit
import MapKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@MainActor private final class PublicGlobe: NSObject, MKMapViewDelegate {
    // These public geographic landmarks are independent of the user's library and device location.
    // Beijing, Seoul, Tokyo Station, Taipei, Chengdu and Hong Kong.
    private let cities = [(39.904, 116.407), (37.567, 126.978), (35.681, 139.767),
                          (25.034, 121.565), (30.572, 104.067), (22.319, 114.169)]
    // Mac MapKit forces 0° pitch at the tvOS home distance of 10,000 km.
    // At 6,000 km this renderer reaches the same actual 35° tilt.
    let map = MKMapView()
    var rendered = false

    func configure() {
        map.delegate = self
        map.appearance = NSAppearance(named: .darkAqua)
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.isPitchEnabled = true
        map.showsUserLocation = false
        map.showsZoomControls = false
        map.showsPitchControl = false
        map.showsCompass = false
        map.showsScale = false
        map.showsTraffic = false
        map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: 29, longitude: 116),
                                 fromDistance: 6_000_000, pitch: 35, heading: 0), animated: false)
        for (latitude, longitude) in cities {
            let marker = MKPointAnnotation()
            marker.coordinate = .init(latitude: latitude, longitude: longitude)
            map.addAnnotation(marker)
        }
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        rendered = fullyRendered
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        // Same stop positions and blue-white colors as TravelMapAnnotationView.makeMarker.
        let diameter = mapView.bounds.height * 22 / 450
        view.image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let colors = [(0.94,0.99,1.0,0.98), (0.80,0.95,1,0.86), (0.61,0.84,0.94,0.48),
                          (0.53,0.77,0.88,0.19), (0.47,0.71,0.83,0.05), (0.47,0.71,0.83,0)]
                .map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                            locations: [0,0.065,0.16,0.34,0.65,1]),
                  let context = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: rect.width / 2, options: [])
            return true
        }
        view.canShowCallout = false
        return view
    }
}

@main enum GeneratePublicMapKitShelf {
    private static func luminances(_ image: CGImage, at rect: CGRect) throws -> [UInt8] {
        guard let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: crop.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
              let address = context.data else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(crop, in: CGRect(origin: .zero, size: rect.size))
        return Array(UnsafeBufferPointer(start: address.assumingMemoryBound(to: UInt8.self),
                                         count: crop.width * crop.height))
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        guard args.count == 4, let width = Int(args[1]), let height = Int(args[2]), width > 0, height > 0 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let size = NSSize(width: width / 2, height: height / 2)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.title = "Photo Earth · Public MapKit artwork"
        let globe = PublicGlobe()
        window.contentView = globe.map
        window.orderBack(nil)
        defer { window.close() }
        globe.configure()
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while !globe.rendered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard globe.rendered, abs(globe.map.camera.pitch - 35) < 0.2,
              abs(globe.map.camera.centerCoordinate.latitude - 29) < 0.001,
              abs(globe.map.camera.centerCoordinate.longitude - 116) < 0.001 else { throw CocoaError(.fileReadCorruptFile) }
        try await Task.sleep(for: .seconds(2))
        let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let ownWindow = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) &&
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else { throw CocoaError(.fileNoSuchFile) }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        for annotation in globe.map.annotations { globe.map.view(for: annotation)?.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        let withoutLights = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        guard image.width == width, image.height == height,
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        // The native presentation and convert(coordinate:) can disagree at the horizon on macOS.
        // Verify the actual on-screen annotation by comparing two map captures at the same camera.
        let annotations = try globe.map.annotations.map { annotation -> [String: Double] in
            let point = globe.map.convert(annotation.coordinate, toPointTo: globe.map)
            guard let view = globe.map.view(for: annotation),
                  let container = view.superview, globe.map.bounds.contains(point) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let center = container.convert(CGPoint(x: view.frame.midX, y: view.frame.midY), to: globe.map)
            let residual = hypot(center.x - point.x, center.y - point.y)
            let y = globe.map.isFlipped ? center.y : globe.map.bounds.height - center.y
            let xPixels = center.x * CGFloat(width) / globe.map.bounds.width
            let yPixels = y * CGFloat(height) / globe.map.bounds.height
            let patch = CGRect(x: round(xPixels) - 3, y: round(yPixels) - 3, width: 7, height: 7)
            let marked = try luminances(image, at: patch)
            let unmarked = try luminances(withoutLights, at: patch)
            let brightening = zip(marked, unmarked).map { Int($0) - Int($1) }.max() ?? 0
            guard brightening >= 12 else { throw CocoaError(.validationMultipleErrors) }
            return ["latitude": annotation.coordinate.latitude, "longitude": annotation.coordinate.longitude,
                    "imageX": xPixels, "imageY": yPixels, "verifiedLightDelta": Double(brightening),
                    "coordinateConversionDifferencePoints": residual]
        }.sorted { ($0["longitude"] ?? 0) < ($1["longitude"] ?? 0) }
        guard annotations.count == 6 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let output = URL(fileURLWithPath: args[3])
        let digest = SHA256.hash(data: try Data(contentsOf: output)).map { String(format: "%02x", $0) }.joined()
        let receipt: [String: Any] = ["source": "MKMapView + MKImageryMapConfiguration(.realistic)",
                                       "system": ProcessInfo.processInfo.operatingSystemVersionString,
                                       "utc": Date.now.ISO8601Format(), "width": width, "height": height,
                                       "latitude": globe.map.camera.centerCoordinate.latitude,
                                       "longitude": globe.map.camera.centerCoordinate.longitude,
                                       "pitch": globe.map.camera.pitch, "distanceMeters": globe.map.camera.centerCoordinateDistance,
                                       "heading": globe.map.camera.heading, "pngSHA256": digest, "publicLandmarks": annotations]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.deletingPathExtension().appendingPathExtension("json"))
        print("MapKit camera: \(globe.map.camera.centerCoordinate), \(globe.map.camera.centerCoordinateDistance) m, pitch \(globe.map.camera.pitch); \(width) × \(height)")
    }
}
