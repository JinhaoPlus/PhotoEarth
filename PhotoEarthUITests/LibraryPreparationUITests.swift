import XCTest

final class LibraryPreparationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testNeutralWelcomeHasNativeFocusAndOpensExplicitSample() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--welcome-fixture"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        let connect = app.buttons["welcome-connect"]
        let sample = app.buttons["welcome-demo"]
        XCTAssertTrue(connect.waitForExistence(timeout: 12))
        XCTAssertTrue(sample.exists)
        XCTAssertFalse(app.buttons["overview-explore-button"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'overview-place-'")).firstMatch.exists)
        // Give the existing native map time to draw while also verifying the
        // app never leaves welcome or invents a library without a user action.
        let remainsWelcome = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: connect)
        remainsWelcome.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [remainsWelcome], timeout: 4), .completed)
        attach(app, "Neutral welcome — native globe before photo authorization")
        XCUIRemote.shared.press(.down)
        attach(app, "Neutral welcome — explicit sample action in native Focus")
        // Native glass can place the focus on the button's hosting item. The
        // single Select below must activate Sample, independently of AX focus.
        XCUIRemote.shared.press(.select)
        let globe = app.buttons["overview-explore-button"]
        XCTAssertTrue(globe.waitForExistence(timeout: 10))
        app.enterHomeContent()
        XCTAssertTrue(focused(globe))
        XCTAssertTrue(app.staticTexts["Sample Journey"].waitForExistence(timeout: 5))
        XCTAssertFalse(connect.exists)
        attach(app, "Explicit public sample — welcome navigation completed")
    }

    @MainActor func testUnifiedScanCanPauseResumeBrowseAndReopen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preparation-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        let progress = app.descendants(matching: .any)["preparation-status"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 12))
        XCTAssertTrue(focused(progress))
        XCTAssertFalse(app.buttons["返回"].exists)
        attach(app, "Initial globe preparation")
        XCUIRemote.shared.press(.down)
        let pause = app.buttons["preparation-pause"]
        XCTAssertTrue(focused(pause))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["照片整理已暂停"].waitForExistence(timeout: 5))
        attach(app, "Paused preparation")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        // The local index is browsable while place names finish.
        XCTAssertTrue(app.staticTexts["preparation-ready"].waitForExistence(timeout: 15))
        // Keep the progress entry available while navigating. A completed
        // scan intentionally removes it from the home screen.
        XCTAssertTrue(focused(pause))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["照片整理已暂停"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        let globe = app.buttons["overview-explore-button"]
        XCTAssertTrue(globe.waitForExistence(timeout: 8))
        let entry = app.buttons["library-preparation-entry"]
        XCTAssertTrue(entry.exists)
        app.enterHomeContent()
        attach(app, "Home preparation entry")
        XCTAssertTrue(focused(globe))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(focused(entry))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["照片整理已暂停"].exists)
        attach(app, "Shared scan details")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        // Reopening with Select verifies the original entry regained actual
        // remote focus, including its native Glass focus wrapper.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
    }

    @MainActor func testFirstScanCompletesIntoSameGlobeAndSettingsReusesPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--welcome-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        // Establish the first scan's start through the same explicit action as
        // a real first launch. A TV automation session can attach after the
        // complete fixture scan if the fixture starts reading at process launch.
        let connect = app.buttons["welcome-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 12))
        // The default action is observable even when the native glass host
        // owns the focus rather than its accessible Button child.
        XCUIRemote.shared.press(.select)
        let progress = app.descendants(matching: .any)["preparation-status"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 12))
        let globe = app.buttons["overview-explore-button"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            globe.exists && !progress.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 55), .completed)
        app.enterHomeContent()
        XCTAssertTrue(focused(globe))
        attach(app, "Prepared home")
        app.openSidebarDestination("tab-settings")
        let update = app.buttons["settings-scan"]
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        XCTAssertTrue(focused(update))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["返回地球"].exists)
        attach(app, "Settings update uses same scene")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused(update))
        let details = app.buttons["settings-scan-details"]
        for _ in 0..<4 where !details.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(focused(details))
        XCTAssertFalse(app.buttons["settings-rebuild"].exists)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.down)
        // When a place name is incomplete, the dedicated repair precedes Rebuild.
        let completePlaces = app.buttons["settings-complete-places"]
        if completePlaces.exists && completePlaces.hasFocus { XCUIRemote.shared.press(.down) }
        let rebuild = app.buttons["settings-rebuild"]
        XCTAssertTrue(focused(rebuild))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["重新寻找照片里的足迹，同时保留已有的地点名称。"].waitForExistence(timeout: 15))
        attach(app, "Rebuild preserves globe and names")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused(rebuild))
    }

    @MainActor func testMinimumItemsBackDiscardsDraftAndSaveAppliesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        app.openSidebarDestination("tab-settings")
        let minimum = app.buttons["settings-journey-minimum"]
        XCTAssertTrue(minimum.waitForExistence(timeout: 5))
        for _ in 0..<4 where !minimum.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(focused(minimum))
        let original = minimum.value as? String
        XCTAssertNotNil(original)
        let candidate = original == "1" ? "3" : "1"
        let preset = app.buttons["settings-journey-minimum-preset-\(candidate)"]
        let save = app.buttons["settings-journey-minimum-save"]

        func chooseDraft() {
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            XCTAssertEqual(save.label, "保存")
            let first = app.buttons["settings-journey-minimum-preset-1"]
            XCTAssertTrue(focused(first))
            if candidate != "1" { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(focused(preset))
            XCUIRemote.shared.press(.select)
        }

        chooseDraft()
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focused(minimum))
        XCTAssertEqual(minimum.value as? String, original)
        chooseDraft()
        for _ in 0..<3 where !save.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(focused(save))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focused(minimum))
        XCTAssertEqual(minimum.value as? String, candidate)
    }

    @MainActor private func focused(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 5) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
