import XCTest

@MainActor final class OnThisDayUITests: XCTestCase {
    func testPastYearsOpenExactPhotosAndRestoreRemoteFocus() {
        let app = launch(empty: false)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'anniversary-year-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(cards.count, 2)
        let yearIDs = cards.allElementsBoundByIndex.map(\.identifier).sorted(by: >)
        let first = app.buttons[yearIDs[0]]
        let second = app.buttons[yearIDs[1]]
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertTrue(first.label.contains("52"), first.label)
        XCTAssertTrue(second.label.contains("3"))
        XCTAssertTrue(focused(first), app.debugDescription)
        attach("01 那年今日", app)
        XCUIRemote.shared.press(.select)
        let wallCount = app.staticTexts["photo-wall-count"]
        XCTAssertTrue(wallCount.waitForExistence(timeout: 8))
        XCTAssertTrue(wallCount.label.contains("52"), wallCount.label)
        let photo = app.buttons["viewport-photo-sample-paris-52"]
        XCTAssertTrue(focused(photo), app.debugDescription)
        attach("02 当日照片墙", app)
        XCUIRemote.shared.press(.select)
        let image = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        attach("03 连续看图", app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused(app.buttons["viewport-photo-sample-paris-51"]), app.debugDescription)
        XCUIRemote.shared.press(.playPause)
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(focused(begin), app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        if !photo.exists { XCUIRemote.shared.press(.menu) }
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused(first), app.debugDescription)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focused(second))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focused(app.buttons["viewport-photo-sample-tokyo-3"]), app.debugDescription)
        XCTAssertTrue(wallCount.label.contains("3"))
    }

    func testEmptyAnniversaryReturnsToNativeSidebar() {
        let app = launch(empty: true)
        let empty = app.descendants(matching: .any)["anniversary-empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'anniversary-year-'")).firstMatch.exists)
        attach("04 空状态", app)
        app.openSidebarDestination("tab-home")
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 8))
    }

    private func launch(empty: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--anniversary-fixture"] + (empty ? ["--anniversary-empty"] : [])
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 55), app.debugDescription)
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
