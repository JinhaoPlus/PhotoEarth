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
        app.launchArguments = ["--demo", "--photo-ratio-fixture", "-photoEarth.mosaicPhotoWall", "NO"]
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
        // In this single-city wall both focused and unfocused cards end at
        // the image edge. A persistent date footer would change these ratios.
        XCTAssertEqual(first.frame.width / first.frame.height, 1.5, accuracy: 0.02)
        XCTAssertEqual(portrait.frame.width / portrait.frame.height, 2.0 / 3.0, accuracy: 0.02)
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
        XCTAssertTrue(app.staticTexts["60 项"].waitForExistence(timeout: 8))
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

    @MainActor func testWallSwitchesLayoutsAndRemembersTheChoiceAcrossWalls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-recent")
        let collection = app.buttons["library-collection-sample-ratio-place-0"]
        XCTAssertTrue(focus(collection))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-ratio-landscape-60"]
        let second = app.buttons["viewport-photo-sample-ratio-panorama-59"]
        let toggle = app.descendants(matching: .any)["photo-wall-switch-layout"].firstMatch
        XCTAssertTrue(focus(first))

        XCTAssertEqual(toggle.frame.height, app.buttons["photo-wall-map-review"].frame.height, accuracy: 1)
        XCTAssertEqual(toggle.frame.height, app.buttons["photo-wall-slideshow"].frame.height, accuracy: 1)

        func focusLayoutSwitch() {
            XCUIRemote.shared.press(.up)
            for _ in 0..<2 where !toggle.hasFocus { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(focus(toggle))
            XCTAssertEqual(toggle.label, "照片墙布局")
        }

        func selectLayout(_ expectedLayout: String) {
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(toggle.value as? String, expectedLayout)
            XCTAssertTrue(focus(toggle))
        }

        attach(app, "Photo wall on entry with saved or default layout")
        if first.frame.width > second.frame.width {
            focusLayoutSwitch()
            selectLayout("原比例")
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(focus(first))
        }
        let nextRow = app.buttons["viewport-photo-sample-ratio-panorama-56"]
        let nextRowY = nextRow.frame.minY
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(second))
        XCTAssertEqual(nextRow.frame.minY, nextRowY, accuracy: 1)
        attach(app, "Original ratios with the date on the focused panorama")

        focusLayoutSwitch()
        selectLayout("拼贴布局")
        selectLayout("原比例")
        selectLayout("拼贴布局")
        attach(app, "Layout switch retains focus after repeated selection")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(focus(app.buttons["photo-wall-slideshow"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(toggle))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(first))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(second))
        XCTAssertEqual(first.frame.width, 2 * second.frame.width + 4, accuracy: 2)
        XCTAssertEqual(second.frame.height, second.frame.width, accuracy: 1)
        let mosaicWidth = first.frame.width
        let below = app.buttons["viewport-photo-sample-ratio-panorama-56"]
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(below))
        attach(app, "Mosaic with focus in the lower row")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["photo-detail-image"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(below))
        XCUIRemote.shared.press(.menu)
        let backSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (collection.exists && collection.hasFocus) || (first.exists && first.hasFocus)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backSettled], timeout: 5), .completed)
        if first.exists && first.hasFocus { XCUIRemote.shared.press(.menu) }
        XCTAssertTrue(focus(collection))
        XCUIRemote.shared.press(.right)
        let nextCollection = app.buttons["library-collection-sample-ratio-place-1"]
        XCTAssertTrue(focus(nextCollection))
        XCUIRemote.shared.press(.select)
        let nextFirst = app.buttons["viewport-photo-sample-ratio-portrait-120"]
        XCTAssertTrue(focus(nextFirst))
        XCTAssertEqual(nextFirst.frame.width, mosaicWidth, accuracy: 1)
        focusLayoutSwitch()
        selectLayout("原比例")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(nextFirst))
        XCTAssertLessThan(nextFirst.frame.width, nextFirst.frame.height)

        app.terminate()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(focus(collection))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(first))
        XCTAssertLessThan(first.frame.width, second.frame.width, "Relaunch must keep the selected original ratios")
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
