import XCTest

/// Opt-in acceptance against the authorized Photos library on the selected Apple TV.
final class PrivateLibrarySlideshowUITests: XCTestCase {
    @MainActor func testOpensTheRealIndexedLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_LIBRARY"] == "1")
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["PHOTOEARTH_WAKE_TV"] == "1" {
            XCUIRemote.shared.press(.home)
            try await Task.sleep(for: .seconds(3))
        }
        let app = XCUIApplication()
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        try await enterRealLibrary(app)
        let frame = XCTAttachment(screenshot: app.screenshot())
        frame.name = "Real library home"
        frame.lifetime = .keepAlways
        add(frame)
    }

    @MainActor private func enterRealLibrary(_ app: XCUIApplication) async throws {
        let explore = app.buttons["overview-explore-button"]
        let start = app.buttons["overview-slideshow"]
        let welcome = app.buttons["welcome-connect"]
        let scope = app.buttons["scan-scope-save"]
        let browse = app.buttons["preparation-browse"]
        let progress = app.descendants(matching: .any)["preparation-status"].firstMatch
        let homeTab = app.cells.containing(.button, identifier: "tab-home").firstMatch
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        let deadline = ContinuousClock.now.advanced(by: .seconds(420))
        var submitted = Set<String>()

        // A Select can leave its source visible during a transition. Send it
        // once for each onboarding step, even when a library scan takes time.
        func selectOnce(_ identifier: String, _ element: XCUIElement) {
            guard element.hasFocus, element.isEnabled, submitted.insert(identifier).inserted else { return }
            XCUIRemote.shared.press(.select)
        }

        while ContinuousClock.now < deadline {
            if (start.exists && start.hasFocus) || (explore.exists && explore.hasFocus) { return }
            if scope.exists {
                if scope.hasFocus { selectOnce("scope", scope) }
                else if !submitted.contains("scope") { XCUIRemote.shared.press(.up) }
            } else if progress.exists {
                if browse.exists {
                    if browse.hasFocus { selectOnce("browse", browse) }
                    else if !submitted.contains("browse") { XCUIRemote.shared.press(.down) }
                }
            } else if welcome.exists {
                if welcome.hasFocus { selectOnce("welcome", welcome) }
                else if app.buttons["welcome-demo"].exists && app.buttons["welcome-demo"].hasFocus {
                    XCUIRemote.shared.press(.up)
                }
            } else if homeTab.exists && homeTab.hasFocus {
                if !submitted.contains("homeTab") { selectOnce("homeTab", homeTab) }
                else if submitted.insert("enterHomeContent").inserted { XCUIRemote.shared.press(.right) }
            } else if ["tab-recent", "tab-countries", "tab-settings"].contains(where: {
                let tab = app.cells.containing(.button, identifier: $0).firstMatch
                return tab.exists && tab.hasFocus
            }) {
                XCUIRemote.shared.press(.up)
            } else if globe.exists && globe.hasFocus && submitted.insert("leaveGlobe").inserted {
                XCUIRemote.shared.press(.menu)
            } else if app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'overview-place-' AND hasFocus == true")).firstMatch.exists {
                XCUIRemote.shared.press(.up)
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        XCTFail("The real library must reach a focused home action")
    }

    @MainActor private func openRealSlideshow(_ app: XCUIApplication) async throws {
        try await enterRealLibrary(app)
        let start = app.buttons["overview-slideshow"]
        let explore = app.buttons["overview-explore-button"]
        if explore.exists && explore.hasFocus { XCUIRemote.shared.press(.right) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(start.exists && start.hasFocus) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
        guard start.exists && start.hasFocus else {
            XCTFail("The slideshow button did not receive focus")
            return
        }
        XCUIRemote.shared.press(.select)
    }

    #if !targetEnvironment(simulator)
    @MainActor func testAppleMusicPermissionRequiresAnExplicitConnection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_MUSIC_PROMPT"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        try await openRealSlideshow(app)

        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 5))
        XCTAssertTrue(begin.hasFocus)
        let choose = app.buttons["slideshow-opening-music"]
        XCUIRemote.shared.press(.right)
        let focusDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !choose.hasFocus && ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard choose.hasFocus else {
            XCTFail("Choose Music must receive focus")
            return
        }
        XCUIRemote.shared.press(.select)
        let connect = app.buttons["slideshow-music-source-apple"]
        let online = app.buttons["slideshow-music-source-online"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        for _ in 0..<3 where !connect.hasFocus && !online.hasFocus {
            XCUIRemote.shared.press(.up)
        }
        if online.hasFocus { XCUIRemote.shared.press(.right) }
        let sourceDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !connect.hasFocus && ContinuousClock.now < sourceDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard connect.hasFocus else {
            XCTFail("Apple Music must receive focus before requesting permission")
            return
        }
        XCUIRemote.shared.press(.select)

        let processes = [app, XCUIApplication(bundleIdentifier: "com.apple.PineBoard"),
                         XCUIApplication(bundleIdentifier: "com.apple.TVSystemUIService")]
        let promptDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        let message = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                  "Apple Music", "媒体资料库", "media library")
        var prompt: XCUIElement?
        while prompt == nil && ContinuousClock.now < promptDeadline {
            for process in processes where process.state != .notRunning {
                let alert = process.alerts.firstMatch
                if alert.exists && (message.evaluate(with: alert) || alert.staticTexts.matching(message).firstMatch.exists) {
                    prompt = alert
                    break
                }
            }
            if prompt == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let prompt else { XCTFail("The explicit connection must present the system music permission sheet"); return }

        // Menu dismisses cancelable sheets. If tvOS requires a decision, Select
        // may only run while a labeled Cancel or Don't Allow button has focus.
        XCUIRemote.shared.press(.menu)
        try await Task.sleep(for: .milliseconds(600))
        if prompt.exists {
            let decline = prompt.buttons.matching(NSPredicate(format: "label IN %@",
                ["不允许", "不允許", "取消", "Cancel", "Don’t Allow", "Don't Allow"])).firstMatch
            guard decline.exists else { XCTFail("Cannot identify a non-grant action on the permission sheet"); return }
            for direction in [XCUIRemote.Button.left, .down, .right, .up] where prompt.exists && !decline.hasFocus {
                XCUIRemote.shared.press(direction)
            }
            if prompt.exists {
                guard decline.hasFocus else { XCTFail("The permission sheet's non-grant action must have focus"); return }
                XCUIRemote.shared.press(.select)
            }
        }
        let dismissDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while prompt.exists && ContinuousClock.now < dismissDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(prompt.exists)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-music-picker"].firstMatch.exists)
    }
    #endif

    @MainActor func testPlaysForAnHourFromTheRealLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_SOAK"] == "1")
        continueAfterFailure = false
        executionTimeAllowance = 4200
        let app = XCUIApplication()
        app.launchArguments = ["--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        try await openRealSlideshow(app)
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 5))
        XCTAssertTrue(begin.hasFocus)
        XCUIRemote.shared.press(.select)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 90))
        let started = ContinuousClock.now
        var lastAdvance = started
        var samples = Set<String>()
        var prior: String?
        var captures = 0
        while started.duration(to: .now) < .seconds(3600) {
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertFalse(app.buttons["slideshow-retry"].exists)
            XCTAssertFalse(app.buttons["slideshow-replay"].exists)
            if media.exists, let shown = media.value as? String, !shown.isEmpty, prior != shown {
                XCTAssertTrue(samples.insert(shown).inserted, "A previously presented item appeared again")
                prior = shown
                lastAdvance = .now
                if started.duration(to: .now) >= .seconds(900 * captures) {
                    let frame = XCTAttachment(screenshot: app.screenshot())
                    frame.name = "Private library playback milestone \(captures)"
                    frame.lifetime = .keepAlways
                    add(frame)
                    captures += 1
                }
            }
            // A large readable library must still advance late in the hour. Allow
            // several 20-second media deadlines so one unavailable original can recover.
            XCTAssertLessThan(lastAdvance.duration(to: .now), .seconds(120), "Playback stopped advancing for two minutes")
            try await Task.sleep(for: .seconds(7))
        }
        XCTAssertGreaterThan(samples.count, 100, "The slideshow must keep advancing")
        let summary = XCTAttachment(string: "At least \(samples.count) distinct real assets observed during 60 minutes.")
        summary.lifetime = .keepAlways
        add(summary)
        XCUIRemote.shared.press(.menu)
    }
}
