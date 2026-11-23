import XCTest

@MainActor final class OnThisDayUITests: XCTestCase {
    func testPastYearsOpenExactPhotosAndRestoreRemoteFocus() {
        let app = launch(empty: false)
        let remote = XCUIRemote.shared
        let first = app.buttons["viewport-photo-sample-paris-1"]
        let previous = app.buttons["anniversary-previous"]
        let date = app.buttons["anniversary-date"]
        let year = Calendar.current.component(.year, from: .now)
        let currentTitle = date.label
        XCTAssertTrue(first.waitForExistence(timeout: 12), app.debugDescription)
        if !previous.hasFocus { remote.press(.left) }
        XCTAssertTrue(focused(previous), app.debugDescription)
        remote.press(.select)
        XCTAssertTrue(app.buttons["viewport-photo-sample-rio-1"].waitForExistence(timeout: 8))
        XCTAssertNotEqual(date.label, currentTitle)
        remote.press(.right)
        XCTAssertTrue(focused(date))
        remote.press(.select)
        let today = app.buttons["anniversary-today"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        let month = app.buttons["anniversary-month"]
        if !today.hasFocus && !month.hasFocus { remote.press(.up) }
        if !today.hasFocus { remote.press(.right) }
        XCTAssertTrue(focused(today), app.debugDescription)
        attach("02-date-picker", app)
        remote.press(.select)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertEqual(date.label, currentTitle)
        remote.press(.down)
        XCTAssertTrue(focused(first), app.debugDescription)
        XCTAssertTrue(app.staticTexts["anniversary-empty"].firstMatch.exists)
        let currentYear = app.staticTexts["anniversary-year-\(year)"]
        XCTAssertTrue(currentYear.exists)
        XCTAssertLessThan(currentYear.frame.midY, app.staticTexts["anniversary-year-\(year - 1)"].frame.midY)
        let locations = app.staticTexts["anniversary-locations-\(year)"]
        let names = locations.label.components(separatedBy: "·")
        XCTAssertEqual(names.count, 3, locations.label)
        for (entry, city) in zip(names, ["巴黎", "伦敦", "布鲁塞尔"]) {
            XCTAssertTrue(entry.contains(city), locations.label)
        }
        XCTAssertFalse(app.staticTexts["anniversary-locations-\(year - 1)"].exists)
        attach("01-anniversary-wall", app)
        remote.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        XCTAssertTrue(focused(image))
        remote.press(.right)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "2"), object: image)], timeout: 6), .completed, app.debugDescription)
        remote.press(.menu)
        XCTAssertTrue(focused(app.buttons["viewport-photo-sample-istanbul-102"]), app.debugDescription)
        for _ in 0..<4 { remote.press(.right) }
        let expand = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'anniversary-expand-'")).firstMatch
        XCTAssertTrue(focused(expand), app.debugDescription)
        remote.press(.select)
        let sixth = app.buttons["viewport-photo-sample-cape-town-106"]
        XCTAssertTrue(sixth.waitForExistence(timeout: 8), app.debugDescription)
        attach("03-expanded-year", app)
        remote.press(.select)
        XCTAssertTrue(sixth.waitForNonExistence(timeout: 8))
        remote.press(.up)
        XCTAssertTrue(focused(app.buttons["anniversary-play"]))
        remote.press(.select)
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(focused(begin), app.debugDescription)
        remote.press(.select)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 25), app.debugDescription)
        let rail = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        XCTAssertTrue(rail.label.contains(String(year)), rail.label)
        attach("04-slideshow", app)
        remote.press(.select)
        let play = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(focused(play))
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(focused(app.buttons["slideshow-next-journey"]))
        remote.press(.select)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", String(year)), object: rail)], timeout: 10), .completed)
        XCTAssertTrue(media.waitForExistence(timeout: 10))
        if play.exists { remote.press(.menu) }
        let olderMedia = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "sample-tokyo-"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [olderMedia], timeout: 10), .completed)
        attach("05-earlier-year", app)
        app.confirmSlideshowExit()
        XCTAssertTrue(focused(app.buttons["anniversary-play"]), app.debugDescription)
    }

    func testVerticalScrollingKeepsPhotosAlignedWithTheYearColumn() {
        let app = launch(empty: false)
        let remote = XCUIRemote.shared
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let year = Calendar.current.component(.year, from: .now)
        let location = app.staticTexts["anniversary-locations-\(year)"]
        let columnX = location.frame.minX
        XCTAssertGreaterThan(columnX, app.buttons["anniversary-previous"].frame.maxX)
        remote.press(.down)
        XCTAssertTrue(focused(first))
        for _ in 0..<5 { remote.press(.right) }
        let expand = app.buttons["anniversary-expand-\(year)"]
        XCTAssertTrue(focused(expand))
        XCTAssertEqual(location.frame.minX, columnX, accuracy: 2)
        remote.press(.select)
        for _ in 0..<5 { remote.press(.left) }
        XCTAssertTrue(focused(first))
        let focusedX = first.frame.minX
        for _ in 0..<5 { remote.press(.down) }
        let lower = app.buttons["viewport-photo-sample-banff-126"]
        XCTAssertTrue(focused(lower), app.debugDescription)
        XCTAssertEqual(lower.frame.minX, focusedX, accuracy: 2)
        XCTAssertGreaterThan(lower.frame.minX, app.buttons["anniversary-previous"].frame.maxX)
        for _ in 0..<5 { remote.press(.up) }
        XCTAssertTrue(focused(first))
        XCTAssertEqual(location.frame.minX, columnX, accuracy: 2)
    }

    func testDetailCrossesFoldAndReturnsToNewlyVisiblePhoto() {
        let app = launch(empty: false)
        let remote = XCUIRemote.shared
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        remote.press(.down)
        XCTAssertTrue(focused(first))
        let firstColumnX = first.frame.minX
        for _ in 0..<4 { remote.press(.right) }
        XCTAssertTrue(focused(app.buttons["viewport-photo-sample-banff-105"]))
        remote.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(focused(image))
        remote.press(.right)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "6"), object: image)], timeout: 8), .completed)
        remote.press(.menu)
        let sixth = app.buttons["viewport-photo-sample-cape-town-106"]
        XCTAssertTrue(focused(sixth), app.debugDescription)
        XCTAssertEqual(sixth.frame.minX, firstColumnX, accuracy: 2)
    }

    func testEmptyAnniversaryReturnsToNativeSidebar() {
        let app = launch(empty: true)
        XCTAssertTrue(app.staticTexts["anniversary-empty"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["anniversary-play"].isEnabled)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch.exists)
        attach("06-empty-years", app)
        app.openSidebarDestination("tab-home")
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 8))
    }

    func testReturningToAnOffscreenPhotoPreservesItsColumn() {
        let app = launch(empty: false)
        let remote = XCUIRemote.shared
        let first = app.buttons["viewport-photo-sample-paris-1"]
        let fifth = app.buttons["viewport-photo-sample-banff-105"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        remote.press(.down)
        XCTAssertTrue(focused(first))
        for _ in 0..<4 { remote.press(.right) }
        XCTAssertTrue(focused(fifth))
        let columnX = fifth.frame.minX
        remote.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(focused(image))
        for _ in 0..<25 { remote.press(.right) }
        remote.press(.menu)
        let thirtieth = app.buttons["viewport-photo-sample-istanbul-130"]
        XCTAssertTrue(focused(thirtieth), app.debugDescription)
        XCTAssertEqual(thirtieth.frame.minX, columnX, accuracy: 2)
    }

    private func launch(empty: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--anniversary-fixture", "--slideshow-observe-media"] + (empty ? ["--anniversary-empty"] : [])
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 55), app.debugDescription)
        XCTAssertTrue(app.buttons["library-preparation-entry"].waitForNonExistence(timeout: 60),
                      "Wait for the fixture scan to finish before navigating the sidebar")
        app.enterHomeContent()
        app.openSidebarDestination("tab-anniversary")
        return app
    }

    private func focused(_ element: XCUIElement) -> Bool {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter.wait(for: [wait], timeout: 10) == .completed
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
