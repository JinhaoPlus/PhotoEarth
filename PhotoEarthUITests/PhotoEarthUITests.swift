//
//  PhotoEarthUITests.swift
//  PhotoEarthUITests
//
//  Created by doupi on 2026/9/4.
//

import XCTest

final class PhotoEarthUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCompleteGlobePhotoNavigationStack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["PHOTO EARTH"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["最近抵达"].waitForExistence(timeout: 5))
        let enterGlobe = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '滚动地球'")
        ).firstMatch
        XCTAssertTrue(enterGlobe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(enterGlobe))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.staticTexts["方向键转动"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["外圈旋转缩放"].exists)
        XCTAssertTrue(app.staticTexts["按下查看照片"].exists)
        XCTAssertTrue(app.staticTexts["此刻俯瞰到的记忆"].waitForExistence(timeout: 5))

        let fullBleedScreenshot = XCTAttachment(screenshot: app.screenshot())
        fullBleedScreenshot.name = "Full-bleed globe without safe-area border"
        fullBleedScreenshot.lifetime = .keepAlways
        add(fullBleedScreenshot)

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["当前地表的记忆"].waitForExistence(timeout: 5))

        let firstPhoto = app.buttons.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.select)

        let information = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '照片信息'")
        ).firstMatch
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(information))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["拍摄时间"].waitForExistence(timeout: 3))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["当前地表的记忆"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["方向键转动"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOverviewGlassDockScrollsToMorePlaces() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["最近抵达"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.down)
        let recentPlace = try XCTUnwrap(waitForFocusedPlaceButton(in: app))
        XCTAssertTrue(recentPlace.hasFocus)

        let dockScreenshot = XCTAttachment(screenshot: app.screenshot())
        dockScreenshot.name = "Liquid Glass recent places dock"
        dockScreenshot.lifetime = .keepAlways
        add(dockScreenshot)

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.staticTexts["更多城市与国家"].waitForExistence(timeout: 5))
        let additionalPlace = try XCTUnwrap(
            waitForFocusedPlaceButton(in: app, excludingLabel: recentPlace.label)
        )
        XCTAssertTrue(additionalPlace.hasFocus)

        let shelfScreenshot = XCTAttachment(screenshot: app.screenshot())
        shelfScreenshot.name = "Additional city and country shelf"
        shelfScreenshot.lifetime = .keepAlways
        add(shelfScreenshot)
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.hasFocus
    }

    @MainActor
    private func waitForFocusedPlaceButton(
        in app: XCUIApplication,
        excludingLabel: String? = nil,
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = app.buttons.allElementsBoundByIndex.first(where: {
                $0.hasFocus
                    && !$0.label.contains("滚动地球")
                    && $0.label != excludingLabel
            }) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--demo"]
            app.launch()
        }
    }
}
