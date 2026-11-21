import XCTest

final class ExperienceScopeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testCityScopeSurvivesDraggingUntilExplicitCurrentViewSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND hasFocus == true", "overview-place-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        let scope = app.staticTexts["globe-photo-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        let original = scope.label
        XCTAssertTrue(original.contains("City photos only"))
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCTAssertEqual(scope.label, original)
        attach(app, "City scope remains visible")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(focus(app.buttons["globe-zoom-in"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(app.buttons["globe-use-current-view"]))
        XCUIRemote.shared.press(.right)
        let style = app.buttons["globe-style"]
        XCTAssertTrue(focus(style))
        let manualStyle = style.label == "Map" ? "Satellite" : "Map"
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(style.label, manualStyle)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        XCTAssertEqual(scope.label, original)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(focus(app.buttons["globe-zoom-in"]))
        XCTAssertEqual(style.label, manualStyle, "Reopening controls retains the selected map style")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(app.buttons["globe-use-current-view"]))
        attach(app, "Explicit scope control in Glass Dock")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(globe))
        XCTAssertFalse(scope.exists, "The city-only indicator disappears when the globe follows the current view")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Memories in This View"].waitForExistence(timeout: 6))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        XCTAssertFalse(scope.exists, "The city-only indicator disappears when the globe follows the current view")
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
