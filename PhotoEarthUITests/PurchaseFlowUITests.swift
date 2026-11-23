import XCTest
import StoreKitTest

@MainActor
final class PurchaseFlowUITests: XCTestCase {
    private let prefix = "com.doupi.PhotoEarth.PhotoEarth."

    func testClaimTrialExpireBuyRestoreAndRefund() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        openHome(app)
        openRecent(app)
        let trips = visitButtons(app)
        let first = trips.element(boundBy: 0)
        let second = trips.element(boundBy: 1)
        selectTrip(first)
        let wall = app.descendants(matching: .any)["viewport-photo-wall"].firstMatch
        XCTAssertTrue(wall.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["photo-wall-slideshow"].waitForExistence(timeout: 12))
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCUIRemote.shared.press(.menu)
        selectTrip(second)
        XCTAssertTrue(app.buttons["purchase-trial"].waitForExistence(timeout: 10))
        attach(app, "Offer for requested journey")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertTrue(second.hasFocus, "Returning from the offer should restore the requested journey")
        XCTAssertTrue(session.allTransactions().isEmpty)
        selectTrip(second)
        XCTAssertTrue(app.staticTexts["purchase-heading"].waitForExistence(timeout: 8))
        let secondTitle = app.staticTexts["purchase-heading"].label
        select(app.buttons["purchase-trial"])
        confirmPurchase("Free trial confirmation")
        XCTAssertTrue(wall.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["photo-wall-title"].label, secondTitle)
        XCTAssertEqual(session.allTransactions().map(\.productIdentifier), [prefix + "trial7days"])

        app.terminate()
        app.launchEnvironment["PHOTOEARTH_STORE_CLOCK_OFFSET"] = String(7 * 86400 + 1)
        app.launch()
        openHome(app)
        openRecent(app)
        selectTrip(first)
        XCTAssertTrue(wall.waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.menu)
        selectTrip(second)
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        let buy = app.buttons["purchase-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        XCTAssertEqual(buy.label, "Buy Full Version · One-Time Purchase")
        XCTAssertTrue(app.staticTexts["purchase-terms"].label.contains("permanently unlocks"))
        attach(app, "Unlock after seven days")
        session.disableDialogs = true
        select(app.buttons["purchase-restore"])
        XCTAssertTrue(app.staticTexts["purchase-notice"].waitForExistence(timeout: 12))
        session.disableDialogs = false
        select(buy)
        confirmPurchase("Full unlock confirmation")
        XCTAssertTrue(wall.waitForExistence(timeout: 15))
        let lifetime = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == prefix + "lifetime" })
        try session.refundTransaction(identifier: lifetime.identifier)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertFalse(wall.exists)
    }

    func testAllJourneysPlaysASingleJourneyLibraryWithoutPurchase() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore(singleJourney: true)
        openHome(app)
        focusAll(app.buttons["overview-slideshow"])
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 12))
        XCTAssertEqual(app.staticTexts["slideshow-opening-range"].label, "All Trips")
        select(begin)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(app.buttons["purchase-buy"].exists)
        XCTAssertTrue(session.allTransactions().isEmpty)
        attach(app, "Single journey playing from All Trips")
    }

    func testSettingsOffersLifetimePurchaseBeforeDuringAndAfterTrial() async throws {
        continueAfterFailure = false
        let (app, session) = try launchStore(language: "zh-Hans", locale: "zh_CN")
        let purchase = app.buttons["settings-purchase"]
        func enterSettings(captureOverview: Bool = false) {
            openHome(app)
            app.openSidebarDestination("tab-settings")
            let photos = app.buttons["settings-category-photos"]
            XCTAssertTrue(photos.wait(for: \.hasFocus, toEqual: true, timeout: 6))
            XCTAssertEqual(purchase.label, "解锁完整版")
            let privacy = app.buttons["settings-category-privacy"]
            XCTAssertGreaterThan(purchase.frame.minY - privacy.frame.maxY, privacy.frame.height)
            XCTAssertEqual(purchase.frame.midX, privacy.frame.midX, accuracy: 4)
            for name in ["globe", "music", "home", "privacy"] {
                XCUIRemote.shared.press(.down)
                XCTAssertTrue(app.buttons["settings-category-" + name].wait(for: \.hasFocus, toEqual: true, timeout: 5))
                if captureOverview && name == "globe" { attach(app, "Settings with purchase in the lower left") }
            }
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(purchase.wait(for: \.hasFocus, toEqual: true, timeout: 5))
            let buy = app.buttons["purchase-buy"]
            XCTAssertTrue(buy.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(buy.frame.minX, purchase.frame.maxX)
            XCTAssertFalse(app.buttons["purchase-back"].exists)
        }
        func openPurchase() {
            XCTAssertTrue(purchase.wait(for: \.hasFocus, toEqual: true, timeout: 6), app.debugDescription)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["purchase-buy"].wait(for: \.hasFocus, toEqual: true, timeout: 8))
        }
        enterSettings(captureOverview: true)
        attach(app, "Settings before trial")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["purchase-buy"].wait(for: \.hasFocus, toEqual: true, timeout: 6))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(purchase.wait(for: \.hasFocus, toEqual: true, timeout: 6))
        openPurchase()
        XCTAssertTrue(app.buttons["purchase-trial"].exists)
        attach(app, "Available trial offer in Settings")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(purchase.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(app.buttons["settings-category-privacy"].wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCTAssertFalse(app.buttons["purchase-buy"].exists)

        XCUIRemote.shared.press(.down)
        openPurchase()
        XCUIRemote.shared.press(.select)
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        XCTAssertTrue(board.alerts.buttons["Cancel"].firstMatch.waitForExistence(timeout: 12))
        pressSystemButton("Cancel", toward: .left)
        XCTAssertTrue(app.buttons["purchase-buy"].wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(app.buttons["purchase-trial"].wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCUIRemote.shared.press(.select)
        confirmPurchase("Start trial from settings")
        XCTAssertTrue(app.staticTexts["purchase-trial-end"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["purchase-heading"].label, "完整版试用中")
        XCTAssertTrue(app.staticTexts["purchase-trial-end"].label.contains("结束"))
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        XCTAssertTrue(purchase.wait(for: \.hasFocus, toEqual: true, timeout: 6))
        attach(app, "Active trial offer in Settings")
        app.terminate()
        app.launchEnvironment["PHOTOEARTH_STORE_CLOCK_OFFSET"] = String(7 * 86400 + 1)
        app.launch()
        enterSettings()
        session.disableDialogs = false
        openPurchase()
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        attach(app, "Expired trial offer in Settings")
        XCUIRemote.shared.press(.select)
        confirmPurchase("Full version from settings")
        let owned = app.descendants(matching: .any)["settings-purchase-owned"].firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: 15))
        XCTAssertEqual(owned.label, "已解锁完整版")
        XCTAssertFalse(purchase.exists)
        XCTAssertTrue(app.buttons["settings-category-privacy"].wait(for: \.hasFocus, toEqual: true, timeout: 6))
        attach(app, "Full version unlocked in settings")
        XCTAssertTrue(session.allTransactions().contains { $0.productIdentifier == prefix + "lifetime" })
    }

    func testTrialExpiresWhileTheAppStaysOpen() async throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        session.disableDialogs = true
        _ = try await session.buyProduct(identifier: prefix + "trial7days")
        let tx = try XCTUnwrap(session.allTransactions().first)
        app.terminate()
        app.launchEnvironment["PHOTOEARTH_STORE_CLOCK_OFFSET"] = String(tx.purchaseDate.addingTimeInterval(7 * 86400).timeIntervalSinceNow - 45)
        app.launch()
        select(app.buttons["welcome-connect"])
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 24))
        app.enterHomeContent()
        focusAll(app.buttons["overview-slideshow"])
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        select(begin)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 18))
        let notice = app.staticTexts["trial-ended-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 55))
        XCTAssertEqual(notice.label, "Your trial has ended. You can still revisit one trip for free.")
        XCTAssertFalse(app.buttons["purchase-buy"].exists)
        attach(app, "Trial ended during playback")
        XCTAssertTrue(notice.waitForNonExistence(timeout: 12))
        XCTAssertTrue(app.buttons["overview-explore-button"].exists)
        XCTAssertFalse(app.buttons["purchase-buy"].exists)
        // This account started its trial before choosing any free journey.
        openRecent(app)
        let visits = visitButtons(app)
        selectTrip(visits.element(boundBy: 0))
        XCTAssertTrue(app.buttons["photo-wall-slideshow"].waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.menu)
        selectTrip(visits.element(boundBy: 1))
        XCTAssertTrue(app.buttons["purchase-buy"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        select(app.buttons["purchase-back"])
        XCTAssertTrue(visits.element(boundBy: 1).wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertEqual(session.allTransactions().map(\.productIdentifier), [prefix + "trial7days"])
    }

    func testSampleAndCancelledPurchaseLeaveTrialAvailable() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        select(app.buttons["welcome-demo"])
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 15))
        XCTAssertTrue(session.allTransactions().isEmpty)
        app.terminate()
        app.launch()
        openHome(app)
        let all = app.buttons["overview-slideshow"]
        openRecent(app)
        let first = visitButtons(app).element(boundBy: 0)
        selectTrip(first)
        let play = app.buttons["photo-wall-slideshow"]
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 12))
        XCTAssertTrue(photo.wait(for: \.hasFocus, toEqual: true, timeout: 6))
        XCUIRemote.shared.press(.up)
        if app.buttons["photo-wall-map-review"].hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(play.wait(for: \.hasFocus, toEqual: true, timeout: 6))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["slideshow-begin"].waitForExistence(timeout: 20))
        select(app.buttons["slideshow-begin"])
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 25))
        XCTAssertTrue(session.allTransactions().isEmpty)
        app.terminate()
        app.launch()
        openHome(app)
        focusAll(all)
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["purchase-buy"].exists)
        select(begin)
        select(app.buttons["purchase-buy"])
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.PineBoard").alerts.buttons["Cancel"].firstMatch.waitForExistence(timeout: 12))
        pressSystemButton("Cancel", toward: .left)
        XCTAssertTrue(begin.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCUIRemote.shared.press(.select)
        session.disableDialogs = true
        select(app.buttons["purchase-trial"])
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 25), app.debugDescription)
    }

    func testChinesePreviewReturnsToTheRequestedJourneyWithoutStartingTrial() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore(language: "zh-Hans", locale: "zh_CN")
        openHome(app)
        XCTAssertTrue(app.staticTexts["你打开的第一段旅程，以后都可以免费回看和放映。"].waitForExistence(timeout: 8))
        attach(app, "Chinese original home")
        openRecent(app)
        let trips = visitButtons(app)
        selectTrip(trips.element(boundBy: 0))
        XCTAssertTrue(app.buttons["photo-wall-slideshow"].waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.menu)
        let next = trips.element(boundBy: 1)
        selectTrip(next)
        let back = app.buttons["purchase-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 12))
        XCTAssertEqual(back.label, "稍后再说")
        XCTAssertTrue(app.staticTexts["purchase-trial-terms"].label.contains("不会自动扣费"))
        XCTAssertEqual(app.buttons["purchase-buy"].label, "一次性购买完整版")
        XCTAssertTrue(app.staticTexts["purchase-terms"].label.contains("永久浏览和放映全部旅程"))
        attach(app, "Chinese journey offer")
        select(back)
        XCTAssertTrue(next.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        attach(app, "Chinese recent visits after dismissal")
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testCityGlobeChecksOnlyWhenOpeningPhotos() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        openHome(app)
        let remote = XCUIRemote.shared
        let cities = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "overview-place-"))
        let first = cities.element(boundBy: 0)
        let second = cities.element(boundBy: 1)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        let wall = app.descendants(matching: .any)["viewport-photo-wall"].firstMatch
        remote.press(.down)
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(wall.waitForExistence(timeout: 10))
        remote.press(.menu)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.menu)
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.right)
        XCTAssertTrue(second.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        remote.press(.select)
        XCTAssertTrue(app.buttons["purchase-trial"].waitForExistence(timeout: 10))
        remote.press(.menu)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCTAssertFalse(wall.exists)
        remote.press(.select)
        XCTAssertTrue(app.buttons["purchase-trial"].waitForExistence(timeout: 10))
        session.disableDialogs = true
        select(app.buttons["purchase-trial"])
        XCTAssertTrue(wall.waitForExistence(timeout: 12))
        XCTAssertEqual(session.allTransactions().map(\.productIdentifier), [prefix + "trial7days"])
    }

    func testAnniversaryChecksThePhotosInTheSelectedYear() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore(anniversary: true)
        openHome(app)
        XCTAssertTrue(app.buttons["library-preparation-entry"].waitForNonExistence(timeout: 60))
        app.openSidebarDestination("tab-anniversary")
        let first = app.buttons["viewport-photo-sample-paris-1"]
        let second = app.buttons["viewport-photo-sample-tokyo-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 8), app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["photo-detail-image"].firstMatch.waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(second.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["purchase-trial"].waitForExistence(timeout: 10))
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testSelectingOneJourneyInTheOriginalSlideshowPickerIsFree() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        openHome(app)
        focusAll(app.buttons["overview-slideshow"])
        let begin = app.buttons["slideshow-begin"]
        let picker = app.buttons["slideshow-opening-trips"]
        let remote = XCUIRemote.shared
        XCTAssertTrue(begin.wait(for: \.hasFocus, toEqual: true, timeout: 12))
        XCTAssertTrue(picker.wait(for: \.isEnabled, toEqual: true, timeout: 12))
        remote.press(.left)
        XCTAssertTrue(picker.wait(for: \.hasFocus, toEqual: true, timeout: 6))
        remote.press(.select)
        let years = app.buttons["slideshow-picker-tab-all"]
        XCTAssertTrue(years.wait(for: \.hasFocus, toEqual: true, timeout: 10))
        remote.press(.right)
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow-picker-trip-")).firstMatch
        XCTAssertTrue(trip.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        remote.press(.up)
        let done = app.buttons["slideshow-picker-done"]
        for _ in 0..<2 where !done.hasFocus { remote.press(.right) }
        XCTAssertTrue(done.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(begin.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 25))
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testCurrentMapViewOfTheFreeCityOpensWithoutAnOffer() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        openHome(app)
        let remote = XCUIRemote.shared
        remote.press(.down)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "overview-place-")).firstMatch
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        let pins = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-review-pin-"))
        XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: 18), "Wait until the city landing reaches its local map before freezing it")
        remote.press(.select)
        let wall = app.descendants(matching: .any)["viewport-photo-wall"].firstMatch
        XCTAssertTrue(wall.waitForExistence(timeout: 12))
        remote.press(.menu)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["globe-zoom-in"].wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.right)
        XCTAssertTrue(app.buttons["globe-use-current-view"].wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(globe.wait(for: \.hasFocus, toEqual: true, timeout: 8))
        remote.press(.select)
        XCTAssertTrue(wall.waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    private func openHome(_ app: XCUIApplication) {
        select(app.buttons["welcome-connect"])
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 35), app.debugDescription)
        app.enterHomeContent()
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
    }

    private func openRecent(_ app: XCUIApplication) {
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(visitButtons(app).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
    }

    private func visitButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-collection-"))
    }

    private func selectTrip(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 12))
        if !target.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(target.wait(for: \.hasFocus, toEqual: true, timeout: 5), XCUIApplication().debugDescription)
        XCUIRemote.shared.press(.select)
    }

    private func focusAll(_ target: XCUIElement) {
        if !target.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(target.wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCUIRemote.shared.press(.select)
    }

    private func launchStore(language: String = "en", locale: String = "en_US", anniversary: Bool = false, singleJourney: Bool = false) throws -> (XCUIApplication, SKTestSession) {
        let app = XCUIApplication()
        app.launchEnvironment["PHOTOEARTH_UI_OWNED_FIXTURE"] = "0"
        app.launchArguments = ["--welcome-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if anniversary { app.launchArguments.append("--anniversary-fixture") }
        if singleJourney { app.launchArguments.append("--single-journey-fixture") }
        app.launchArguments.append("--reset-test-free-journey")
        // StoreKitTest resolves the target via LaunchServices even on a fresh simulator.
        app.launch()
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-free-journey" }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Purchases", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = false
        app.launch()
        return (app, session)
    }

    private func confirmPurchase(_ name: String) {
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let button = board.buttons.matching(NSPredicate(format: "label IN %@", ["Buy", "Get", "Purchase"])).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), board.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        pressSystemButton(button.label, toward: .right)
        let done = board.alerts.buttons["OK"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15), board.debugDescription)
        pressSystemButton("OK", toward: .right)
    }

    // PineBoard exposes both a hosting button and its child. Only the host
    // reports focus, and Select is ignored during the alert's entrance animation.
    private func pressSystemButton(_ label: String, toward direction: XCUIRemote.Button) {
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let buttons = board.alerts.buttons.matching(NSPredicate(format: "label == %@", label))
        let focused = buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<3 {
            guard buttons.firstMatch.exists else { return }
            if !focused.waitForExistence(timeout: 1) { XCUIRemote.shared.press(direction) }
            guard focused.waitForExistence(timeout: 3) else { continue }
            XCUIRemote.shared.press(.select)
            if buttons.firstMatch.waitForNonExistence(timeout: 2) { return }
        }
        XCTFail("System button did not complete: " + label + " " + board.debugDescription)
    }

    private func select(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        if target.identifier.hasPrefix("purchase-") {
            let focused = XCUIApplication().buttons.matching(NSPredicate(format: "hasFocus == YES AND identifier BEGINSWITH 'purchase-'")).firstMatch
            for _ in 0..<6 {
                if target.hasFocus { XCUIRemote.shared.press(.select); return }
                guard focused.exists else { break }
                let dx = target.frame.midX - focused.frame.midX
                let dy = target.frame.midY - focused.frame.midY
                let direction: XCUIRemote.Button = abs(dy) > focused.frame.height / 2
                    ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left)
                XCUIRemote.shared.press(direction)
            }
            XCTFail("Could not reach the purchase action " + target.identifier)
            return
        }
        for direction in [XCUIRemote.Button.up, .down] {
            for _ in 0..<5 {
                if target.hasFocus { XCUIRemote.shared.press(.select); return }
                XCUIRemote.shared.press(direction)
            }
        }
        XCTFail("Could not focus \(target.identifier): \(XCUIApplication().debugDescription)")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
