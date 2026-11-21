import XCTest

final class PhotoGlobeNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPublicGlobeDeepLinkReturnsToAppHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let home = app.buttons["overview-explore-button"]
        XCTAssertTrue(focus(home))
        app.open(try XCTUnwrap(URL(string: "photoearth://globe")))
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(globe.waitForNonExistence(timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        if !home.hasFocus {
            let tabHome = app.buttons["tab-home"]
            let tabHomeRow = app.cells.containing(.button, identifier: "tab-home").firstMatch
            XCTAssertTrue(tabHome.hasFocus || (tabHomeRow.exists && tabHomeRow.hasFocus),
                          "The app's native sidebar must focus Home after leaving the external route")
            attach(app, "Top Shelf Globe returns to native Home")
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(focus(home))
        XCTAssertTrue(app.buttons["overview-place-sample-reykjavik"].exists)
        attach(app, "Home content after Top Shelf Globe return")
    }

    @MainActor func testViewportPhotoLocationReturnsThroughItsDetailAndWall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let entry = app.buttons["overview-explore-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(focus(entry))
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(globe))
        let sourceCamera = globe.value as? String
        XCUIRemote.shared.press(.select)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-sample-reykjavik-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.select)
        try exploreFromDetail(app, expectedCity: "reykjavik", expectedTitle: "雷克雅未克")
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        XCTAssertEqual(globe.value as? String, sourceCamera)
    }

    @MainActor func testCountryPhotoLocationReturnsThroughItsDetailAndCountry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        let home = app.buttons["overview-explore-button"]
        XCTAssertTrue(focus(home))
        XCUIRemote.shared.press(.menu)
        let leftHome = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == false"), object: home)
        XCTAssertEqual(XCTWaiter.wait(for: [leftHome], timeout: 5), .completed)
        attach(app, "Countries navigation — open sidebar")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let country = app.buttons["library-collection-country:region:IS"]
        XCTAssertTrue(country.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(country))
        XCUIRemote.shared.press(.select)
        let all = app.buttons["library-country-photos"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(all))
        XCUIRemote.shared.press(.select)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-sample-reykjavik-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.select)
        try exploreFromDetail(app, expectedCity: "reykjavik", expectedTitle: "雷克雅未克")
        XCTAssertTrue(focus(photo))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(all))
    }

    @MainActor func testReturningFromPhotoLocationKeepsFrozenViewportPaging() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--map-review-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        app.enterHomeContent()
        XCTAssertTrue(focus(app.buttons["overview-explore-button"]))
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-1"]))
        XCUIRemote.shared.press(.select)
        let viewing = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(focus(viewing))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(app.buttons["photo-information-toggle"]))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focus(app.buttons["photo-location-globe"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(viewing))
        for _ in 0..<48 { XCUIRemote.shared.press(.right) }
        let nextPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '49'"), object: viewing)
        XCTAssertEqual(XCTWaiter.wait(for: [nextPage], timeout: 8), .completed)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(app.buttons["viewport-photo-sample-paris-49"]))
    }

    @MainActor private func exploreFromDetail(_ app: XCUIApplication, expectedCity: String, expectedTitle: String) throws {
        let viewing = app.descendants(matching: .any)["photo-detail-image"].firstMatch
        XCTAssertTrue(viewing.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(viewing))
        let sourcePosition = viewing.value as? String
        XCTAssertFalse(app.buttons["photo-location-globe"].exists, "The map is created only when controls are requested")
        XCUIRemote.shared.press(.select)
        let info = app.buttons["photo-information-toggle"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(info))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["拍摄时间"].waitForExistence(timeout: 3))
        XCUIRemote.shared.press(.down)
        let miniature = app.buttons["photo-location-globe"]
        XCTAssertTrue(miniature.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(miniature), "The location globe is reachable directly from the information control")
        XCTAssertLessThan(miniature.frame.midX, app.frame.width / 2)
        XCTAssertGreaterThan(miniature.frame.midY, app.frame.height / 2)
        attach(app, "Photo detail — focused location globe")
        XCUIRemote.shared.press(.select)
        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 8))
        XCTAssertTrue(focus(globe))
        XCTAssertFalse(app.buttons["photo-information-toggle"].exists)
        XCTAssertFalse(app.buttons["photo-location-globe"].exists)
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let distance = self.cameraDistanceMeters(from: globe.value) else { return false }
            return abs(distance - 800_000) < 2
        }, object: nil)
        let arrivalResult = XCTWaiter.wait(for: [arrived], timeout: 12)
        XCTAssertEqual(arrivalResult, .completed, "Observed camera accessibility value: \(String(describing: globe.value))")
        attach(app, "Full-screen globe — photo location")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(focus(app.buttons["globe-zoom-in"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(focus(app.buttons["globe-use-current-view"]))
        XCUIRemote.shared.press(.right)
        let style = app.buttons["globe-style"]
        XCTAssertTrue(focus(style))
        let automaticStyle = style.label
        let manualStyle = automaticStyle == "地图" ? "卫星" : "地图"
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(style.label, manualStyle)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        attach(app, "Photo destination with shared map controls")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(style.label, automaticStyle)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe), "The photo destination restores the usual remote controls")
        XCUIRemote.shared.press(.select)
        let enabledPhotos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-' AND isEnabled == true"))
        let localPhoto = enabledPhotos.matching(NSPredicate(format: "identifier BEGINSWITH %@", "viewport-photo-sample-\(expectedCity)-")).firstMatch
        XCTAssertTrue(localPhoto.waitForExistence(timeout: 8), "The new wall reads the new camera, not the old collection or viewport")
        let title = app.staticTexts.matching(identifier: "photo-wall-title")
            .matching(NSPredicate(format: "isEnabled == true")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, expectedTitle, "Photo detail exploration should retain the photo's city scope")
        XCTAssertTrue(enabledPhotos.allElementsBoundByIndex.allSatisfy { $0.identifier.hasPrefix("viewport-photo-sample-\(expectedCity)-") })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(globe))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focus(viewing), "Back from a photo location restores the originating photo")
        XCTAssertEqual(viewing.value as? String, sourcePosition)
        XCTAssertFalse(app.buttons["photo-information-toggle"].exists)
        XCUIRemote.shared.press(.menu)
    }

    private func cameraDistanceMeters(from value: Any?) -> Double? {
        guard let text = value as? String,
              let number = Double(text.filter(\.isNumber)) else { return nil }
        let lowercased = text.lowercased()
        return text.contains("公里") || lowercased.contains("km") || lowercased.contains("kilometer")
            ? number * 1_000
            : number
    }

    @MainActor private func focus(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)], timeout: 5) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
