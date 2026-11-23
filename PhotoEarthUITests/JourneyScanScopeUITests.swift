import XCTest

/// Run on the dedicated simulator seeded by Scripts/PrivateLibraryFixture/seed_scan_scope.py.
/// The normal app and PhotoKit provide every photo, album, scan, and count.
final class JourneyScanScopeUITests: XCTestCase {
    @MainActor func testFirstScanAlbumListKeepsItsColumnWhileScrolling() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Photo Earth · Scan Gates",
                          "Requires the isolated album fixture and a fresh app installation")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(waitForFocus(app.buttons["scan-scope-save"]))
        let first = app.buttons["scan-scope-album-0"]
        XCTAssertTrue(seek(first, direction: .down))
        let firstX = first.frame.minX
        for _ in 0..<10 { XCUIRemote.shared.press(.down) }
        let lower = app.buttons["scan-scope-album-10"]
        XCTAssertTrue(waitForFocus(lower))
        XCTAssertEqual(lower.frame.minX, firstX, accuracy: 2)
        for _ in 0..<10 { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(waitForFocus(first))
        XCTAssertEqual(first.frame.minX, firstX, accuracy: 2)
    }

    @MainActor func testFirstScanScopeOverlappingAlbumsAndRecovery() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Photo Earth · Scan Gates",
                          "Requires the isolated five-photo album fixture and a fresh app installation")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        let save = app.buttons["scan-scope-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 40))
        XCTAssertEqual(save.label, "开始扫描")
        XCTAssertTrue(waitForFocus(save))
        let first = album(1, app: app)
        let second = album(2, app: app)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.exists)
        capture(app, "01 选择首扫范围")
        let originalSelection = save.value as? String
        XCTAssertNotNil(originalSelection)
        XCTAssertTrue(seek(first, direction: .down))
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(save.value as? String, originalSelection)
        XCUIRemote.shared.press(.menu)
        let connect = app.buttons["welcome-connect"]
        XCTAssertTrue(waitForFocus(connect))
        XCTAssertFalse(save.exists)
        XCTAssertFalse(app.buttons["overview-explore-button"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForFocus(connect))
        XCTAssertFalse(save.exists, "A deferred first scan waits for an explicit connection after relaunch")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(save))
        XCTAssertEqual(save.value as? String, originalSelection)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(connect))

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        app.enterHomeContent()
        app.openSidebarDestination("tab-settings")
        app.enterSettingsCategory("photos")
        let sampleConnection = app.buttons["settings-scan"]
        XCTAssertTrue(waitForFocus(sampleConnection))
        let connectLabel = sampleConnection.label
        let sampleSummary = app.staticTexts["settings-index-summary"].label
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(save))
        XCTAssertEqual(save.label, "开始扫描")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(sampleConnection))
        XCTAssertEqual(sampleConnection.label, connectLabel)
        XCTAssertEqual(app.staticTexts["settings-index-summary"].label, sampleSummary)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(save))
        XCUIRemote.shared.press(.select)

        try openScope(app, expectedPhotos: 4)
        XCTAssertEqual(save.label, "保存范围")
        XCTAssertTrue(seek(first, direction: .down))
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(save.value as? String, originalSelection)
        XCUIRemote.shared.press(.menu)
        let settingsScope = app.buttons["settings-scan-scope"]
        XCTAssertTrue(waitForFocus(settingsScope))
        XCTAssertTrue(app.staticTexts["settings-index-summary"].label.contains("4 项"))
        // The album fixture has one surviving short visit when both albums are
        // excluded. Keep the independent transit policy out of this assertion.
        let transit = app.descendants(matching: .any)["settings-hide-transit"].firstMatch
        XCTAssertTrue(seek(transit, direction: .down))
        if ["1", "已开启"].contains(String(describing: transit.value ?? "")) { XCUIRemote.shared.press(.select) }
        let disabledTransit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["0", "已关闭"].contains(String(describing: transit.value ?? ""))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [disabledTransit], timeout: 8), .completed)
        XCTAssertTrue(seek(settingsScope, direction: .up))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(save))
        XCTAssertEqual(save.value as? String, originalSelection)
        XCTAssertTrue(seek(first, direction: .down))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(seek(second, direction: .down))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(seek(save, direction: .up))
        capture(app, "02 排除两个重叠相册")
        XCUIRemote.shared.press(.select)

        try openScope(app, expectedPhotos: 1)
        let excluded = app.descendants(matching: .any)["scan-count-2"].firstMatch
        let lastAlbum = album(41, app: app)
        XCTAssertTrue(seek(lastAlbum, direction: .down))
        XCTAssertTrue(excluded.waitForExistence(timeout: 8))
        XCTAssertTrue(excluded.label.contains("3"), "The shared photo contributes once")
        capture(app, "03 查验排除计数")
        XCTAssertTrue(seek(first, direction: .up))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(seek(save, direction: .up))
        XCUIRemote.shared.press(.select)

        try openScope(app, expectedPhotos: 2)
        XCTAssertTrue(seek(second, direction: .down))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(seek(save, direction: .up))
        XCUIRemote.shared.press(.select)

        try openScope(app, expectedPhotos: 4)
        XCTAssertTrue(seek(lastAlbum, direction: .down))
        XCTAssertFalse(excluded.exists)
        capture(app, "04 取消排除后恢复")
    }

    @MainActor private func album(_ number: Int, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'scan-scope-album-' AND label CONTAINS %@", "Sample Album \(number)"
        )).firstMatch
    }

    @MainActor private func openScope(_ app: XCUIApplication, expectedPhotos: Int) throws {
        let home = app.buttons["overview-explore-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 65))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: home)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        if !home.hasFocus {
            XCUIRemote.shared.press(.right)
            settle()
        }
        XCUIRemote.shared.press(.menu)
        settle()
        for _ in 0..<5 {
            XCUIRemote.shared.press(.down)
            settle()
        }
        capture(app, "选择设置入口")
        XCUIRemote.shared.press(.select)
        settle()
        let summary = app.staticTexts["settings-index-summary"]
        if !summary.exists {
            XCUIRemote.shared.press(.right)
            settle()
        }
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(summary.label.contains("\(expectedPhotos) 项"), "Expected \(expectedPhotos) indexed items. Got \(summary.label)")
        let scope = app.buttons["settings-scan-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        if app.buttons["settings-category-photos"].hasFocus { app.enterSettingsCategory("photos") }
        XCTAssertTrue(seek(scope, direction: .up))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["scan-scope-save"]))
    }

    @MainActor private func seek(_ element: XCUIElement, direction: XCUIRemote.Button) -> Bool {
        for _ in 0..<18 {
            if element.exists && element.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            settle()
        }
        return element.exists && element.hasFocus
    }

    @MainActor private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
    }

    @MainActor private func waitForFocus(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 8) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
