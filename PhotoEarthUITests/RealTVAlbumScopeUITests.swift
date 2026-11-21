import XCTest

/// Opt in on an already authorized Apple TV. Only the selected album is toggled.
final class RealTVAlbumScopeUITests: XCTestCase {
    private struct Album {
        let identifier: String
        let title: String
    }

    private struct GateFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor func testRealTVAlbumExclusionPersistsAndRestores() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical Apple TV")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_ALBUM_UI"] == "1")
        // A navigation assertion must still allow restoration through the actual form.
        continueAfterFailure = true
        executionTimeAllowance = 2_400
        let app = XCUIApplication()
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        try openScope(app)
        let save = app.buttons["scan-scope-save"]
        guard let initialCount = count(save) else { throw GateFailure("Missing initial exclusion count") }
        let camera = app.descendants(matching: .any)["scan-scope-camera"].firstMatch
        guard camera.waitForExistence(timeout: 8), let initialCamera = switchValue(camera) else {
            throw GateFailure("Missing initial camera setting")
        }
        let album = try chooseAlbum(app)
        capture(app, "01 Original scope · excluded albums \(initialCount)")
        var needsRestore = true
        defer {
            if needsRestore {
                do {
                    if app.state != .runningForeground { app.activate() }
                    try restore(app, album: album, initialCount: initialCount, camera: initialCamera)
                } catch {
                    XCTFail("Could not verify recovery of the temporary album exclusion. \(error)")
                }
            }
        }

        try setExcluded(true, album: album, app: app)
        try commit(app)
        try openScope(app)
        try verifyScope(app, expectedCount: initialCount + 1, camera: initialCamera)
        try focusAlbum(album, app: app)
        guard app.buttons[album.identifier].isSelected else {
            throw GateFailure("The saved album exclusion did not survive closing the sheet")
        }
        capture(app, "02 Saved scope · excluded albums \(initialCount + 1)")
        try restore(app, album: album, initialCount: initialCount, camera: initialCamera)
        needsRestore = false
        #endif
    }

    @MainActor private func restore(_ app: XCUIApplication, album: Album, initialCount: Int, camera: String) throws {
        try openScope(app)
        try setExcluded(false, album: album, app: app)
        try commit(app)
        try openScope(app)
        try verifyScope(app, expectedCount: initialCount, camera: camera)
        try focusAlbum(album, app: app)
        guard !app.buttons[album.identifier].isSelected else { throw GateFailure("The restored album is still excluded") }
        capture(app, "03 Restored scope · excluded albums \(initialCount)")
        XCUIRemote.shared.press(.menu)
    }

    @MainActor private func verifyScope(_ app: XCUIApplication, expectedCount: Int, camera: String) throws {
        let control = app.descendants(matching: .any)["scan-scope-camera"].firstMatch
        guard control.waitForExistence(timeout: 8), count(app.buttons["scan-scope-save"]) == expectedCount,
              switchValue(control) == camera else {
            throw GateFailure("The total selection or camera preference differs from the expected scope")
        }
    }

    @MainActor private func chooseAlbum(_ app: XCUIApplication) throws -> Album {
        let first = app.buttons["scan-scope-album-0"]
        guard first.waitForExistence(timeout: 45) else { throw GateFailure("No accessible ordinary album") }
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scan-scope-album-' AND hasFocus == YES")).firstMatch
        var visited = Set<String>()
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            if focused.exists {
                let id = focused.identifier
                guard visited.insert(id).inserted else { break }
                if !focused.isSelected, let members = count(focused), members > 0 {
                    return Album(identifier: id, title: focused.label)
                }
            }
            XCUIRemote.shared.press(.down)
            settle()
        }
        throw GateFailure("No nonempty, initially included album could be reached")
    }

    @MainActor private func focusAlbum(_ album: Album, app: XCUIApplication) throws {
        let row = app.buttons[album.identifier]
        if !row.exists || !row.hasFocus {
            // Start at the top of this newly presented settings sheet.
            try focus(app.buttons["scan-scope-save"], direction: .up, timeout: 100)
            try focus(row, direction: .down, timeout: 150)
        }
        guard row.label == album.title else { throw GateFailure("The target album changed while the test was running") }
    }

    @MainActor private func setExcluded(_ excluded: Bool, album: Album, app: XCUIApplication) throws {
        try focusAlbum(album, app: app)
        let row = app.buttons[album.identifier]
        guard row.isSelected != excluded else { return }
        XCUIRemote.shared.press(.select)
        guard wait(8, until: { row.exists && row.isSelected == excluded }) else {
            throw GateFailure("Select did not toggle the focused album")
        }
    }

    @MainActor private func commit(_ app: XCUIApplication) throws {
        let save = app.buttons["scan-scope-save"]
        try focus(save, direction: .up, timeout: 150)
        guard save.isEnabled else { throw GateFailure("Scope save is unavailable") }
        XCUIRemote.shared.press(.select)
        guard wait(120, until: { !save.exists }) else { throw GateFailure("The scope editor did not close after Save") }
    }

    @MainActor private func openScope(_ app: XCUIApplication) throws {
        let save = app.buttons["scan-scope-save"]
        let settings = app.buttons["settings-scan-scope"]
        let browse = app.buttons["preparation-browse"]
        let progress = app.descendants(matching: .any)["preparation-status"].firstMatch
        let deadline = Date().addingTimeInterval(450)
        while Date() < deadline {
            if save.exists {
                // A never-configured scope has no persisted value the UI could restore.
                guard save.label != "开始扫描" else { throw GateFailure("Finish first-time scan setup before this gate") }
                return
            } else if progress.exists {
                let failureScope = app.buttons["preparation-scan-scope"]
                if failureScope.exists {
                    if progress.hasFocus { XCUIRemote.shared.press(.down); settle() }
                    try focus(failureScope, direction: .right)
                    XCUIRemote.shared.press(.select)
                    break
                }
                if browse.exists {
                    try focus(browse, direction: .down)
                    XCUIRemote.shared.press(.select)
                    settle()
                }
            } else if settings.exists && settings.isHittable {
                if !settings.hasFocus {
                    let sidebar = app.cells.containing(.button, identifier: "tab-settings").firstMatch
                    if sidebar.exists && sidebar.hasFocus { XCUIRemote.shared.press(.right); settle() }
                    try focus(settings, direction: .up)
                }
                XCUIRemote.shared.press(.select)
                break
            } else if app.buttons["进入我的旅行地球"].exists {
                try focus(app.buttons["进入我的旅行地球"], direction: .left)
                XCUIRemote.shared.press(.select)
            } else if app.buttons["扫描范围"].exists && !settings.exists {
                // Empty indexed library still permits restoration of an excluded album.
                try focus(app.buttons["扫描范围"], direction: .right)
                XCUIRemote.shared.press(.select)
                break
            } else if app.buttons["overview-explore-button"].exists && app.buttons["overview-explore-button"].isEnabled {
                app.openSidebarDestination("tab-settings")
                settle()
            } else if app.buttons["welcome-connect"].exists {
                throw GateFailure("This gate requires an already authorized Photos library")
            }
            settle(0.8)
        }
        guard save.waitForExistence(timeout: 8) else { throw GateFailure("Could not reopen Scan Scope after preparation") }
    }

    @MainActor private func focus(_ element: XCUIElement, direction: XCUIRemote.Button, timeout: TimeInterval = 8) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return }
            XCUIRemote.shared.press(direction)
            settle()
        }
        throw GateFailure("The remote did not reach the intended control")
    }

    @MainActor private func switchValue(_ element: XCUIElement) -> String? {
        if let value = element.value as? String { return value }
        if let value = element.value as? NSNumber { return value.stringValue }
        return nil
    }

    @MainActor private func count(_ element: XCUIElement) -> Int? {
        guard let value = element.value as? String else { return nil }
        let digits = value.compactMap(\.wholeNumberValue).map(String.init).joined()
        return Int(digits)
    }

    @MainActor private func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.35)
        }
        return condition()
    }

    @MainActor private func settle(_ duration: TimeInterval = 0.45) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
