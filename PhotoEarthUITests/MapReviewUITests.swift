import XCTest

final class MapReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testCountryAndClassifiedCityWallsShareReviewAndRestorePagedPhotoFocus() throws {
        let app = XCUIApplication()
        launchFixture(app)
        app.openSidebarDestination("tab-countries")
        XCTAssertTrue(focus(app.buttons["library-collection-country:region:FR"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["library-country-photos"]))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertTrue(focus(first))
        XCUIRemote.shared.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        for _ in 0..<48 { XCUIRemote.shared.press(.right) }
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '49'"), object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 8), .completed)
        XCUIRemote.shared.press(.menu)
        let paged = app.buttons["viewport-photo-sample-paris-49"]
        XCTAssertTrue(focus(paged))
        try reviewAndReturn(app, to: paged)
        scrollDownAndReturnToTop(app, first: first)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["library-country-photos"]))
        XCUIRemote.shared.press(.down)
        let city = app.buttons["library-collection-country:region:FR/city:sample-map-review"]
        XCTAssertTrue(focus(city))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(first))
        try reviewAndReturn(app, to: first)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(city))
    }

    @MainActor func testHomeCityWallOffersTheSameReviewAndKeepsItsCityScope() throws {
        let app = XCUIApplication()
        launchFixture(app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(app.buttons["overview-place-sample-map-review"]))
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(globe))
        let scope = app.staticTexts["globe-photo-scope"].label
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-paris-1"]
        scrollDownAndReturnToTop(app, first: first)
        try reviewAndReturn(app, to: first)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        XCTAssertEqual(app.staticTexts["globe-photo-scope"].label, scope)
    }

    @MainActor func testCurrentViewportWallReturnsToItsExistingMap() throws {
        let app = XCUIApplication()
        launchFixture(app)
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertTrue(focus(first))
        XCTAssertFalse(app.buttons["photo-wall-map-review"].exists)
        XCTAssertFalse(app.buttons["photo-wall-back"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        let viewportMap = XCTAttachment(screenshot: app.screenshot())
        viewportMap.name = "Current viewport wall reuses the shared map"; viewportMap.lifetime = .keepAlways; add(viewportMap)
    }

    @MainActor func testDirectMapPlayPauseZoomAndPhotographicClusters() throws {
        let app = XCUIApplication()
        let map = try enterReview(app)
        XCTAssertTrue(focus(map))
        let ready = app.staticTexts["map-review-count"].waitForExistence(timeout: 12)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Initial direct map review"; initial.lifetime = .keepAlways; add(initial)
        if !ready { print(app.debugDescription) }
        XCTAssertTrue(ready)
        XCTAssertTrue(app.staticTexts["map-review-count"].label.contains("125"))
        let stripTitle = app.staticTexts["memory-horizon-title"]
        let stripCount = app.staticTexts["map-review-count"]
        XCTAssertEqual(stripCount.frame.midY, stripTitle.frame.midY, accuracy: 4,
                       "The complete viewport count belongs beside the filmstrip title")
        XCTAssertGreaterThan(stripCount.frame.minX, stripTitle.frame.maxX)
        let group = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'map-review-pin-' AND label CONTAINS '120'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'map-review-pin-' ")).firstMatch.exists)
        XCTAssertFalse(app.buttons["map-review-move"].exists)
        let originalPinFrame = group.frame
        let before = map.value as? String
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(group.exists, "Movement must retain the photographic cluster")
        XCTAssertLessThan(group.frame.midX, originalPinFrame.midX - 1,
                          "The retained cluster must track its geographic position")
        let movingPins = XCTAttachment(screenshot: app.screenshot())
        movingPins.name = "Photographic pins follow map movement"; movingPins.lifetime = .keepAlways; add(movingPins)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in map.value as? String != before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 8), .completed)
        XCTAssertTrue(focus(map))
        XCUIRemote.shared.press(.playPause)
        let zoom = app.buttons["map-review-zoom-in"]
        let zoomFocused = focus(zoom)
        let dock = XCTAttachment(screenshot: app.screenshot())
        dock.name = "Direct map review zoom dock"; dock.lifetime = .keepAlways; add(dock)
        if !zoomFocused { print(app.debugDescription) }
        XCTAssertTrue(zoomFocused)
        XCTAssertFalse(app.descendants(matching: .any)["photo-wall"].firstMatch.exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(zoom))
        XCUIRemote.shared.press(.right)
        let style = app.buttons["map-review-style"]
        XCTAssertTrue(focus(style))
        XCTAssertTrue(style.label.contains("地图"))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(style.label.contains("卫星"))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(style.label.contains("地图"))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(focus(zoom))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(focus(app.buttons["map-review-zoom-out"]))
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(map))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Direct map review, photographic clusters and viewport horizon"
        screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["viewport-photo-sample-paris-1"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(map))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-1"]))
    }

    @MainActor func testEmptyViewportShowsCompactStatusWithoutReservingPhotoRow() throws {
        let app = XCUIApplication()
        let map = try enterReview(app)
        XCTAssertTrue(focus(map))
        XCTAssertTrue(app.staticTexts["map-review-count"].waitForExistence(timeout: 12))
        let horizon = app.descendants(matching: .any)["memory-horizon"].firstMatch
        let populatedHeight = horizon.frame.height
        for _ in 0..<40 { XCUIRemote.shared.press(.right) }
        let empty = app.staticTexts["memory-horizon-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 15))
        XCTAssertEqual(empty.label, "当前画面没有照片")
        XCTAssertFalse(app.staticTexts["map-review-count"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["memory-horizon-photos"].firstMatch.exists)
        XCTAssertLessThan(horizon.frame.height, populatedHeight - 60,
                          "An empty view removes the thumbnail-row reservation")
        XCTAssertTrue(focus(map))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Empty map review — compact status over an unobscured map"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let group = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'map-review-pin-' AND label CONTAINS '120'")).firstMatch
        for round in 0..<3 {
            if round > 0 {
                for _ in 0..<40 { XCUIRemote.shared.press(.right) }
                XCTAssertTrue(empty.waitForExistence(timeout: 15))
            }
            for _ in 0..<40 { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(app.staticTexts["map-review-count"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["map-review-count"].label.contains("125"))
            XCTAssertTrue(group.waitForExistence(timeout: 8), "Photo pins return after each empty-to-populated movement")
            XCTAssertTrue(focus(map))
        }
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Map review pins restored after repeated viewport round trips"
        restored.lifetime = .keepAlways; add(restored)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-1"]))
    }

    @MainActor func testViewportWallCrossesPageBoundaryAndReturnsThroughMap() throws {
        let app = XCUIApplication()
        let map = try enterReview(app)
        XCTAssertTrue(focus(map))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertFalse(app.buttons.matching(identifier: "photo-wall-map-review")
            .matching(NSPredicate(format: "isEnabled == true")).firstMatch.exists)
        scrollDownAndReturnToTop(app, first: first)
        let wallTop = first.frame.minY
        XCUIRemote.shared.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        for _ in 0..<48 { XCUIRemote.shared.press(.right) }
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '49'"), object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 8), .completed)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-49"]))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(first), "Back from the restored detail position first returns to the top")
        XCTAssertEqual(first.frame.minY, wallTop, accuracy: 2)
        XCUIRemote.shared.press(.menu)
        let didRestoreMap = focus(map)
        if !didRestoreMap {
            print(app.debugDescription)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Active screen when Back from the wall failed"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(didRestoreMap)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-1"]))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["library-collection-sample-map-review"]))
    }

    @MainActor private func scrollDownAndReturnToTop(_ app: XCUIApplication, first: XCUIElement) {
        XCTAssertTrue(focus(first))
        let firstFrame = first.frame
        XCTAssertFalse(app.buttons["photo-wall-back"].exists)
        for _ in 0..<5 { XCUIRemote.shared.press(.down) }
        if first.exists { XCTAssertLessThan(first.frame.minY, firstFrame.minY) }
        XCUIRemote.shared.press(.menu)
        let restoredFirst = focus(first)
        if !restoredFirst { print(app.debugDescription) }
        XCTAssertTrue(restoredFirst, "Back after scrolling down restores the first photo")
        XCTAssertEqual(first.frame.minY, firstFrame.minY, accuracy: 2)
    }

    @MainActor private func enterReview(_ app: XCUIApplication) throws -> XCUIElement {
        launchFixture(app)
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(focus(app.buttons["library-collection-sample-map-review"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-1"]))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(focus(app.buttons["photo-wall-map-review"]))
        XCUIRemote.shared.press(.select)
        return app.descendants(matching: .any)["map-review-direct-manipulation"].firstMatch
    }

    @MainActor private func launchFixture(_ app: XCUIApplication) {
        app.launchArguments = ["--demo", "--map-review-fixture"]
        app.useSimplifiedChineseTestLanguage(); app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
    }

    @discardableResult
    @MainActor private func reachReviewEntry(_ app: XCUIApplication) -> String? {
        let entry = app.buttons.matching(identifier: "photo-wall-map-review")
            .matching(NSPredicate(format: "isEnabled == true")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        var lastPhotoID: String?
        for _ in 0..<20 {
            if entry.hasFocus { break }
            let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-' AND hasFocus == true")).firstMatch
            if photo.exists { lastPhotoID = photo.identifier }
            let slideshow = app.buttons.matching(identifier: "photo-wall-slideshow")
                .matching(NSPredicate(format: "isEnabled == true")).firstMatch
            let layout = app.buttons["photo-wall-switch-layout"]
            if (slideshow.exists && slideshow.hasFocus) || (layout.exists && layout.hasFocus) { XCUIRemote.shared.press(.left) }
            else { XCUIRemote.shared.press(.up) }
        }
        XCTAssertTrue(focus(entry))
        return lastPhotoID
    }

    @MainActor private func reviewAndReturn(_ app: XCUIApplication, to photo: XCUIElement) throws {
        let title = app.staticTexts["photo-wall-title"].label
        // Native navigation to the fixed header can pass earlier photo rows.
        // Restore the actual last photo focus before entering review.
        let returnID = reachReviewEntry(app) ?? photo.identifier
        XCUIRemote.shared.press(.select)
        let map = app.descendants(matching: .any)["map-review-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(map))
        XCTAssertTrue(app.staticTexts["map-review-count"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["map-review-count"].label.contains("125"))
        let opening = XCTAttachment(screenshot: app.screenshot())
        opening.name = "Shared Map Review from \(title)"; opening.lifetime = .keepAlways; add(opening)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(focus(app.buttons["map-review-zoom-in"]))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(map))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons[returnID]))
        XCTAssertEqual(app.staticTexts["photo-wall-title"].label, title)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Restored source wall for \(title)"; restored.lifetime = .keepAlways; add(restored)
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 8) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 5) == .completed
    }
}
