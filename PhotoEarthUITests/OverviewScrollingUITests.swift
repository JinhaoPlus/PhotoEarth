import XCTest

final class OverviewScrollingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLargeLibraryScrollsDownAndBackWithBoundedImagesAndCacheReuse() throws {
        try scrollFixture(slowImages: false)
    }

    @MainActor func testSlowCloudImagesDoNotBlockRowsOrFocus() throws {
        try scrollFixture(slowImages: true)
    }

    @MainActor func testBackFromExpandedShelvesStaysAtThePageTop() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--home-scroll-fixture", "--home-performance"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(waitForFocus(entry))
        let initialFrame = entry.frame
        for row in 0...6 {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForRow(row, app: app))
        }
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Deep home shelf before Back"; before.lifetime = .keepAlways; add(before)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(entry))
        let movesOffHero = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == false"), object: entry)
        movesOffHero.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [movesOffHero], timeout: 1.5), .completed)
        XCTAssertEqual(entry.frame.minY, initialFrame.minY, accuracy: 2)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Home stayed at page top after Back"; after.lifetime = .keepAlways; add(after)
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["place-library"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func scrollFixture(slowImages: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--home-scroll-fixture", "--home-performance"]
        app.useSimplifiedChineseTestLanguage()
        if slowImages { app.launchArguments.append("--home-slow-images") }
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFocus(entry))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(app.buttons["overview-place-sample-shelf-0"]))

        for row in 1...20 {
            XCUIRemote.shared.press(.down)
            let reached = waitForRow(row, app: app)
            if !reached {
                let state = XCTAttachment(string: app.debugDescription); state.name = "Failed shelf navigation"; state.lifetime = .keepAlways; add(state)
                let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Failed shelf focus"; shot.lifetime = .keepAlways; add(shot)
            }
            XCTAssertTrue(reached, "Row \(row) is reachable while images are pending")
        }
        let before = try metrics(app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "overview-year-2025").count, 1,
                       "Appending more rows in the same year must retain a single year heading")
        XCTAssertGreaterThanOrEqual(before["loaded"] ?? 0, 65)
        for row in stride(from: 19, through: 17, by: -1) {
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(waitForRow(row, app: app))
        }
        for row in 18...20 {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForRow(row, app: app))
        }
        let after = try metrics(app)
        XCTAssertLessThanOrEqual(after["maxLocal"] ?? 999, 4)
        XCTAssertLessThanOrEqual(after["maxCloud"] ?? 999, 2)
        XCTAssertLessThanOrEqual(after["peakBytes"] ?? Int.max, 48 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(after["images"] ?? 999, 40)
        if !slowImages {
            XCTAssertGreaterThan(after["hits"] ?? 0, before["hits"] ?? 0)
            XCTAssertGreaterThan(after["images"] ?? 0, 0)
            XCTAssertEqual(after["cloud"], 0)
        } else { XCTAssertGreaterThan(after["cloud"] ?? 0, 0) }
        let report = XCTAttachment(string: "Public fixture, 50,000 photos / 1,000 places; slowImages=\(slowImages)\n\(after)")
        report.name = "Home scroll request budgets"; report.lifetime = .keepAlways; add(report)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = slowImages ? "Pending cloud images preserve the shelf" : "Cached shelf after reversing direction"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor private func metrics(_ app: XCUIApplication) throws -> [String: Int] {
        let probe = app.staticTexts["overview-performance"]
        XCTAssertTrue(probe.waitForExistence(timeout: 3))
        var result: [String: Int] = [:]
        for pair in probe.label.split(separator: ";") {
            let parts = pair.split(separator: "=")
            if parts.count == 2 { result[String(parts[0])] = Int(parts[1]) }
        }
        XCTAssertNotNil(result["loaded"])
        return result
    }

    @MainActor private func waitForFocus(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func waitForRow(_ row: Int, app: XCUIApplication) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", ";row=\(row);"),
                                                    object: app.staticTexts["overview-performance"])
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else { return false }
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'overview-place-' AND hasFocus == true")).firstMatch
        let reached = focused.waitForExistence(timeout: 3)
        if !reached {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "Native focus missing in row \(row)"; state.lifetime = .keepAlways; add(state)
        }
        return reached
    }
}
