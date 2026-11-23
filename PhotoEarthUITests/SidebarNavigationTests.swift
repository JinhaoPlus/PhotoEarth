import XCTest

final class SidebarNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testNativeSidebarDestinationsAndCollectionReturn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        // Accessibility can expose the new window during the system launch
        // transition. Send Menu only once the app owns the expected focus.
        XCTAssertTrue(focus(entry))
        XCUIRemote.shared.press(.menu)
        attach(app, "Native sidebar")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let city = app.buttons["library-collection-sample-reykjavik"]
        XCTAssertTrue(city.waitForExistence(timeout: 5))
        let monthTitle = app.descendants(matching: .any)["library-recent-month-title"].firstMatch
        XCTAssertTrue(monthTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(monthTitle.label.contains("2025年2月"), "Recent visits must use a localized month heading")
        let visitSummary = app.descendants(matching: .any)["library-visit-summary-sample-reykjavik"].firstMatch
        XCTAssertTrue(visitSummary.waitForExistence(timeout: 5))
        XCTAssertTrue(visitSummary.label.contains("项"), "A recent-visit card must identify the full range and photo count")
        attach(app, "Recent arrivals")
        XCTAssertTrue(focus(city))
        XCUIRemote.shared.press(.select)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["photo-detail-image"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(city.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(city))
        app.openSidebarDestination("tab-countries")
        let country = app.buttons["library-collection-country:region:IS"]
        let brazil = app.buttons["library-collection-country:region:BR"]
        XCTAssertTrue(country.waitForExistence(timeout: 5))
        XCTAssertTrue(brazil.waitForExistence(timeout: 5))
        XCTAssertLessThan(country.frame.minX, brazil.frame.minX, "Countries must appear newest first")
        XCTAssertTrue(focus(country))
        XCTAssertEqual(app.staticTexts["library-place-title-country:region:IS"].label, "🇮🇸 冰岛")
        attach(app, "Countries")
        XCUIRemote.shared.press(.select)
        let allPhotos = app.buttons["library-country-photos"]
        XCTAssertTrue(allPhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["🇮🇸 冰岛"].exists)
        attach(app, "Cities in a country")
        XCTAssertTrue(focus(allPhotos))
        XCTAssertEqual(allPhotos.label, "查看所有照片")
        XCTAssertFalse(app.buttons["library-countries-back"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["photo-wall-title"].label, "🇮🇸 冰岛")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).allElementsBoundByIndex.allSatisfy {
            $0.identifier.hasPrefix("viewport-photo-sample-reykjavik-")
        })
        attach(app, "Country photos")
        XCTAssertTrue(focus(photo))
        XCTAssertFalse(app.descendants(matching: .any)["place-library"].firstMatch.isHittable, "The modal wall must exclude its underlying library from interaction")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(allPhotos))
        XCUIRemote.shared.press(.down)
        let classifiedCity = app.buttons["library-collection-country:region:IS/city:sample-reykjavik"]
        XCTAssertTrue(focus(classifiedCity))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["雷克雅未克"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).allElementsBoundByIndex.allSatisfy {
            $0.identifier.hasPrefix("viewport-photo-sample-reykjavik-")
        })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(classifiedCity))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(country.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(country))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(brazil))
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.buttons["library-countries-back"].exists)
        XCTAssertTrue(focus(allPhotos))
        XCUIRemote.shared.press(.select)
        let brazilianPhoto = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-sample-rio-'")).firstMatch
        XCTAssertTrue(brazilianPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).allElementsBoundByIndex.allSatisfy {
            $0.identifier.hasPrefix("viewport-photo-sample-rio-")
        })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(allPhotos))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(brazil), "Country navigation preserves the originating country")
        app.openSidebarDestination("tab-settings")
        XCTAssertTrue(app.buttons["settings-scan"].waitForExistence(timeout: 5))
        attach(app, "Settings")
        XCTAssertTrue(focus(app.buttons["settings-scan"]))
        XCUIRemote.shared.press(.right)
        let hints = app.descendants(matching: .any)["settings-globe-hints"].firstMatch
        XCTAssertTrue(focusHomeScreenSwitch(in: app))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(hints))
        let original = hints.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(hints.value as? String, original)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(hints.value as? String, original)
        app.openSidebarDestination("tab-home")
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
    }

    @MainActor func testCityJourneysExpandAndCollapseOnTheSameWall() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-journeys-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-countries")

        let remote = XCUIRemote.shared
        XCTAssertTrue(focus(app.buttons["library-collection-country:region:JP"]))
        attach(app, "Japan cover from the latest trip")
        remote.press(.select)
        XCTAssertTrue(focus(app.buttons["library-country-photos"]))
        remote.press(.down)
        let city = app.buttons["library-collection-country:region:JP/city:tokyo-return,tokyo-arrival,tokyo-older"]
        XCTAssertTrue(focus(city))
        remote.press(.select)
        let first = app.buttons["viewport-photo-sample-rio-5"]
        let lastOld = app.buttons["viewport-photo-sample-sydney-1"]
        let hidden = app.buttons["viewport-photo-sample-tokyo-5"]
        let toggle = app.buttons["journey-toggle-city-trip:tokyo-arrival"]
        XCTAssertTrue(focus(first))
        XCTAssertEqual(app.staticTexts["photo-wall-title"].label, "东京")
        XCTAssertEqual(app.staticTexts["photo-wall-count"].label, "15 项")
        XCTAssertTrue(lastOld.waitForExistence(timeout: 5))
        XCTAssertFalse(hidden.exists)
        XCTAssertFalse(app.buttons["journey-toggle-city-trip:tokyo-older"].exists)
        attach(app, "Tokyo trips inline")
        remote.press(.up)
        XCTAssertTrue(focus(toggle))
        remote.press(.select)
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.label.contains("收起"))
        attach(app, "Tokyo trip expanded")
        remote.press(.select)
        XCTAssertTrue(toggle.label.contains("展开"))
        XCTAssertFalse(hidden.exists)
        XCTAssertTrue(lastOld.exists)
        remote.press(.down)
        let fifthPhoto = app.buttons["viewport-photo-sample-rio-1"]
        XCTAssertTrue(focus(fifthPhoto))
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["photo-detail-image"].firstMatch.waitForExistence(timeout: 5))
        remote.press(.right)
        remote.press(.menu)
        XCTAssertTrue(focus(hidden), "Returning from the sixth photo reveals its row")
        XCTAssertTrue(toggle.label.contains("收起"))
        remote.press(.menu)
        if !city.exists {
            XCTAssertTrue(focus(first))
            remote.press(.menu)
        }
        XCTAssertTrue(focus(city))
    }

    @MainActor func testBackFromScrolledCountriesReturnsToTopBeforeOpeningSidebar() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-countries")

        let first = app.buttons["library-collection-country:region:IS"]
        XCTAssertTrue(focus(first))
        let topFrame = first.frame
        for region in ["AU", "US"] {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(focus(app.buttons["library-collection-country:region:\(region)"]))
        }
        XCTAssertLessThan(first.frame.minY, topFrame.minY - 20)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(first))
        XCTAssertEqual(first.frame.minY, topFrame.minY, accuracy: 2)
        attach(app, "Country list after Back to top")

        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["library-collection-sample-reykjavik"]))
    }

    @MainActor func testRecentJourneyPreferencePersistsAcrossRelaunchAndRestores() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        func openSettings() {
            app.launch()
            app.enterHomeContent()
            app.openSidebarDestination("tab-settings")
            XCTAssertTrue(focus(app.buttons["settings-scan"]))
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(focusHomeScreenSwitch(in: app))
        }
        openSettings()
        let preference = app.descendants(matching: .any)["settings-top-shelf"].firstMatch
        XCTAssertEqual(preference.label, "显示最近到访的城市")
        let original = try XCTUnwrap(preference.value as? String)
        let changed = original == "已开启" ? "已关闭" : "已开启"
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(preference.value as? String, changed)
        XCTAssertTrue(preference.hasFocus)
        attach(app, "Recent journeys — Home Screen preference")
        app.terminate()
        openSettings()
        XCTAssertEqual(preference.value as? String, changed)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(preference.value as? String, original)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(app.descendants(matching: .any)["settings-globe-hints"].firstMatch))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(app.descendants(matching: .any)["settings-wait-for-globe"].firstMatch))
    }

    @MainActor func testSetRealHomeShelfVisibility() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the prepared real Apple TV library")
#else
        let requested = ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_TOP_SHELF_SETTING"]
        try XCTSkipUnless(requested == "on" || requested == "off",
                          "Set PHOTOEARTH_REAL_TV_TOP_SHELF_SETTING to on or off")
        let desired = requested == "on" ? "已开启" : "已关闭"
        let app = XCUIApplication()
        app.launchArguments = ["--qa-shelf-report"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let scope = app.buttons["settings-scan-scope"]
        if !scope.exists {
            XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 90),
                          "The prepared real library must be available before changing its Home Screen preference")
            app.openSidebarDestination("tab-settings")
        }
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "Settings must belong to the live Photos library")
        let shelf = app.descendants(matching: .any)["settings-top-shelf"].firstMatch
        let hints = app.descendants(matching: .any)["settings-globe-hints"].firstMatch
        let imagery = app.descendants(matching: .any)["settings-wait-for-globe"].firstMatch
        let deadline = Date().addingTimeInterval(12)
        while !shelf.hasFocus && Date() < deadline {
            // The native sidebar and then the two Settings columns are reached
            // by Right. Within the right column, Home Screen is its first row.
            let inRightColumn = hints.hasFocus || imagery.hasFocus
            XCUIRemote.shared.press(inRightColumn ? .up : .right)
        }
        XCTAssertTrue(shelf.hasFocus, "The focused control must be the Home Screen preference")
        let previous = try XCTUnwrap(shelf.value as? String)
        XCTAssertTrue(["已开启", "已关闭"].contains(previous))
        if previous != desired { XCUIRemote.shared.press(.select) }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", desired), object: shelf)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        XCTAssertTrue(shelf.hasFocus)
        let capture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = "Real Apple TV Home Screen setting " + (requested ?? "")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCUIRemote.shared.press(.home)
        let pixels = try XCTUnwrap(capture.image.cgImage)
        XCTAssertEqual(pixels.width, 3840)
        XCTAssertEqual(pixels.height, 2160)
#endif
    }

    @MainActor private func focusHomeScreenSwitch(in app: XCUIApplication) -> Bool {
        let shelf = app.descendants(matching: .any)["settings-top-shelf"].firstMatch
        let hints = app.descendants(matching: .any)["settings-globe-hints"].firstMatch
        let imagery = app.descendants(matching: .any)["settings-wait-for-globe"].firstMatch
        for _ in 0..<2 {
            if shelf.hasFocus { return true }
            if hints.hasFocus || imagery.hasFocus { XCUIRemote.shared.press(.up) }
        }
        return focus(shelf)
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
