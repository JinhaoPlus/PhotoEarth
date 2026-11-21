#if os(tvOS) && !targetEnvironment(simulator)
import XCTest
import ImageIO
import Vision
@testable import PhotoEarth

final class RealTVJourneyShelfTests: XCTestCase {
#if DEBUG
    func testOnlyTheStandaloneAlbumGateSuppressesTheInteractiveHost() {
        let album = "PHOTOEARTH_REAL_TV_ALBUM_SCOPE", shelf = "PHOTOEARTH_REAL_TV_SHELF"
        XCTAssertFalse(PhotoEarthApp.usesIsolatedAlbumHost([:]))
        XCTAssertTrue(PhotoEarthApp.usesIsolatedAlbumHost([album: "1"]))
        XCTAssertFalse(PhotoEarthApp.usesIsolatedAlbumHost([shelf: "1"]))
        XCTAssertFalse(PhotoEarthApp.usesIsolatedAlbumHost([album: "1", shelf: "1"]))
    }
#endif

    @MainActor func testPublishedCityMatchesTheHomeDockAndVisibleLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_SHELF"] == "1")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var ready: JourneyShelfSnapshot?
        while ContinuousClock.now < deadline {
            if let snapshot = JourneyShelfKeychain.read(), snapshot.imageVersion == JourneyShelfSnapshot.currentImageVersion, JourneyShelfPhoto.validatesAllMarkers(snapshot) { ready = snapshot; break }
            try await Task.sleep(for: .seconds(1))
        }
        let snapshot = try XCTUnwrap(ready, "Open Photo Earth with its real prepared library and Home Screen setting enabled")
        let store = SQLiteTravelIndexStore()
        let stored = try await store.load()
        let index = try XCTUnwrap(stored)
        let expected = JourneyShelfSelection.recent(in: index, minimumVisitItems: JourneyVisitThreshold.load())
        let routes = Set(snapshot.items.map(\.route))
        XCTAssertEqual(snapshot.items.map(\.route), expected.filter { routes.contains($0.collection.id) }.map(\.collection.id))
        for item in snapshot.items {
            let selected = try XCTUnwrap(expected.first { $0.collection.id == item.route })
            let wall = selected.collection
            let cover = try await store.visibleJourneyCover(item.assetID, in: [selected.representative.id])
            _ = try XCTUnwrap(cover, "Published cover belongs to the home card's most recent qualifying visit")
            XCTAssertEqual(item.endDate, selected.representative.endDate)
            XCTAssertEqual(item.title, wall.title)
        }
        let first = try XCTUnwrap(snapshot.items.first)
        let url = try XCTUnwrap(JourneyShelfLink.url(first.route))
        let link = XCTAttachment(data: Data(url.absoluteString.utf8), uniformTypeIdentifier: "public.plain-text")
        link.name = "private-journey-link.txt"
        link.lifetime = .keepAlways
        add(link)
#if DEBUG
        if let receipt = JourneyShelfKeychain.providerReceipt() {
            let diagnostics = XCTAttachment(string: receipt)
            diagnostics.name = "top-shelf-system-provider-aggregate.txt"
            diagnostics.lifetime = .keepAlways
            add(diagnostics)
        }
#endif
    }

    @MainActor func testNativeGlobePreviewContainsTheRegionalMapCredit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_SHELF"] == "1")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var preview: Data?
        while ContinuousClock.now < deadline {
            if let snapshot = JourneyShelfKeychain.read(), snapshot.imageVersion == JourneyShelfSnapshot.currentImageVersion, JourneyShelfPhoto.validatesAllMarkers(snapshot),
               let scope = snapshot.globeScope, let jpeg = JourneyShelfKeychain.globe(for: scope) {
                preview = jpeg
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        let data = try XCTUnwrap(preview, "No current private native MapKit preview. Stage: " + EarthShelfMapArtwork.lastStage)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.jpeg")
        attachment.name = "private-native-mapkit-globe.jpg"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(data.count, JourneyShelfImageURL.globeByteLimit)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThanOrEqual(image.width, 1_200)
        XCTAssertEqual(image.width * 9, image.height * 16)
        XCTAssertTrue(EarthShelfMapArtwork.hasSurfacePixels(image))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertTrue(try hasReadableMapCredit(in: image),
                      "Verify the TV region's native MapKit attribution in the attached frame")
    }

    /// Chinese MapKit draws a small outlined provider logo; Vision can miss it in a whole-width frame.
    /// Inspect the ordinary legal strip, then enlarge each possible corner without changing the JPEG.
    private func hasReadableMapCredit(in image: CGImage) throws -> Bool {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let sx = width / 1_440, sy = height / 810
        let right = CGRect(x: width - (190 * sx).rounded(), y: height - (63 * sy).rounded(),
                           width: (124 * sx).rounded(), height: (49 * sy).rounded())
        let left = CGRect(x: width - right.maxX, y: right.minY, width: right.width, height: right.height)
        let widerRight = CGRect(x: width - (230 * sx).rounded(), y: height - (80 * sy).rounded(),
                                width: (230 * sx).rounded(), height: (80 * sy).rounded())
        let widerLeft = CGRect(x: 0, y: widerRight.minY, width: widerRight.width, height: widerRight.height)
        let bottom = CGRect(x: 0, y: height * 0.75, width: width, height: height * 0.25)
        for (region, scale) in [(bottom, 1), (right, 4), (left, 4), (widerRight, 3), (widerLeft, 3)] {
            guard let crop = image.cropping(to: region.integral),
                  let context = CGContext(data: nil, width: crop.width * scale, height: crop.height * scale,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            guard let enlarged = context.makeImage() else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: enlarged).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
            if labels.contains(where: { label in ["高德", "apple", "maps", "legal", "地图", "地圖"].contains(where: label.contains) }) {
                return true
            }
        }
        return false
    }
}
#endif
