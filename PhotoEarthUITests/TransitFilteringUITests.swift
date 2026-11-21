import XCTest

final class TransitFilteringUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSettingsRestoresFilteredPhotosAndReappliesFilter() throws {
        try exercise(allHidden: false)
    }

    @MainActor func testAllHiddenLibraryStillHasAccessibleRecovery() throws {
        try exercise(allHidden: true)
    }

    @MainActor private func exercise(allHidden: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--transit-fixture"] + (allHidden ? ["--transit-only-fixture"] : [])
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        let globe = app.buttons["overview-explore-button"]
        XCTAssertTrue(globe.waitForExistence(timeout: 30))
        if allHidden {
            XCTAssertTrue(app.staticTexts["途经照片已隐藏，你可以在设置中恢复显示。"].waitForExistence(timeout: 5))
        }
        app.openSidebarDestination("tab-settings")
        let scan = app.buttons["settings-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 8))
        let toggle = app.descendants(matching: .any)["settings-hide-transit"].firstMatch
        let count = app.staticTexts["settings-transit-count"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "已隐藏 1 张照片")
        let summary = app.staticTexts["settings-index-summary"]
        XCTAssertTrue(summary.label.contains(allHidden ? "0 张照片" : "3 张照片"))
        XCTAssertTrue(focused(scan))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focused(toggle))
        attach(app, allHidden ? "All hidden — recovery remains available" : "Transit filter enabled")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForLabel(summary, containing: allHidden ? "1 张照片" : "4 张照片"))
        XCTAssertFalse(count.exists)
        XCTAssertTrue(focused(toggle))
        attach(app, "Original photos restored without rescanning")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(summary, containing: allHidden ? "0 张照片" : "3 张照片"))
        XCTAssertTrue(focused(toggle))
        // Return through the native sidebar: the restored overview must reflect the policy.
        XCUIRemote.shared.press(.menu)
        for _ in 0..<3 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
    }

    @MainActor private func focused(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 4) == .completed
    }
    @MainActor private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: 5) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
