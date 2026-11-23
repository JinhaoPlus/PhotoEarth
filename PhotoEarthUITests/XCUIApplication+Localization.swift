import XCTest

extension XCUIApplication {
    /// tvOS can give its native sidebar initial focus on a cold launch.
    /// Use the remote to enter Home before testing actions inside its content.
    @MainActor func enterHomeContent() {
        let entry = buttons["overview-explore-button"]
        guard entry.waitForExistence(timeout: 12), !entry.hasFocus else { return }
        XCUIRemote.shared.press(.right)
        let arrival = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [arrival], timeout: 6), .completed)
    }

    @MainActor func openSidebarDestination(_ identifier: String) {
        let ids = ["tab-home", "tab-recent", "tab-countries", "tab-anniversary", "tab-settings"]
        func focusedIndex() -> Int? {
            ids.firstIndex { id in
                let cell = cells.containing(.button, identifier: id).firstMatch
                return (cell.exists && cell.hasFocus) || (buttons[id].exists && buttons[id].hasFocus)
            }
        }
        guard let target = ids.firstIndex(of: identifier) else { XCTFail("Unknown sidebar destination"); return }
        if focusedIndex() == nil {
            let inSettings = buttons["settings-category-photos"].exists
            XCUIRemote.shared.press(.menu)
            // Back can first return focus to the top of Home or to a settings category.
            let homeEntry = buttons["overview-explore-button"]
            if focusedIndex() == nil && (inSettings || (homeEntry.exists && homeEntry.hasFocus)) {
                XCUIRemote.shared.press(.menu)
            }
        }
        var deadline = Date().addingTimeInterval(12)
        var visited = Set<Int>()
        while Date() < deadline {
            guard let index = focusedIndex() else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            if index == target {
                XCUIRemote.shared.press(.select)
                return
            }
            if visited.insert(index).inserted {
                deadline = Date().addingTimeInterval(12)
            }
            XCUIRemote.shared.press(index < target ? .down : .up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        }
        XCTFail("Native sidebar did not focus the requested destination\n" + debugDescription)
    }

    @MainActor func enterSettingsCategory(_ name: String) {
        let categories = buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-category-'"))
        let target = buttons["settings-category-\(name)"]
        guard target.waitForExistence(timeout: 6) else { XCTFail("Missing settings category " + name + "\n" + debugDescription); return }
        func focusedCategory() -> XCUIElement? { categories.allElementsBoundByIndex.first { $0.hasFocus } }
        if focusedCategory() == nil { XCUIRemote.shared.press(.left) }
        for _ in 0..<6 {
            guard let current = focusedCategory() else { XCTFail("Expected focus in the settings categories\n" + debugDescription); return }
            if current.identifier == target.identifier {
                XCUIRemote.shared.press(.select)
                return
            }
            XCUIRemote.shared.press(current.frame.midY < target.frame.midY ? .down : .up)
        }
        XCTFail("Could not enter settings category " + name)
    }

    @MainActor func confirmSlideshowExit(file: StaticString = #filePath, line: UInt = #line) {
        XCUIRemote.shared.press(.menu)
        let alert = alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), file: file, line: line)
        // tvOS focuses the native button containing the identified SwiftUI action.
        let stay = alert.buttons.containing(.button, identifier: "slideshow-exit-stay").firstMatch
        let exit = alert.buttons.containing(.button, identifier: "slideshow-exit-confirm").firstMatch
        let initialFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: stay)
        XCTAssertEqual(XCTWaiter.wait(for: [initialFocus], timeout: 5), .completed, file: file, line: line)
        XCUIRemote.shared.press(.right)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, file: file, line: line)
        XCUIRemote.shared.press(.select)
    }

    func useTestLanguage(_ language: String, locale: String) {
        launchEnvironment["PHOTOEARTH_UI_OWNED_FIXTURE"] = "1"
        launchArguments.append(contentsOf: [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ])
    }

    /// Existing navigation flows are the Simplified Chinese regression suite.
    /// Other locales have focused smoke tests, while selectors stay language-neutral.
    func useSimplifiedChineseTestLanguage() {
        useTestLanguage("zh-Hans", locale: "zh_CN")
    }
}
