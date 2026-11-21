import XCTest
import Vision

final class RealTVJourneyShelfUITests: XCTestCase {
    @MainActor func testPublicGlobeLinkOpensDirectManipulationAndReturns() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical television")
#else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_SHELF"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        // Attach XCTest to its own process before asking LaunchServices to deliver the URL.
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).firstMatch.waitForExistence(timeout: 30))
        app.open(try XCTUnwrap(URL(string: "photoearth://globe")))
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 150))
        XCUIRemote.shared.press(.playPause)
        let zoom = app.buttons["globe-zoom-in"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 8))
        attachScreen(XCUIScreen.main.screenshot(), name: "Public globe · zoom controls")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(zoom.waitForNonExistence(timeout: 8))
        XCTAssertTrue(globe.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: globe)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
#endif
    }

    /// Select the public card in PineBoard immediately before running this method alone.
    /// The system launched the app. Keep that process and use its actual screen and remote.
    @MainActor func testSelectedSystemGlobeRespondsToRemote() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical television")
#else
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTOEARTH_REAL_TV_SHELF"] == "1" && env["PHOTOEARTH_REAL_TV_SHELF_PRESELECTED"] == "1")
        continueAfterFailure = false
        XCTAssertEqual(XCUIApplication().state, .runningForeground, "Select the public Top Shelf card first")
        try waitForGlobeFrame(.globe, name: "System selection · direct globe")
        XCUIRemote.shared.press(.playPause)
        try waitForGlobeFrame(.toolbar, name: "System selection · remote opened zoom controls")
        XCUIRemote.shared.press(.menu)
        try waitForGlobeFrame(.globe, name: "System selection · remote returned to globe")
#endif
    }

    private enum GlobeFrame { case globe, toolbar }

    @MainActor private func waitForGlobeFrame(_ expected: GlobeFrame, name: String) throws {
        let deadline = Date().addingTimeInterval(12)
        repeat {
            let frame = XCUIScreen.main.screenshot()
            let image = try XCTUnwrap(frame.image.cgImage)
            let controls = try screenText(in: CGRect(x: 0.15, y: 0.66, width: 0.70, height: 0.27), image: image)
            let toolbar = [["缩小", "放大"], ["zoomout", "zoomin"]].contains { words in
                words.allSatisfy { controls.contains($0) }
            }
            var matches = expected == .toolbar && toolbar
            if expected == .globe && !toolbar {
                let scope = try screenText(in: CGRect(x: 0, y: 0, width: 0.38, height: 0.26), image: image)
                matches = ["当前画面内照片", "photosinthecurrentview"].contains { scope.contains($0) }
                if !matches {
                    let strip = try screenText(in: CGRect(x: 0, y: 0.60, width: 0.42, height: 0.36), image: image)
                    matches = ["这片画面里照片", "这片画面照片", "当前画面暂无可展示照片", "当前画面内没有找到照片",
                               "photosinthisview", "nophotopreviewsinthisview", "nophotosfoundinthisview"].contains { strip.contains($0) }
                }
            }
            if matches {
                attachScreen(frame, name: name)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        } while Date() < deadline
        attachScreen(XCUIScreen.main.screenshot(), name: name + " · unexpected frame")
        XCTFail("The expected globe screen was not visible: " + name)
    }

    // Crop in top-left screenshot coordinates before recognition so Vision keeps each
    // control's full 4K glyph detail. On actual TV frames it sometimes drops “的”.
    private func screenText(in region: CGRect, image: CGImage) throws -> String {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(x: region.minX * width, y: region.minY * height,
                            width: region.width * width, height: region.height * height).integral
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: crop).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string.lowercased().filter { !$0.isWhitespace && $0 != "的" }
        }.joined(separator: " ")
    }

    @MainActor private func attachScreen(_ frame: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: frame)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testScrollsTheSystemCityShelfAndOpensAnOlderCity() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the authorized physical television")
#else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PHOTOEARTH_REAL_TV_CITY_SHELF"] == "1")
        let value = try XCTUnwrap(environment["PHOTOEARTH_CITY_SHELF_TITLES"])
        let cities = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        // Only supply a Vision spelling after comparing it with the original TV frame.
        let aliases = try JSONDecoder().decode([String: String].self, from:
            Data((environment["PHOTOEARTH_CITY_SHELF_OCR_ALIASES"] ?? "{}").utf8))
        let target = try XCTUnwrap(environment["PHOTOEARTH_CITY_SHELF_TARGET"].flatMap(Int.init))
        guard cities.indices.contains(target - 1), target > 5 else {
            XCTFail("Supply the actual city order from the indexed TV and an older card to open")
            return
        }

        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        XCTAssertEqual(board.state, .runningForeground)
        let captionBand = CGRect(x: 0, y: 0.592, width: 1, height: 0.075)
        func globeIsFocused(_ frame: XCUIScreenshot) throws -> Bool {
            let caption = try screenText(in: captionBand, image: try XCTUnwrap(frame.image.cgImage))
            return caption.contains("滚动地球") || caption.contains("exploretheglobe")
        }
        var globe = XCUIScreen.main.screenshot()
        if try !globeIsFocused(globe) {
            let header = CGRect(x: 0.02, y: 0.08, width: 0.30, height: 0.08)
            let shelf = try screenText(in: header, image: try XCTUnwrap(globe.image.cgImage))
            if shelf.contains("photoearth") {
                XCUIRemote.shared.press(.up)
                RunLoop.current.run(until: Date().addingTimeInterval(0.45))
                globe = XCUIScreen.main.screenshot()
                // PineBoard can remember the previously selected card.
                for _ in cities {
                    if try globeIsFocused(globe) { break }
                    XCUIRemote.shared.press(.left)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    globe = XCUIScreen.main.screenshot()
                }
            }
        }
        guard try globeIsFocused(globe) else {
            attachScreen(globe, name: "Top Shelf · unexpected starting focus")
            XCTFail("Focus the Photo Earth globe card on the system Home Screen before running")
            return
        }

        for (offset, city) in cities.prefix(target).enumerated() {
            XCUIRemote.shared.press(.right)
            let name = "Top Shelf · city " + String(format: "%02d", offset + 1)
            let expected = city.lowercased().filter { !$0.isWhitespace && $0 != "的" }
            func matches(_ caption: String) -> Bool {
                let titles = caption.split(separator: " ")
                return titles.contains { $0.contains(expected) || String($0) == aliases[city] }
            }
            let deadline = Date().addingTimeInterval(2)
            var frame = XCUIScreen.main.screenshot()
            var caption = ""
            repeat {
                caption = try screenText(in: captionBand, image: try XCTUnwrap(frame.image.cgImage))
                if matches(caption) { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                frame = XCUIScreen.main.screenshot()
            } while Date() < deadline
            attachScreen(frame, name: name)
            XCTAssertTrue(matches(caption), "\(name) must show \(city). Read: \(caption)")
            if offset + 1 == target, !matches(caption) { return }
        }

        XCUIRemote.shared.press(.select)
        let app = XCUIApplication()
        let title = app.staticTexts["photo-wall-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        XCTAssertEqual(title.label, cities[target - 1])
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 12))
        attachScreen(XCUIScreen.main.screenshot(), name: "Top Shelf · city \(target) photo wall")
#endif
    }

    @MainActor func testSystemJourneyLinkOpensItsPhotoWall() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the authorized physical television")
#else
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTOEARTH_REAL_TV_SHELF"] == "1")
        let link = try XCTUnwrap(env["PHOTOEARTH_JOURNEY_SHELF_URL"].flatMap(URL.init(string:)),
                                 "Use the private journey URL from the matched TV's hosted gate")
        let app = XCUIApplication()
        app.open(link)
        let wall = app.descendants(matching: .any)["viewport-photo-wall"].firstMatch
        XCTAssertTrue(wall.waitForExistence(timeout: 150))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch.waitForExistence(timeout: 12))
        let frame = XCTAttachment(screenshot: app.screenshot())
        frame.name = "System journey link · fixed photo wall"
        frame.lifetime = .keepAlways
        add(frame)
#endif
    }
}
