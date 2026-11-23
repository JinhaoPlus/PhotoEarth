import UIKit
import XCTest

final class LocalizationSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let cases: [(language: String, locale: String, heading: String, drag: String, turn: String, photos: String, zoomOut: String, zoomIn: String)] = [
        ("en", "en_US", "Recently Visited Cities", "Drag", "Turn", "Photos", "Zoom Out", "Zoom In"),
        ("de", "de_DE", "Zuletzt besuchte Städte", "Ziehen", "Drehen", "Fotos", "Verkleinern", "Vergrößern"),
        ("es", "es_ES", "Ciudades visitadas recientemente", "Arrastrar", "Girar", "Fotos", "Alejar", "Acercar"),
        ("fr", "fr_FR", "Villes récemment visitées", "Déplacer", "Tourner", "Photos", "Zoom arrière", "Zoom avant"),
        ("it", "it_IT", "Città visitate di recente", "Trascina", "Ruota", "Foto", "Riduci", "Ingrandisci"),
        ("ja", "ja_JP", "最近訪れた都市", "ドラッグ", "回転", "写真", "縮小", "拡大"),
        ("zh-Hans", "zh_CN", "最近到访的城市", "拖动", "转动", "照片", "缩小", "放大"),
        ("zh-Hant", "zh_TW", "最近到訪的城市", "拖曳", "轉動", "照片", "縮小", "放大"),
    ]

    @MainActor
    func testEverySupportedLanguageRendersRemoteActions() throws {
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
                           "Drag and Photos should align for \(item.language)")
            XCTAssertEqual(turn.frame.minX, zoomShortcut.frame.minX, accuracy: 6,
                           "Turn and Zoom should align for \(item.language)")
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
    func testLocalizedCityDockFitsLabelsAndKeepsFocusInsideSafeArea() {
        for item in cases {
            let language = item.language
            let app = XCUIApplication()
            app.launchArguments = ["--demo", "--map-review-fixture"]
            app.useTestLanguage(language, locale: item.locale)
            app.launch()
            app.enterHomeContent()
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(app.buttons["overview-place-sample-map-review"]))
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(waitForFocus(app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch))
            XCUIRemote.shared.press(.playPause)
            XCTAssertTrue(waitForFocus(app.buttons["globe-zoom-in"]))
            let drag = app.descendants(matching: .any)["globe-controls-pan-hint"].firstMatch
            XCTAssertTrue(drag.exists)
            XCTAssertLessThan(drag.frame.maxY, app.frame.height / 4)
            XCTAssertFalse(app.staticTexts["globe-controls-status"].exists)
            XCUIRemote.shared.press(.left)

            var previous: XCUIElement?
            for id in ["globe-zoom-out", "globe-zoom-in", "globe-use-current-view", "globe-style"] {
                let button = app.buttons[id]
                XCTAssertTrue(waitForFocus(button))
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 80)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 80)
                if let previous { XCTAssertLessThan(previous.frame.maxX, button.frame.minX) }
                if id == "globe-zoom-out" || id == "globe-zoom-in" {
                    XCTAssertEqual(button.label, id == "globe-zoom-out" ? item.zoomOut : item.zoomIn)
                    XCTAssertEqual(button.frame.width, button.frame.height, accuracy: 2)
                    XCTAssertGreaterThanOrEqual(button.frame.height, 64)
                } else if id == "globe-use-current-view" {
                    let font = UIFont.systemFont(ofSize: 27, weight: .medium)
                    let titleWidth = (button.label as NSString).size(withAttributes: [.font: font]).width
                    // A full-size title, an icon, and clear space at both ends.
                    XCTAssertGreaterThanOrEqual(button.frame.width, titleWidth + 26 + 2 * 22)
                }
                if id == "globe-zoom-out" {
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "City map controls (\(language))"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                previous = button
                if id != "globe-style" { XCUIRemote.shared.press(.right) }
            }
            let style = app.buttons["globe-style"]
            let priorStyle = style.label
            let width = style.frame.width
            XCUIRemote.shared.press(.select)
            XCTAssertNotEqual(style.label, priorStyle)
            XCTAssertEqual(style.frame.width, width, accuracy: 2)
            app.terminate()
        }
    }

    @MainActor
    func testSlideshowOpeningFitsLocalizedActions() {
        for item in cases {
            let language = item.language
            let app = XCUIApplication()
            app.launchArguments = ["--demo"]
            app.useTestLanguage(language, locale: item.locale)
            app.launch()
            app.enterHomeContent()
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(waitForFocus(app.buttons["overview-slideshow"]))
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
            var previous: XCUIElement?
            for id in ["slideshow-opening-trips", "slideshow-begin", "slideshow-opening-music"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.exists)
                let font = UIFont.systemFont(ofSize: 25, weight: .medium)
                let titleWidth = (button.label as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThanOrEqual(button.frame.width, titleWidth + 48, button.label)
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 80)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 80)
                if let previous { XCTAssertLessThan(previous.frame.maxX, button.frame.minX) }
                previous = button
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Slideshow opening actions (\(language))"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor
    func testFrenchTripPickerKeepsFourDigitSelectionReadable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--home-scroll-fixture"]
        app.useTestLanguage("fr", locale: "fr_FR")
        app.launch()
        app.enterHomeContent()
        let remote = XCUIRemote.shared
        remote.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["overview-slideshow"]))
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        let picker = app.buttons["slideshow-opening-trips"]
        XCTAssertTrue(picker.wait(for: \.isEnabled, toEqual: true, timeout: 12))
        remote.press(.left)
        XCTAssertTrue(waitForFocus(picker))
        remote.press(.select)
        let years = app.buttons["slideshow-picker-tab-all"]
        XCTAssertTrue(waitForFocus(years))
        remote.press(.right)
        let firstTrip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slideshow-picker-trip-'")).firstMatch
        XCTAssertTrue(waitForFocus(firstTrip))
        remote.press(.up)
        let bulk = app.buttons["slideshow-picker-bulk"]
        XCTAssertTrue(waitForFocus(bulk))
        remote.press(.select)
        let selection = app.buttons["slideshow-picker-tab-selected"]
        XCTAssertEqual(selection.label.compactMap(\.wholeNumberValue), [1, 0, 0, 0])
        XCTAssertGreaterThan(selection.frame.height, years.frame.height)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "French trip picker with 1000 selected"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testHiddenControlHintsStayHiddenWhenZoomDockOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-photoEarth.showsGlobeHints", "NO"]
        app.useTestLanguage("en", locale: "en_US")
        app.launch()
        app.enterHomeContent()
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch))
        XCTAssertFalse(app.descendants(matching: .any)["globe-drag-control-hint"].firstMatch.exists)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(app.buttons["globe-zoom-in"]))
        XCTAssertFalse(app.descendants(matching: .any)["globe-controls-pan-hint"].firstMatch.exists)
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
