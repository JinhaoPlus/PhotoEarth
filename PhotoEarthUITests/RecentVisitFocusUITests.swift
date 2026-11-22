import XCTest

final class RecentVisitFocusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSecondColumnMovesIntoAnInterveningSingleCardMonth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--recent-focus-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()

        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(focus(entry))
        app.openSidebarDestination("tab-recent")

        let marchFirst = app.buttons["library-collection-sample-focus-march-first"]
        let marchSecond = app.buttons["library-collection-sample-focus-march-second"]
        let februaryOnly = app.buttons["library-collection-sample-focus-february-only"]
        let januaryFirst = app.buttons["library-collection-sample-focus-january-first"]
        let januarySecond = app.buttons["library-collection-sample-focus-january-second"]
        XCTAssertTrue(focus(marchFirst))
        let title = app.staticTexts["library-place-title-sample-focus-march-first"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("March First") && title.label.contains("Focus Fixture"),
                      "The city and country share one title")
        let summary = app.staticTexts["library-visit-summary-sample-focus-march-first"]
        XCTAssertTrue(summary.label.contains("2025") && summary.label.contains("5 张照片"),
                      "Each visit remains identifiable by its full spoken date and photo count")
        attach(app, "Recent visit captions in their month")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(marchSecond))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(februaryOnly), "A short adjacent month must not be skipped from column two")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(januaryFirst), "Vertical focus must continue through the next visual row")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(januarySecond))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(focus(februaryOnly), "The same short month must remain reachable while moving upward")
    }

    @MainActor func testCitiesUseTheOpenCountryAsTheirHeading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--recent-focus-fixture"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-countries")

        let countryID = "country:name:Focus Fixture"
        XCTAssertTrue(focus(app.buttons["library-collection-\(countryID)"]))
        attach(app, "Country counts on one line")
        XCUIRemote.shared.press(.select)
        let title = app.staticTexts["library-place-title-\(countryID)/city:sample-focus-march-first"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "March First")
        let heading = app.staticTexts["Focus Fixture"]
        let allPhotos = app.buttons["library-country-photos"]
        XCTAssertTrue(heading.isHittable)
        XCTAssertTrue(focus(allPhotos))
        XCTAssertGreaterThan(allPhotos.frame.minX, heading.frame.maxX)
        XCTAssertLessThan(allPhotos.frame.minY, heading.frame.maxY)
        attach(app, "City cards under their country")
    }

    @MainActor func testRecentVisitCoversStayPopulatedAcrossBothScrollDirections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()

        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(focus(entry))
        app.openSidebarDestination("tab-recent")

        XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-0"]))
        for index in [4, 8, 12, 15, 19] {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-\(index)"]))
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "Recent covers after scrolling down")

        for index in [15, 12, 8, 4] {
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-\(index)"]))
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "Recent covers after scrolling up")
    }

    @MainActor func testBackFromScrolledRecentVisitsReturnsToTopBeforeOpeningSidebar() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-recent")

        let first = app.buttons["library-collection-sample-ratio-place-0"]
        XCTAssertTrue(focus(first))
        let topFrame = first.frame
        for index in [4, 8, 12] {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-\(index)"]))
        }
        XCTAssertLessThan(first.frame.minY, topFrame.minY - 20)
        let source = app.buttons["library-collection-sample-ratio-place-12"]
        let sourceFrame = source.frame
        XCUIRemote.shared.press(.select)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(source))
        XCTAssertEqual(source.frame.minY, sourceFrame.minY, accuracy: 2)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(first))
        XCTAssertEqual(first.frame.minY, topFrame.minY, accuracy: 2)
        attach(app, "Recent visits after Back to top")

        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
    }

    @MainActor func testBackFromScrolledCitiesReturnsToTopThenOriginatingCountry() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-countries")

        let country = app.buttons["library-collection-country:name:Layout Sample"]
        XCTAssertTrue(focus(country))
        XCUIRemote.shared.press(.select)
        let allPhotos = app.buttons["library-country-photos"]
        XCTAssertTrue(focus(allPhotos))
        XCTAssertEqual(allPhotos.label, "View All Photos")
        XCTAssertFalse(app.buttons["library-countries-back"].exists)
        let topFrame = allPhotos.frame
        for index in [0, 4, 8] {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(focus(app.buttons["library-collection-country:name:Layout Sample/city:sample-ratio-place-\(index)"]))
        }
        XCTAssertLessThan(allPhotos.frame.minY, topFrame.minY - 20)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(allPhotos))
        XCTAssertEqual(allPhotos.frame.minY, topFrame.minY, accuracy: 2)
        XCTAssertTrue(app.staticTexts["Layout Sample"].isHittable)
        attach(app, "City list after Back to top")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(country))
        XCTAssertFalse(allPhotos.exists)
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 8) else { return false }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
