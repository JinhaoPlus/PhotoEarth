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
        if focusedIndex() == nil { XCUIRemote.shared.press(.menu) }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            guard let index = focusedIndex() else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            if index == target {
                XCUIRemote.shared.press(.select)
                return
            }
            XCUIRemote.shared.press(index < target ? .down : .up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        }
        XCTFail("Native sidebar did not focus the requested destination")
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
