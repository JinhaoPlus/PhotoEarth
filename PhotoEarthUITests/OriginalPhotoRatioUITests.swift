import XCTest

final class OriginalPhotoRatioUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testHomeUsesUniformTilesAndCloudCompletionDoesNotChangeFrames() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture", "--home-slow-images"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(app.buttons["overview-place-sample-ratio-place-0"]))
        attach(app, "Wide city covers above the year shelves")
        XCUIRemote.shared.press(.down)
        let panorama = app.buttons["overview-place-sample-ratio-place-5"]
        XCTAssertTrue(focus(panorama))
        let landscape = app.buttons["overview-place-sample-ratio-place-6"]
        let portrait = app.buttons["overview-place-sample-ratio-place-7"]
        // The focused tile has the established 1.025 focus scale.
        XCTAssertEqual(panorama.frame.width / landscape.frame.width, 1.025, accuracy: 0.015)
        XCTAssertEqual(portrait.frame.width, landscape.frame.width, accuracy: 1)
        XCTAssertEqual(landscape.frame.height, portrait.frame.height, accuracy: 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "overview-year-2025").count, 1)
        let before = portrait.frame
        attach(app, "Uniform home tiles before cloud completion")
        for card in [panorama, landscape, portrait] {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "照片已加载"), object: card)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        }
        attach(app, "Square home covers after cloud completion")
        XCTAssertEqual(before.minX, portrait.frame.minX, accuracy: 1)
        XCTAssertEqual(before.minY, portrait.frame.minY, accuracy: 1)
        XCTAssertEqual(before.width, portrait.frame.width, accuracy: 1)
        XCTAssertEqual(before.height, portrait.frame.height, accuracy: 1)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(landscape))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(portrait))
    }

    @MainActor func testPhotoWallMixedRatiosPaginateAndReturnToTheSamePhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
        app.openSidebarDestination("tab-recent")
        let collection = app.buttons["library-collection-sample-ratio-place-0"]
        XCTAssertTrue(focus(collection))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-ratio-landscape-60"]
        XCTAssertTrue(focus(first))
        let panorama = app.buttons["viewport-photo-sample-ratio-panorama-59"]
        let portrait = app.buttons["viewport-photo-sample-ratio-portrait-58"]
        XCTAssertGreaterThan(panorama.frame.width / first.frame.width, 1.8)
        XCTAssertLessThan(portrait.frame.width / first.frame.width, 0.5)
        attach(app, "Photo wall preserves landscape portrait and panorama")
        let firstWidth = first.frame.width
        let last = app.buttons["viewport-photo-sample-ratio-portrait-1"]
        // The summary knows there are 60 photos before page two is loaded.
        // Reach the actual final record to prove pagination, rather than using
        // that summary count as evidence that the second page was read.
        for _ in 0..<35 {
            if last.exists, last.hasFocus { break }
            let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-' AND hasFocus == true")).firstMatch
            if last.exists, current.exists, abs(last.frame.midY - current.frame.midY) < 30 {
                XCUIRemote.shared.press(last.frame.midX > current.frame.midX ? .right : .left)
            } else {
                XCUIRemote.shared.press(.down)
            }
        }
        XCTAssertTrue(focus(last))
        XCTAssertTrue(app.staticTexts["60 张照片"].waitForExistence(timeout: 8))
        let selectedID = last.identifier
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["photo-detail-image"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons[selectedID]))
        for _ in 0..<30 {
            if [first, panorama, portrait].contains(where: { $0.exists && $0.hasFocus }) { break }
            XCUIRemote.shared.press(.up)
        }
        // Native vertical focus follows screen position across unequal widths;
        // return horizontally from whichever first-row card it chose.
        for _ in 0..<3 {
            if first.exists, first.hasFocus { break }
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(focus(first))
        XCTAssertEqual(firstWidth, first.frame.width, accuracy: 1)
        attach(app, "First row retains its geometry after pagination")
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 8) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 5) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
