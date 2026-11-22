import XCTest

final class ContinuousPhotoViewingTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPlayableMediaSupportsVisibleButtonAndRemote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture", "--playback-control-fixture", "-photoEarth.mosaicPhotoWall", "NO"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-0"]))
        XCUIRemote.shared.press(.select)
        let livePhotoCard = app.buttons["viewport-photo-sample-ratio-landscape-60"]
        XCTAssertTrue(focus(livePhotoCard))
        XCTAssertTrue(livePhotoCard.label.contains("Live Photo"), "The card must keep its accessible media type")
        XCTAssertFalse(app.staticTexts["Live Photo"].exists, "The visible wall badge must be icon-only")
        attach(app, "Live Photo with inline date — landscape")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        let portrait = app.buttons["viewport-photo-sample-ratio-portrait-58"]
        XCTAssertTrue(focus(portrait))
        XCTAssertTrue(portrait.label.contains("Live Photo"))
        attach(app, "Live Photo with inline date — narrow portrait")
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(focus(livePhotoCard))
        XCUIRemote.shared.press(.select)

        let media = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(media))
        XCTAssertFalse(app.buttons["photo-detail-show-controls"].exists)
        let playButton = app.buttons["photo-detail-playback"]
        XCTAssertTrue(playButton.exists)
        XCTAssertFalse(app.staticTexts["Live Photo"].exists)
        XCTAssertTrue(app.staticTexts["photo-detail-capture-time"].exists)

        let globe = app.buttons["photo-location-globe"]
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(playButton))
        attach(app, "Photo detail with regional preview and focused playback button")
        XCUIRemote.shared.press(.select)
        let error = app.descendants(matching: .any)["photo-detail-motion-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "The fixture has no motion resource")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(focus(media))
        XCUIRemote.shared.press(.right)
        let videoPosition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Video 2"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [videoPosition], timeout: 5), .completed)
        XCTAssertFalse(error.exists)
        XCTAssertTrue(playButton.exists)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
    }

    @MainActor func testContinuousViewingCrossesPageBoundaryAndReturnsToLastPhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(focus(app.buttons["library-collection-sample-ratio-place-0"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-ratio-landscape-60"]))
        XCUIRemote.shared.press(.select)
        let photo = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(focus(photo))
        XCTAssertFalse(app.buttons["photo-detail-show-controls"].exists)
        XCTAssertFalse(app.buttons["photo-information-toggle"].exists)
        XCTAssertTrue(app.buttons["photo-location-globe"].exists)
        XCTAssertFalse(app.buttons["photo-detail-playback"].exists)
        let captureTime = app.staticTexts["photo-detail-capture-time"]
        XCTAssertTrue(captureTime.exists)
        let initialTime = captureTime.label
        assertPosition(1, photo: photo)
        for position in 2...49 {
            XCUIRemote.shared.press(.right)
            assertPosition(position, photo: photo)
        }
        // Reverse immediately across 49/48; pending page work cannot move us
        // forward again, and Back must restore this last actual photo.
        XCUIRemote.shared.press(.left)
        assertPosition(48, photo: photo)
        attach(app, "Continuous detail — pure full-frame photo after page boundary")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-ratio-portrait-13"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(photo))
        assertPosition(48, photo: photo)
        XCTAssertNotEqual(captureTime.label, initialTime)
        XCTAssertTrue(app.staticTexts["photo-detail-location-name"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-ratio-portrait-13"]))
    }

    @MainActor private func assertPosition(_ position: Int, photo: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Photo \(position)"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 8) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 5) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
