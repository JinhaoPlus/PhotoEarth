import XCTest

final class LocalizationSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEverySupportedLanguageRendersRemoteActions() throws {
        let cases: [(language: String, locale: String, heading: String, drag: String, turn: String, photos: String)] = [
            ("en", "en_US", "Recently Visited Cities", "Drag", "Turn", "Photos"),
            ("de", "de_DE", "Zuletzt besuchte Städte", "Bewegen", "Drehen", "Fotos"),
            ("es", "es_ES", "Ciudades visitadas recientemente", "Mover", "Girar", "Fotos"),
            ("fr", "fr_FR", "Villes récemment visitées", "Déplacer", "Tourner", "Photos"),
            ("it", "it_IT", "Città visitate di recente", "Sposta", "Ruota", "Foto"),
            ("ja", "ja_JP", "最近訪れた都市", "ドラッグ", "回転", "写真"),
            ("zh-Hans", "zh_CN", "最近抵达的城市", "拖动", "转动", "照片"),
            ("zh-Hant", "zh_TW", "最近抵達的城市", "拖曳", "轉動", "照片"),
        ]

        for item in cases {
            let app = XCUIApplication()
            app.launchArguments = ["--demo"]
            app.useTestLanguage(item.language, locale: item.locale)
            app.launch()
            app.enterHomeContent()
            XCTAssertTrue(
                app.staticTexts[item.heading].waitForExistence(timeout: 10),
                "Photo Earth should use the Apple-selected \(item.language) localization"
            )
            let entry = app.buttons["overview-explore-button"]
            XCTAssertTrue(entry.exists)
            XCTAssertTrue(waitForFocus(entry))
            XCUIRemote.shared.press(.select)

            let drag = app.descendants(matching: .any)["globe-drag-control-hint"].firstMatch
            let turn = app.descendants(matching: .any)["globe-turn-control-hint"].firstMatch
            let photos = app.descendants(matching: .any)["globe-photo-control-hint"].firstMatch
            let zoomShortcut = app.descendants(matching: .any)["globe-zoom-control-hint"].firstMatch
            XCTAssertTrue(drag.waitForExistence(timeout: 5), "Missing concise drag hint for \(item.language)")
            XCTAssertTrue(turn.exists, "Missing concise turn hint for \(item.language)")
            XCTAssertTrue(photos.waitForExistence(timeout: 5), "Missing concise photo hint for \(item.language)")
            XCTAssertEqual(drag.label, item.drag)
            XCTAssertEqual(turn.label, item.turn)
            XCTAssertEqual(photos.label, item.photos)
            XCTAssertTrue(zoomShortcut.exists, "Missing concise zoom hint for \(item.language)")
            XCTAssertEqual(drag.frame.minX, photos.frame.minX, accuracy: 6,
                           "The left hint column should align for \(item.language)")
            XCTAssertEqual(turn.frame.minX, zoomShortcut.frame.minX, accuracy: 6,
                           "The right hint column should align for \(item.language)")
            XCTAssertEqual(drag.frame.midY, turn.frame.midY, accuracy: 2,
                           "The first hint row should align for \(item.language)")
            XCTAssertEqual(photos.frame.midY, zoomShortcut.frame.midY, accuracy: 2,
                           "The second hint row should align for \(item.language)")
            XCTAssertLessThan(drag.frame.midY, photos.frame.midY,
                              "The two hint rows should remain visually distinct for \(item.language)")
            XCTAssertGreaterThan(photos.frame.width, 0)
            XCTAssertGreaterThan(zoomShortcut.frame.width, 0)
            XCTAssertLessThanOrEqual(max(photos.frame.maxX, zoomShortcut.frame.maxX), app.frame.maxX - 72,
                                     "Remote hints should remain inside the television safe area for \(item.language)")
            app.terminate()
        }
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
