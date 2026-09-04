//
//  PhotoEarthUITestsLaunchTests.swift
//  PhotoEarthUITests
//
//  Created by doupi on 2026/9/4.
//

import XCTest

final class PhotoEarthUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Demo Globe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
