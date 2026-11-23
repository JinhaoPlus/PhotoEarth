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
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()

        XCTAssertTrue(app.staticTexts["PHOTO EARTH"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["最近到访的城市"].waitForExistence(timeout: 5))
        let enterGlobe = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '滚动地球'")
        ).firstMatch
        XCTAssertTrue(enterGlobe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(enterGlobe))
        attachScreenshot(app, name: "Overview — redesigned television composition")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.otherElements["globe-direct-manipulation"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)["globe-photo-control-hint"].firstMatch.label,
            "照片"
        )
        XCTAssertTrue(app.descendants(matching: .any)["globe-zoom-control-hint"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["画面内的照片"].waitForExistence(timeout: 5))
        let memoryStrip = app.descendants(matching: .any)["memory-horizon"].firstMatch
        let photosReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "预览"), object: memoryStrip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [photosReady], timeout: 8), .completed)
        let stripCount = app.staticTexts["memory-horizon-count"]
        XCTAssertTrue(stripCount.label.contains("预览"), "A representative batch must not claim the complete viewport count")
        XCTAssertEqual(stripCount.frame.midY, app.staticTexts["memory-horizon-title"].frame.midY, accuracy: 4)

        let fullBleedScreenshot = XCTAttachment(screenshot: app.screenshot())
        fullBleedScreenshot.name = "Full-bleed globe without safe-area border"
        fullBleedScreenshot.lifetime = .keepAlways
        add(fullBleedScreenshot)

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["photo-wall-title"].waitForExistence(timeout: 5))

        attachScreenshot(app, name: "Photo wall — four-column focus layout")
        let firstPhoto = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.select)

        let viewing = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(viewing.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(viewing))
        XCTAssertTrue(app.staticTexts["photo-detail-capture-time"].exists)
        XCTAssertTrue(app.staticTexts["photo-detail-location-name"].exists)
        XCTAssertTrue(app.buttons["photo-location-globe"].exists)
        attachScreenshot(app, name: "Photo detail — inline time and location")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["photo-wall-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(firstPhoto), "Return restores the photo that opened the detail")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.otherElements["globe-direct-manipulation"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(enterGlobe), "Return restores the overview entry")
    }

    @MainActor
    func testEmptyGlobeShowsCompactStatusAfterMovingAwayFromPhotos() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--map-review-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        let city = app.buttons["overview-place-sample-map-review"]
        XCTAssertTrue(waitForFocus(city))
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(waitForFocus(globe))
        XCTAssertTrue(app.staticTexts["memory-horizon-count"].waitForExistence(timeout: 12))
        let horizon = app.descendants(matching: .any)["memory-horizon"].firstMatch
        let populatedHeight = horizon.frame.height
        for _ in 0..<40 { XCUIRemote.shared.press(.right) }
        let empty = app.staticTexts["memory-horizon-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 15))
        XCTAssertEqual(empty.label, "当前画面没有照片")
        XCTAssertFalse(app.staticTexts["memory-horizon-count"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["memory-horizon-photos"].firstMatch.exists)
        XCTAssertLessThan(horizon.frame.height, populatedHeight - 60)
        XCTAssertTrue(waitForFocus(globe))
        attachScreenshot(app, name: "Empty globe — compact status without a filmstrip placeholder")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(app.buttons["globe-zoom-in"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["globe-use-current-view"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(globe))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["没有照片"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-wall-back"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(globe), "An empty wall remains dismissible through Back")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(city))
    }

    @MainActor
    func testDifferentGlobeRegionsShowDifferentPhotoIdentities() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.down)
        var previous = Set<String>()
        for city in ["rio", "singapore"] {
            let expectedPhotoCount = city == "rio" ? 12 : 16
            let entry = app.buttons["overview-place-sample-\(city)"]
            if city == "singapore" { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(waitForFocus(entry))
            XCUIRemote.shared.press(.select)
            let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
            XCTAssertTrue(globe.waitForExistence(timeout: 5))
            XCTAssertTrue(waitForFocus(globe))
            XCTAssertTrue(app.staticTexts["memory-horizon-count"].waitForExistence(timeout: 10))
            // Open immediately after a real movement; wall capture cannot rely
            // on the filmstrip's previously settled projection.
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.select)
            let localPhoto = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "viewport-photo-sample-\(city)-")).firstMatch
            XCTAssertTrue(localPhoto.waitForExistence(timeout: 8))
            let identifiers = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).allElementsBoundByIndex.map(\.identifier))
            XCTAssertFalse(identifiers.isEmpty)
            XCTAssertTrue(app.staticTexts["\(expectedPhotoCount) 项"].waitForExistence(timeout: 3),
                          "A city wall reports its full count, not a page size")
            XCTAssertNotEqual(identifiers, previous)
            let excludedCity = city == "rio" ? "singapore" : "rio"
            XCTAssertFalse(identifiers.contains { $0.hasPrefix("viewport-photo-sample-\(excludedCity)-") })
            previous = identifiers
            attachScreenshot(app, name: "Strict current area — \(city)")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(waitForFocus(globe))
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(waitForFocus(entry))
        }
    }

    @MainActor
    func testOverviewCityShelfScrollsToMorePlaces() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()

        XCTAssertTrue(app.staticTexts["最近到访的城市"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.down)
        let recentPlace = try XCTUnwrap(waitForFocusedPlaceButton(in: app))
        XCTAssertTrue(recentPlace.hasFocus)
        XCTAssertEqual(recentPlace.identifier, "overview-place-sample-rio", "One down command enters the first row without skipping")
        let cities = ["rio", "singapore", "tokyo", "sydney", "cape-town"]
        let cards = cities.map { app.buttons["overview-place-sample-" + $0] }
        let screen = app.windows.firstMatch.frame
        let entry = app.buttons["overview-explore-button"]
        XCTAssertGreaterThan(recentPlace.frame.height, screen.height * 0.20,
                             "The city photo and caption should be readable from the sofa")
        XCTAssertGreaterThan(recentPlace.frame.minY - entry.frame.maxY, screen.height * 0.22,
                             "Leave the center of the opening composition to the globe")
        for index in cards.indices {
            let card = cards[index]
            if index > 0 {
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(waitForFocus(card), "All five cities must be reachable in order")
                XCTAssertGreaterThan(card.frame.minX - cards[index - 1].frame.maxX, 12)
            }
            XCTAssertGreaterThanOrEqual(card.frame.minX, screen.minX + 60)
            XCTAssertLessThanOrEqual(card.frame.maxX, screen.maxX - 60)
            XCTAssertLessThanOrEqual(card.frame.maxY, screen.maxY - 40)
        }
        for card in cards.dropLast().reversed() {
            XCUIRemote.shared.press(.left)
            XCTAssertTrue(waitForFocus(card))
        }

        let dockScreenshot = XCTAttachment(screenshot: app.screenshot())
        dockScreenshot.name = "Recently visited cities over the globe"
        dockScreenshot.lifetime = .keepAlways
        add(dockScreenshot)

        XCUIRemote.shared.press(.down)
        let year = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "overview-year-")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        let additionalPlace = try XCTUnwrap(
            waitForFocusedPlaceButton(in: app, excludingLabel: recentPlace.label)
        )
        XCTAssertTrue(additionalPlace.hasFocus)

        let shelfScreenshot = XCTAttachment(screenshot: app.screenshot())
        shelfScreenshot.name = "Additional city and country shelf"
        shelfScreenshot.lifetime = .keepAlways
        add(shelfScreenshot)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(recentPlace), "Moving up from the first year shelf returns to the city above")
    }

    @MainActor
    func testPlayPauseProvidesZoomWithoutOpeningPhotoWall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(entry))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["globe-direct-manipulation"].waitForExistence(timeout: 5))
        let globeNodes = app.descendants(matching: .any).matching(identifier: "globe-direct-manipulation")
        XCTAssertEqual(globeNodes.count, 1, "The press capture bridge must not duplicate the accessible input surface")
        XCTAssertTrue(waitForFocus(globeNodes.firstMatch), "The unique accessible input surface owns focus on entry")
        XCUIRemote.shared.press(.playPause)
        let zoomIn = app.buttons["globe-zoom-in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(zoomIn))
        XCTAssertEqual(globeNodes.count, 0, "The direct input surface is hidden from accessibility while the toolbar owns focus")
        XCTAssertFalse(app.staticTexts["photo-wall-title"].exists)
        let controls = app.descendants(matching: .any)["globe-controls"].firstMatch
        let dock = app.descendants(matching: .any)["globe-zoom-dock"].firstMatch
        XCTAssertTrue(controls.exists)
        XCTAssertTrue(dock.exists)
        let drag = app.descendants(matching: .any)["globe-controls-pan-hint"].firstMatch
        XCTAssertTrue(drag.exists)
        XCTAssertLessThan(drag.frame.maxY, app.frame.height / 4)
        XCTAssertGreaterThan(drag.frame.minX, app.frame.midX)
        XCTAssertLessThanOrEqual(dock.frame.maxY, app.frame.maxY - 88,
                                 "The floating glass controls must leave map attribution unobstructed")
        XCTAssertLessThan(dock.frame.width, app.frame.width * 0.5,
                          "Zoom controls leave the Earth as the visual subject")
        let openingDistance = try cameraDistance(controls)
        attachScreenshot(app, name: "Liquid Glass zoom — focused approach over an unobscured Earth")

        XCUIRemote.shared.press(.right)
        let style = app.buttons["globe-style"]
        XCTAssertTrue(waitForFocus(style))
        XCTAssertEqual(style.label, "卫星")
        attachScreenshot(app, name: "Map style switch — focused satellite selection")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(style.label, "地图")
        XCTAssertTrue(waitForFocus(style), "Changing map style retains the focused action")
        XCTAssertEqual(try cameraDistance(controls), openingDistance, accuracy: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        attachScreenshot(app, name: "Global exploration — standard map at the same camera")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(style.label, "卫星")
        XCTAssertEqual(try cameraDistance(controls), openingDistance, accuracy: 2)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(zoomIn))

        // Physical directions navigate native button focus. Touch dragging is
        // covered by model/input tests; XCUIRemote cannot reproduce a clickpad pan.
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.left)
        let zoomOut = app.buttons["globe-zoom-out"]
        XCTAssertTrue(waitForFocus(zoomOut))
        XCTAssertEqual(try cameraDistance(controls), openingDistance, accuracy: 1)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(zoomIn))
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(try cameraDistance(controls), openingDistance)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(zoomOut))
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(try cameraDistance(controls), openingDistance, accuracy: 2,
                       "Symmetric controls return to the same scale")
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(zoomIn.exists)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertEqual(globeNodes.count, 1)
        XCTAssertTrue(waitForFocus(globe), "Back closes the dock and restores direct manipulation")
        XCTAssertTrue(app.descendants(matching: .any)["globe-drag-control-hint"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["globe-turn-control-hint"].firstMatch.exists)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5))
        let reopenedFocus = waitForFocus(zoomIn)
        if !reopenedFocus { print(app.debugDescription); attachScreenshot(app, name: "Reopened zoom dock focus diagnosis") }
        XCTAssertTrue(reopenedFocus, "A new dock starts on Zoom In without inheriting old input state")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(zoomOut), "Physical arrows reach the newly installed dock")
        XCTAssertFalse(app.buttons["globe-controls-close"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(zoomIn.exists)
        XCTAssertEqual(globeNodes.count, 1)
        XCTAssertTrue(waitForFocus(globe), "Removing a reopened dock releases its Focus environment")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(globe), "Directional input stays on the restored globe")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["photo-wall-title"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testGlassZoomControlsRespectBoundaryAndBackRestoresGlobe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        if !entry.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(waitForFocus(entry))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["globe-direct-manipulation"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let globeBeforeControls = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globeBeforeControls.exists)
        let globeNodes = app.descendants(matching: .any).matching(identifier: "globe-direct-manipulation")
        XCTAssertEqual(globeNodes.count, 1, "The input surface has one accessible representation")
        XCTAssertTrue(waitForFocus(globeBeforeControls))
        let distanceBeforeControls = try cameraDistance(globeBeforeControls)
        XCUIRemote.shared.press(.playPause)
        let zoomIn = app.buttons["globe-zoom-in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(zoomIn))
        XCTAssertEqual(globeNodes.count, 0)
        let controls = app.descendants(matching: .any)["globe-controls"].firstMatch
        var previousDistance = try cameraDistance(controls)
        XCTAssertEqual(previousDistance, distanceBeforeControls, accuracy: 1,
                       "Opening with Play/Pause must not activate the newly focused zoom button")
        let style = app.buttons["globe-style"]
        XCTAssertEqual(style.label, "卫星")
        attachScreenshot(app, name: "Orbital satellite and place lights")
        for _ in 0..<14 {
            XCUIRemote.shared.press(.select)
            let before = previousDistance
            let moved = NSPredicate { _, _ in
                guard let current = try? self.cameraDistance(controls) else { return false }
                return current < before * 0.76
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)],
                                          timeout: 3), .completed)
            previousDistance = try cameraDistance(controls)
            if previousDistance < 600_000 { break }
        }
        XCTAssertLessThan(previousDistance, 600_000)
        XCTAssertEqual(style.label, "地图")
        XCTAssertTrue(waitForFocus(zoomIn))
        XCTAssertFalse(app.staticTexts["photo-wall-title"].exists)
        attachScreenshot(app, name: "Near map below 800 km")

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["globe-zoom-out"]))
        for _ in 0..<5 {
            XCUIRemote.shared.press(.select)
            let before = previousDistance
            let moved = NSPredicate { _, _ in
                guard let current = try? self.cameraDistance(controls) else { return false }
                return current > before * 1.32
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)],
                                          timeout: 3), .completed)
            previousDistance = try cameraDistance(controls)
            if previousDistance > 850_000 { break }
        }
        XCTAssertGreaterThan(previousDistance, 800_000)
        XCTAssertEqual(style.label, "卫星")
        attachScreenshot(app, name: "Return to orbital satellite")
        XCTAssertFalse(app.buttons["globe-controls-close"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(zoomIn.exists)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertEqual(globeNodes.count, 1)
        XCTAssertTrue(waitForFocus(globe), "Back restores the globe without exiting it")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(globe), "A direction command reaches the restored exploration surface")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["photo-wall-title"].waitForExistence(timeout: 5), "A subsequent short press opens the wall")
    }

    @MainActor
    func testCityEntryRestoresOverviewFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(app.buttons["overview-explore-button"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.down)
        let recent = try XCTUnwrap(waitForFocusedPlaceButton(in: app))
        XCUIRemote.shared.press(.down)
        let city = try XCTUnwrap(waitForFocusedPlaceButton(in: app, excludingLabel: recent.label))
        let identifier = city.identifier
        attachScreenshot(app, name: "Home globe before opening Cape Town")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["globe-direct-manipulation"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        attachScreenshot(app, name: "Quiet orbital Earth — Cape Town after help fades")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCUIRemote.shared.press(.menu)
        attachScreenshot(app, name: "Home globe immediately after returning")
        XCTAssertTrue(waitForFocus(app.buttons[identifier]))
    }

    @MainActor
    private func cameraDistance(_ globe: XCUIElement) throws -> Double {
        let value = try XCTUnwrap(globe.value as? String)
        let numericValue = value.filter { $0.isNumber || $0 == "." || $0 == "-" }
        let number = try XCTUnwrap(Double(numericValue), "Camera accessibility value must expose the current scale")
        return value.contains("公里") || value.contains("千米") || value.lowercased().contains("km") ? number * 1_000 : number
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.hasFocus
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
            app.useSimplifiedChineseTestLanguage()
            app.launch()
            app.enterHomeContent()
        }
    }
}
