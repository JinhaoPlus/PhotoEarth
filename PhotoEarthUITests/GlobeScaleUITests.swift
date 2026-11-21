import XCTest

final class GlobeScaleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testDemoCityToNeighborhoodAndBack() throws {
        try exerciseCamera(demo: true)
    }

    /// Run explicitly on a simulator that has already indexed its private Photos sample.
    @MainActor func testPhotoLibraryCityToNeighborhoodAndBack() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_GLOBE_TEST"] == "1")
        try exerciseCamera(demo: false)
    }

    @MainActor private func exerciseCamera(demo: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = demo ? ["--demo"] : []
        app.useSimplifiedChineseTestLanguage()
        let recordSeconds = ProcessInfo.processInfo.environment["PHOTOEARTH_TV_RECORD_SECONDS"].flatMap(Int.init)
        if let recordSeconds {
            XCTAssertTrue((50...150).contains(recordSeconds))
            app.launchArguments += ["--qa-device-record-seconds", String(recordSeconds)]
        }
        app.launch()
        if let recordSeconds {
            // Let the TV operator approve the system prompt before the test sends
            // remote input. Keep the app alive until ReplayKit closes the file.
            let recording = app.descendants(matching: .any)["qa-device-recording-active"].firstMatch
            XCTAssertTrue(recording.waitForExistence(timeout: 120), "Waiting for the TV operator to approve ReplayKit")
            addTeardownBlock { @MainActor in
                let saved = app.descendants(matching: .any)["qa-device-recording-saved"].firstMatch
                XCTAssertTrue(saved.waitForExistence(timeout: TimeInterval(recordSeconds + 20)),
                              "ReplayKit must finish writing tmp/PhotoEarthQA/device-screen.mp4")
            }
        }
        let remote = XCUIRemote.shared
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 40))
        if !entry.hasFocus { remote.press(.right) }
        XCTAssertTrue(waitForFocus(entry))
        remote.press(.down)
        let city = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'overview-place-' AND hasFocus == true")).firstMatch
        XCTAssertTrue(city.waitForExistence(timeout: 8))
        remote.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 10))
        let arrived = NSPredicate { _, _ in self.distance(globe).map { abs($0 - 800_000) < 15_000 } == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: arrived, object: nil)], timeout: 12), .completed)
        remote.press(.playPause)
        let zoomIn = app.buttons["globe-zoom-in"]
        let zoomOut = app.buttons["globe-zoom-out"]
        let style = app.buttons["globe-style"]
        let controls = app.descendants(matching: .any)["globe-controls"].firstMatch
        XCTAssertTrue(waitForFocus(zoomIn))
        XCTAssertTrue(waitForStyle(style, "地图"))
        XCTAssertTrue(app.descendants(matching: .any)["earth-native-streets"].firstMatch.waitForExistence(timeout: 90))
        remote.press(.left)
        XCTAssertTrue(waitForFocus(zoomOut))
        remote.press(.select)
        XCTAssertTrue(waitForStyle(style, "卫星"))
        try awaitMapTiles(in: app, satellite: true)
        capture(app, "01-Orbital-satellite")
        remote.press(.right)
        XCTAssertTrue(waitForFocus(zoomIn))
        for _ in 0..<3 { remote.press(.select) }
        XCTAssertTrue(waitForStyle(style, "地图"))
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(globe))
        let count = app.staticTexts["memory-horizon-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 12))
        try awaitMapTiles(in: app)
        capture(app, "02-Local-map-photo-pins")
        remote.press(.playPause)
        XCTAssertTrue(waitForFocus(zoomIn))
        remote.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["globe-use-current-view"]))
        remote.press(.select)
        XCTAssertTrue(waitForFocus(globe))
        let exactCount = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label ENDSWITH %@", "张照片"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [exactCount], timeout: 15), .completed)
        let total = try XCTUnwrap(Int(count.label.filter(\.isNumber)))
        let markers = app.descendants(matching: .image).matching(NSPredicate(format: "identifier BEGINSWITH 'map-review-pin-'"))
        XCTAssertTrue(markers.firstMatch.waitForExistence(timeout: 12))
        let counts = markers.allElementsBoundByIndex.compactMap { Int($0.label.filter(\.isNumber)) }
        XCTAssertEqual(counts.reduce(0, +), total, "Native annotation groups must account for the same visible assets as the filmstrip")
        remote.press(.select)
        let wallCount = app.staticTexts["photo-wall-count"]
        let frozenCount = NSPredicate { _, _ in
            wallCount.exists && Int(wallCount.label.filter(\.isNumber)) == total
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: frozenCount, object: nil)], timeout: 20), .completed)
        let aggregate = XCTAttachment(string: "groups=\(counts.count) grouped_assets=\(counts.reduce(0, +)) filmstrip=\(total) wall=\(total)")
        aggregate.name = "Frozen-viewport-counts"
        aggregate.lifetime = .keepAlways
        add(aggregate)
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(globe))
        remote.press(.playPause)
        XCTAssertTrue(waitForFocus(zoomIn))
        for _ in 0..<26 {
            guard let current = distance(controls), current > 2_500 else { break }
            remote.press(.select)
        }
        let street = try XCTUnwrap(distance(controls))
        XCTAssertLessThan(street, 3_500)
        XCTAssertEqual(style.label, "地图")
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(globe))
        remote.press(.right)
        remote.press(.left)
        // Wait until the refreshed projection finishes, including an empty street.
        let horizon = app.descendants(matching: .any)["memory-horizon-empty"].firstMatch
        let settled = NSPredicate { _, _ in count.exists || horizon.exists }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 4)
        try awaitMapTiles(in: app)
        capture(app, "03-Neighborhood")
        remote.press(.playPause)
        XCTAssertTrue(waitForFocus(zoomIn))
        remote.press(.left)
        XCTAssertTrue(waitForFocus(zoomOut))
        for _ in 0..<28 {
            if style.label == "卫星", (distance(controls) ?? 0) > 850_000 { break }
            remote.press(.select)
        }
        XCTAssertTrue(waitForStyle(style, "卫星"))
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(globe))
        XCTAssertGreaterThan(try XCTUnwrap(distance(globe)), 800_000)
        try awaitMapTiles(in: app, satellite: true)
        capture(app, "04-Return-to-globe")
    }

    /// Sample the map outside the toolbar, filmstrip and central photographic pin.
    /// Cold MapKit can publish a valid camera well before streets are drawn.
    @MainActor private func awaitMapTiles(in app: XCUIApplication, satellite: Bool = false) throws {
        let currentMap = app.descendants(matching: .any)[satellite ? "earth-native-satellite" : "earth-native-streets"].firstMatch
        XCTAssertTrue(currentMap.waitForExistence(timeout: 90), "MapKit must have installed the requested style")
        let deadline = Date().addingTimeInterval(75)
        repeat {
            let source = try XCTUnwrap(app.screenshot().image.cgImage)
            let width = 64, height = 36
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var colors = Set<Int>()
            for y in 10..<26 {
                for x in 5..<59 where x < 27 || x > 37 {
                    let i = (y * width + x) * 4
                    colors.insert(Int(pixels[i] / 6) << 12 | Int(pixels[i+1] / 6) << 6 | Int(pixels[i+2] / 6))
                }
            }
            // Incomplete satellite tiles can be uniform gray along the edge
            // even when the cached center has already drawn in full color.
            let edgeColumns = [2, 5, 58, 61]
            var incompleteEdge = false
            if satellite {
                for x in edgeColumns {
                    var neutral = 0
                    for y in 4..<30 {
                        let i = (y * width + x) * 4
                        let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
                        if min(r, g, b) > 135, max(r, g, b) - min(r, g, b) <= 2 { neutral += 1 }
                    }
                    if neutral >= 10 { incompleteEdge = true }
                }
            }
            if colors.count >= 12, !incompleteEdge { return }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        } while Date() < deadline
        capture(app, "Native-map-tiles-unavailable")
        XCTFail("The native basemap remained blank or had missing satellite tiles after the camera settled")
    }

    @MainActor private func distance(_ element: XCUIElement) -> Double? {
        guard let value = element.value as? String,
              let number = Double(value.filter { $0.isNumber || $0 == "." }) else { return nil }
        return value.contains("公里") || value.contains("千米") || value.lowercased().contains("km") ? number * 1_000 : number
    }

    @MainActor private func waitForStyle(_ style: XCUIElement, _ value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value),
                                                       object: style)], timeout: 8) == .completed
    }

    @MainActor private func waitForFocus(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 8) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"),
                                                              object: element)], timeout: 6) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
