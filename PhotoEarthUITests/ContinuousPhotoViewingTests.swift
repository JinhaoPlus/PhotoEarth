import XCTest

final class ContinuousPhotoViewingTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPlayableMediaHasImmediateBottomTrailingPlaybackControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture", "--playback-control-fixture"]
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
        attach(app, "Photo wall — Live Photo icon-only badge")
        XCUIRemote.shared.press(.select)

        let media = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        let playback = app.buttons["photo-detail-playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 3), "Playback must be visible before the detail controls are opened")
        let showControls = app.buttons["photo-detail-show-controls"]
        XCTAssertTrue(showControls.waitForExistence(timeout: 3), "More Actions must remain visible in the pure viewing state")
        XCTAssertGreaterThan(showControls.frame.midX, app.frame.width / 2)
        XCTAssertLessThan(showControls.frame.midY, app.frame.height / 2)
        let immediateActionFocus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            media.hasFocus || playback.hasFocus
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [immediateActionFocus], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["photo-information-toggle"].exists)
        XCTAssertFalse(app.staticTexts["Live Photo"].exists, "The lower-left Live Photo badge must be icon-only")
        XCTAssertGreaterThan(playback.frame.midX, app.frame.width / 2)
        XCTAssertGreaterThan(playback.frame.midY, app.frame.height / 2)
        attach(app, "Live Photo — immediate playback control and icon-only badge")

        XCUIRemote.shared.press(.select)
        let retryReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Try Motion Again"), object: playback)
        XCTAssertEqual(XCTWaiter.wait(for: [retryReady], timeout: 5), .completed,
                       "One Select press on the initial playback focus must start the playback request")

        XCUIRemote.shared.press(.right)
        let videoPosition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Video 2"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [videoPosition], timeout: 5), .completed)
        XCTAssertTrue(playback.exists, "The same immediate control must remain available for video")
        attach(app, "Video — immediate bottom-trailing playback control")
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
        let showControls = app.buttons["photo-detail-show-controls"]
        XCTAssertTrue(showControls.waitForExistence(timeout: 3), "Static photos must expose More Actions without a hidden gesture")
        XCTAssertFalse(app.buttons["photo-information-toggle"].exists)
        XCTAssertFalse(app.buttons["photo-location-globe"].exists)
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
        XCUIRemote.shared.press(.select)
        let info = app.buttons["photo-information-toggle"]
        XCTAssertTrue(focus(info))
        XCTAssertTrue(app.buttons["photo-location-globe"].exists)
        attach(app, "Continuous detail — explicitly requested controls")
        // Longer than the passive introductory hint: a focused operation may
        // never vanish because of a timer.
        let remainsFocused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == false"), object: info)
        remainsFocused.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [remainsFocused], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Captured"].waitForExistence(timeout: 3))
        attach(app, "Continuous detail — information and optional location map")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(photo))
        XCTAssertTrue(showControls.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["photo-location-globe"].exists)
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
