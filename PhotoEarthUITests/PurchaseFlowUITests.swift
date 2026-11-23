import XCTest
import StoreKitTest

@MainActor
final class PurchaseFlowUITests: XCTestCase {
    private let prefix = "com.doupi.PhotoEarth.PhotoEarth."

    func testClaimTrialExpireBuyRestoreAndRefund() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        let trial = app.buttons["purchase-trial"]
        let buy = app.buttons["purchase-buy"]
        XCTAssertTrue(trial.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(buy.label.contains("6.99"))
        attach(app, "Seven-day trial and full unlock")
        select(trial)
        confirmPurchase("Free trial confirmation")
        let connect = app.buttons["welcome-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(session.allTransactions().map(\.productIdentifier), [prefix + "trial7days"])
        select(connect)
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 35), app.debugDescription)
        attach(app, "Trial opens personal globe")
        // Advance only the app's clock. StoreKit keeps the original verified transaction.
        app.terminate()
        app.launchEnvironment["PHOTOEARTH_STORE_CLOCK_OFFSET"] = String(7 * 86400 + 1)
        app.launch()
        XCTAssertTrue(buy.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Your free trial has ended"].exists)
        XCTAssertFalse(trial.exists)
        XCTAssertFalse(connect.exists)
        XCTAssertFalse(app.buttons["overview-explore-button"].exists)
        try app.open(XCTUnwrap(URL(string: "photoearth://globe")))
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        XCTAssertEqual(session.allTransactions().count, 1)
        attach(app, "Unlock after seven days")
        session.disableDialogs = true
        select(app.buttons["purchase-restore"])
        XCTAssertTrue(app.staticTexts["purchase-notice"].waitForExistence(timeout: 12))
        XCTAssertFalse(trial.exists)
        attach(app, "Expired trial after restore")
        session.disableDialogs = false
        select(buy)
        confirmPurchase("Full unlock confirmation")
        XCTAssertTrue(app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch.waitForExistence(timeout: 14), app.debugDescription)
        let lifetime = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == prefix + "lifetime" })
        app.terminate()
        app.launch()
        XCTAssertTrue(connect.waitForExistence(timeout: 12))
        try session.refundTransaction(identifier: lifetime.identifier)
        XCTAssertTrue(buy.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(connect.exists)
        XCTAssertFalse(trial.exists)
    }

    func testTrialExpiresWhileTheAppStaysOpen() async throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        session.disableDialogs = true
        _ = try await session.buyProduct(identifier: prefix + "trial7days")
        let tx = try XCTUnwrap(session.allTransactions().first)
        app.terminate()
        let end = tx.purchaseDate.addingTimeInterval(7 * 86400)
        // Launch shortly before the exact boundary, then let real time cross it.
        app.launchEnvironment["PHOTOEARTH_STORE_CLOCK_OFFSET"] = String(end.timeIntervalSinceNow - 16)
        app.launch()
        XCTAssertTrue(app.buttons["welcome-connect"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your free trial has ended"].waitForExistence(timeout: 24))
        XCTAssertFalse(app.buttons["welcome-connect"].exists)
        XCTAssertFalse(app.buttons["purchase-trial"].exists)
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    func testSampleAndCancelledPurchaseLeaveTrialAvailable() throws {
        continueAfterFailure = false
        let (app, session) = try launchStore()
        select(app.buttons["purchase-sample"])
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 15))
        XCTAssertTrue(session.allTransactions().isEmpty)
        app.openSidebarDestination("tab-settings")
        let connect = app.buttons["settings-scan"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        select(connect)
        let buy = app.buttons["purchase-buy"]
        select(buy)
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let cancel = board.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        pressSystemButton("Cancel", toward: .left)
        XCTAssertTrue(app.buttons["purchase-trial"].waitForExistence(timeout: 8))
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCTAssertFalse(app.buttons["welcome-connect"].exists)
    }

    private func launchStore() throws -> (XCUIApplication, SKTestSession) {
        let app = XCUIApplication()
        app.launchEnvironment["PHOTOEARTH_UI_OWNED_FIXTURE"] = "0"
        app.launchArguments = ["--welcome-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // StoreKitTest resolves the target via LaunchServices even on a fresh simulator.
        app.launch()
        app.terminate()
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
        // All purchase actions form a single native vertical focus group.
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
