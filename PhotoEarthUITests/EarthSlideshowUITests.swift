import XCTest

final class EarthSlideshowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBackLeavesSlideshowOpeningWithoutStartingPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-preparation-delay-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)

        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(waitForFocus(begin), app.debugDescription)
        XCTAssertEqual(app.staticTexts["slideshow-opening-title"].label, "放映")
        XCTAssertTrue(app.buttons["slideshow-opening-music"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-media"].firstMatch.exists)
        attach(app, "Earth Slideshow — opening with Start focused")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(begin))
        XCTAssertTrue(waitForFocus(app.buttons["overview-slideshow"]), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attach(app, "Home with Earth Slideshow focused")
    }

    @MainActor
    func testPortraitSlideshowFitsWithinTelevisionCanvas() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--photo-ratio-fixture", "--slideshow-long-dwell-fixture", "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        XCUIRemote.shared.press(.right)
        let start = app.buttons["overview-slideshow"]
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)
        let startTime = ContinuousClock.now
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(waitForFocus(begin))
        let confirmTime = ContinuousClock.now
        XCUIRemote.shared.press(.select)
        let chapter = app.descendants(matching: .any)["slideshow-chapter"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 4))
        XCTAssertTrue(app.frame.contains(chapter.frame), "\(chapter.frame)")
        print("Slideshow local fixture confirmToTitle=\(confirmTime.duration(to: .now))")
        attach(app, "Earth Slideshow — title over the opening globe")
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        let selection = app.descendants(matching: .any)["slideshow-photo-selection"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != nil AND value != ''"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        print("Slideshow local fixture scope=library remoteToDisplayed=\(startTime.duration(to: .now))")
        XCTAssertFalse(selection.exists)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-playback-progress"].firstMatch.exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let playPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(playPause.label.contains("暂停"))
        let playingID = try XCTUnwrap(media.value as? String)
        let currentPhoto = app.buttons["slideshow-select-photo-\(playingID)"]
        attach(app, "Playing with the current photo highlighted below the controls")
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertGreaterThan(currentPhoto.frame.minY, playPause.frame.maxY)
        XCTAssertTrue(currentPhoto.isSelected)
        XCUIRemote.shared.press(.down)
        let firstID = try XCTUnwrap(media.value as? String)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-select-photo-\(firstID)"]))
        XCTAssertTrue(playPause.label.contains("继续"))
        // The selected representatives include portrait, panorama and
        // landscape. Moving focus leaves the preview in place until Select.
        let focusedThumbnail = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'slideshow-select-photo-' AND hasFocus == true"
        )).firstMatch
        for index in 0..<3 {
            if index > 0 {
                let previousID = try XCTUnwrap(media.value as? String)
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(focusedThumbnail.exists)
                let targetID = String(focusedThumbnail.identifier.dropFirst("slideshow-select-photo-".count))
                XCTAssertNotEqual(targetID, previousID)
                XCTAssertEqual(media.value as? String, previousID)
                XCUIRemote.shared.press(.select)
                let selected = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", targetID), object: media)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
                XCTAssertTrue(waitForFocus(app.buttons["slideshow-select-photo-\(targetID)"]))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertTrue(media.exists)
            attach(app, "Slideshow fitted ratio \(index)")
        }
        let selectedID = media.value as? String
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertTrue(selection.exists)
        XCTAssertEqual(media.value as? String, selectedID)
    }

    @MainActor
    func testAutomaticEffectsFollowTheResolvedPages() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-transition-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        for expected in ["sample-tokyo-1 opening 0", "sample-rio-1 settle 780", "sample-banff-1 dissolve 720",
                         "sample-paris-1 reveal 820", "sample-collage-1 backdrop 800", "sample-collage-6 stagger 820"] {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: media)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 12), .completed, app.debugDescription)
        }
        XCUIRemote.shared.press(.left)
        let manual = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "sample-collage-4 dissolve 160"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [manual], timeout: 5), .completed)
    }

    @MainActor
    func testCollagePagesAndIndividualFilmstripSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-collage-fixture", "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        func expectPage(_ first: String, count: Int) {
            let displayed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", first), object: media)
            XCTAssertEqual(XCTWaiter.wait(for: [displayed], timeout: 12), .completed, app.debugDescription)
            if count > 1 {
                XCTAssertTrue(media.label.contains("\(count) 张照片"), media.label)
                XCTAssertFalse(app.descendants(matching: .any)["slideshow-location-globe"].firstMatch.exists)
            }
        }
        expectPage("sample-collage-1", count: 3)
        attach(app, "01 Three full-height portraits")
        // Let the three-photo page advance on its own.
        expectPage("sample-collage-4", count: 2)
        attach(app, "02 Two portraits")
        XCUIRemote.shared.press(.right)
        expectPage("sample-collage-6", count: 2)
        attach(app, "03 Portrait and landscape")
        XCUIRemote.shared.press(.right)
        expectPage("sample-sydney-8", count: 1)
        XCUIRemote.shared.press(.left)
        expectPage("sample-collage-6", count: 2)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-play-pause"]))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-select-photo-sample-collage-6"]))
        XCUIRemote.shared.press(.right)
        let landscape = app.buttons["slideshow-select-photo-sample-reykjavik-7"]
        XCTAssertTrue(waitForFocus(landscape))
        XCUIRemote.shared.press(.select)
        expectPage("sample-reykjavik-7", count: 1)
        let map = app.descendants(matching: .any)["slideshow-location-globe"].firstMatch
        XCTAssertTrue(map.exists)
        XCTAssertTrue(app.staticTexts["slideshow-capture-time"].exists)
        XCTAssertLessThan(map.frame.maxY, app.buttons["slideshow-play-pause"].frame.minY)
        attach(app, "04 Single photo inspected from the filmstrip")
        XCTAssertTrue(app.buttons["slideshow-play-pause"].label.contains("继续"))
        XCUIRemote.shared.press(.playPause)
        expectPage("sample-sydney-8", count: 1)
    }

    @MainActor
    func testFilmstripScrollsBeyondOneScreenAndBackBeforeChoosing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-filmstrip-fixture", "--slideshow-long-dwell-fixture", "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-play-pause"]))
        XCUIRemote.shared.press(.down)
        let first = app.buttons["slideshow-select-photo-sample-reykjavik-1"]
        XCTAssertTrue(waitForFocus(first))
        let initialX = first.frame.midX
        for _ in 0..<20 { XCUIRemote.shared.press(.right) }
        let target = app.buttons["slideshow-select-photo-sample-tokyo-21"]
        XCTAssertTrue(waitForFocus(target))
        XCTAssertTrue(app.frame.contains(target.frame))
        XCTAssertTrue(!first.exists || first.frame.maxX < initialX)
        XCTAssertEqual(media.value as? String, "sample-reykjavik-1")
        attach(app, "Filmstrip scrolled past the first screen")
        XCUIRemote.shared.press(.select)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "sample-tokyo-21"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-play-pause"]))
        let neighbor = app.buttons["slideshow-select-photo-sample-filmstrip-20"]
        XCTAssertGreaterThan(target.frame.width, neighbor.frame.width * 1.2)
        XCTAssertGreaterThan(target.frame.height, neighbor.frame.height * 1.2)
        XCTAssertLessThan(neighbor.frame.maxX, target.frame.minX)
        attach(app, "Playing photo enlarged within the scrolling filmstrip")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(target))
        for _ in 0..<20 { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(waitForFocus(first))
        XCTAssertTrue(app.frame.contains(first.frame))
        XCTAssertEqual(media.value as? String, "sample-tokyo-21")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(first.isSelected)
    }

    @MainActor
    func testRecentVisitStartsPausesAndReturnsToItsPhotoWall() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo",
            "--slideshow-fast-controls-fixture",
            "--slideshow-long-dwell-fixture",
        ]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let overviewEntry = app.buttons["overview-explore-button"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        app.openSidebarDestination("tab-recent")

        let recentVisit = app.buttons["library-collection-sample-rio"]
        XCTAssertTrue(recentVisit.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(recentVisit))
        XCUIRemote.shared.press(.select)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
            .firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(firstPhoto))
        attach(app, "Photo wall with slideshow action and first photo focused")
        XCUIRemote.shared.press(.up)

        let start = app.buttons["photo-wall-slideshow"]
        let review = app.buttons["photo-wall-map-review"]
        if review.exists && review.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(start), "The visible slideshow entry must be reachable from the photo grid")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attach(app, "Wall with Earth Slideshow focused")
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-journey-list"].firstMatch.exists)
        let selection = app.descendants(matching: .any)["slideshow-photo-selection"].firstMatch
        let location = app.descendants(matching: .any)["slideshow-location-globe"].firstMatch
        let captureTime = app.staticTexts["slideshow-capture-time"]
        let place = app.staticTexts["slideshow-location-name"]
        XCTAssertFalse(selection.exists)
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(captureTime.waitForExistence(timeout: 5))
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertGreaterThan(location.frame.width, 100)
        XCTAssertTrue(
            app.frame.intersects(location.frame),
            "Location must be on-screen. App: \(app.frame), location: \(location.frame)"
        )
        XCTAssertGreaterThan(
            location.frame.maxY,
            app.frame.maxY - 120,
            "Location globe must remain anchored to the television's bottom safe region. App: \(app.frame), location: \(location.frame)"
        )
        attach(app, "Earth Slideshow — immersive location")
        XCTAssertTrue(captureTime.label.contains("2024"), captureTime.label)
        XCTAssertTrue(place.label.contains("里约热内卢"), place.label)
        // MapKit may report accessibility bounds that extend beyond the clipped map tile.
        XCTAssertEqual(captureTime.frame.minX, app.frame.minX + 382, accuracy: 8)
        XCTAssertEqual(place.frame.minX, captureTime.frame.minX, accuracy: 4)
        XCTAssertLessThan(captureTime.frame.midY, place.frame.midY)
        XCTAssertEqual(place.frame.maxY, app.frame.maxY - 56, accuracy: 12)

        XCUIRemote.shared.press(.playPause)
        let controls = app.descendants(matching: .any)["slideshow-controls"].firstMatch
        let playPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.label.contains("继续"), "Play/Pause must freeze the whole slideshow clock")
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        attach(app, "Earth Slideshow — paused controls over a memory")
        XCTAssertTrue(waitForDisappearance(captureTime))
        XCTAssertTrue(waitForDisappearance(place))
        XCTAssertFalse(app.buttons["slideshow-return"].exists)
        XCTAssertGreaterThan(selection.frame.maxY, app.frame.maxY - 120)
        let neighboringButtons = ["slideshow-previous", "slideshow-play-pause", "slideshow-next", "slideshow-sound", "slideshow-restart"]
            .map { app.buttons[$0].frame }
        XCTAssertGreaterThan(playPause.frame.height, app.buttons["slideshow-next"].frame.height)
        for (left, right) in zip(neighboringButtons, neighboringButtons.dropFirst()) {
            XCTAssertLessThan(left.maxX, right.minX, "Focused transport buttons need visible space between them")
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(controls))
        XCUIRemote.shared.press(.menu)
        let stay = app.alerts.buttons.containing(.button, identifier: "slideshow-exit-stay").firstMatch
        XCTAssertTrue(waitForFocus(stay))
        XCUIRemote.shared.press(.select)
        let surface = app.descendants(matching: .any)["slideshow-viewing-surface"].firstMatch
        XCTAssertTrue(waitForFocus(surface))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertTrue(playPause.label.contains("继续"), "Staying in a paused slideshow preserves the pause")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(playPause.label.contains("暂停"), "Resuming starts the control auto-hide window")
        XCTAssertTrue(selection.exists)
        XCTAssertTrue(
            waitForDisappearance(controls, timeout: 8),
            "Playback and music chrome should automatically retreat while the slideshow keeps playing"
        )
        XCTAssertFalse(selection.exists)
        let restoredLocation = app.descendants(matching: .any)["slideshow-location-globe"].firstMatch
        XCTAssertTrue(restoredLocation.waitForExistence(timeout: 5))
        XCTAssertTrue(captureTime.waitForExistence(timeout: 5))
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            restoredLocation.frame.maxY,
            app.frame.maxY - 120,
            "Location globe must stay bottom-anchored when immersive chrome returns. App: \(app.frame), location: \(restoredLocation.frame)"
        )
        attach(app, "Earth Slideshow — immersive chrome remains bottom-anchored after controls hide")
        XCTAssertTrue(slideshow.exists)

        // The clear focus surface is intentionally absent from the tvOS
        // accessibility tree. Allow its one-yield focus handoff to settle,
        // then prove it receives the next remote command by reopening chrome.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(slideshow.exists, "The first Back press only dismisses visible playback chrome")
        XCTAssertTrue(waitForDisappearance(controls))
        XCUIRemote.shared.press(.menu)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        attach(app, "Exit slideshow confirmation")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(surface))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "暂停")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(controls))
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForDisappearance(slideshow))
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(firstPhoto), "Back returns to the source wall and restores its photo focus")
    }

    @MainActor
    func testPlayingSlideshowResumesAfterHomeRoundTrip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let overviewEntry = app.buttons["overview-explore-button"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        XCUIRemote.shared.press(.select)

        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(globe))
        XCUIRemote.shared.press(.select)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
            .firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.up)
        let start = app.buttons["photo-wall-slideshow"]
        let review = app.buttons["photo-wall-map-review"]
        if review.exists && review.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 8))
        XCTAssertTrue(media.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.activate()
        XCTAssertTrue(slideshow.waitForExistence(timeout: 8))
        XCTAssertTrue(media.waitForExistence(timeout: 8))

        XCUIRemote.shared.press(.up)
        let playPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(
            playPause.label.contains("暂停"),
            "A slideshow that was playing before Home must continue instead of returning stuck"
        )
    }

    @MainActor
    func testTripPickerCanNarrowAThousandTripsByCountry() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--home-scroll-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let remote = XCUIRemote.shared
        let picker = app.buttons["slideshow-opening-trips"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCTAssertTrue(picker.wait(for: \.isEnabled, toEqual: true, timeout: 12))
        remote.press(.left)
        XCTAssertTrue(waitForFocus(picker))
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-picker-tab-all"], timeout: 15))
        remote.press(.up)
        func menuFocused(_ menu: XCUIElement) -> Bool {
            if menu.hasFocus { return true }
            return menu.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES"))
                .firstMatch.waitForExistence(timeout: 4)
        }
        let countries = app.buttons["slideshow-picker-country"]
        XCTAssertTrue(menuFocused(countries), app.debugDescription)
        remote.press(.select)
        let japan = app.cells.containing(.any, identifier: "slideshow-picker-country-region:JP").firstMatch
        XCTAssertTrue(japan.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<12 where !japan.hasFocus { remote.press(.down) }
        XCTAssertTrue(waitForFocus(japan))
        remote.press(.select)
        XCTAssertTrue(menuFocused(countries))
        let bulk = app.buttons["slideshow-picker-bulk"]
        XCTAssertEqual(bulk.label.compactMap(\.wholeNumberValue), [1, 0, 0])
        remote.press(.right)
        let cities = app.buttons["slideshow-picker-city"]
        XCTAssertTrue(menuFocused(cities))
        remote.press(.select)
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(menuFocused(cities))
        XCTAssertEqual(bulk.label.compactMap(\.wholeNumberValue), [1])
    }

    @MainActor
    func testThousandTripsCanSelectAYearInBulkAndKeepItWhenFilteringAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--home-scroll-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let remote = XCUIRemote.shared
        let picker = app.buttons["slideshow-opening-trips"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCTAssertTrue(picker.wait(for: \.isEnabled, toEqual: true, timeout: 12))
        remote.press(.left)
        XCTAssertTrue(waitForFocus(picker))
        remote.press(.select)
        let years = app.buttons["slideshow-picker-tab-all"]
        let bulk = app.buttons["slideshow-picker-bulk"]
        let done = app.buttons["slideshow-picker-done"]
        func count(_ element: XCUIElement) -> Int? {
            Int(element.label.compactMap(\.wholeNumberValue).map(String.init).joined())
        }
        XCTAssertTrue(waitForFocus(years, timeout: 15), app.debugDescription)
        XCTAssertEqual(count(bulk), 1000)
        func chooseYear(_ year: Int) {
            let option = app.buttons["slideshow-picker-tab-\(year)"]
            remote.press(.down)
            XCTAssertTrue(waitForFocus(option))
            remote.press(.right)
            let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slideshow-picker-trip-'")).firstMatch
            XCTAssertTrue(waitForFocus(trip))
            remote.press(.up)
            XCTAssertTrue(waitForFocus(bulk), app.debugDescription)
        }
        chooseYear(2025)
        let firstCount = count(bulk) ?? 0
        XCTAssertTrue((1..<365).contains(firstCount))
        remote.press(.select)
        remote.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-picker-tab-2025"]))
        chooseYear(2024)
        let secondCount = count(bulk) ?? 0
        XCTAssertEqual(secondCount, 366)
        remote.press(.select)
        remote.press(.right)
        XCTAssertTrue(waitForFocus(done))
        attach(app, "Large trip picker — two years selected")
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCTAssertEqual(count(app.staticTexts["slideshow-opening-range"]), firstCount + secondCount)
    }

    @MainActor
    func testHomeTripPickerCommitsSelectionAndBackDiscardsEdits() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-journeys-fixture", "--slideshow-long-dwell-fixture",
                               "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let begin = app.buttons["slideshow-begin"]
        let picker = app.buttons["slideshow-opening-trips"]
        let recent = app.buttons["slideshow-picker-trip-sample-trip-tokyo-arrival"]
        let older = app.buttons["slideshow-picker-trip-sample-trip-osaka"]
        let done = app.buttons["slideshow-picker-done"]
        let remote = XCUIRemote.shared
        func enterPicker() {
            XCTAssertTrue(waitForFocus(begin))
            remote.press(.left)
            XCTAssertTrue(waitForFocus(picker))
            remote.press(.select)
        }
        enterPicker()
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-picker-tab-all"]))
        remote.press(.right)
        XCTAssertTrue(waitForFocus(recent), app.debugDescription)
        XCTAssertFalse(done.isEnabled)
        remote.press(.select)
        remote.press(.down)
        XCTAssertTrue(waitForFocus(older))
        remote.press(.select)
        XCTAssertTrue(recent.isSelected && older.isSelected)
        remote.press(.up)
        XCTAssertTrue(waitForFocus(recent))
        remote.press(.select)
        XCTAssertFalse(recent.isSelected)
        XCTAssertEqual(app.buttons["slideshow-picker-tab-selected"].label, "已选 1 段旅程")
        XCTAssertEqual(app.buttons["slideshow-picker-bulk"].label, "勾选这 2 段旅程")
        XCTAssertTrue(recent.label.contains("4月2日") && recent.label.contains("8日"), recent.label)
        attach(app, "Trip picker — older trip selected")
        remote.press(.up)
        for _ in 0..<2 where !done.hasFocus { remote.press(.right) }
        XCTAssertTrue(waitForFocus(done), app.debugDescription)
        remote.press(.select)
        XCTAssertTrue(waitForFocus(begin))
        let summary = app.staticTexts["slideshow-opening-range"]
        XCTAssertTrue(summary.label.contains("2023"), summary.label)
        enterPicker()
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-picker-tab-selected"]))
        remote.press(.right)
        XCTAssertTrue(waitForFocus(older))
        remote.press(.select)
        XCTAssertFalse(done.isEnabled)
        XCTAssertTrue(app.staticTexts["尚未选择旅程"].waitForExistence(timeout: 3))
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(begin))
        XCTAssertTrue(summary.label.contains("2023"), summary.label)
        beginSlideshow(in: app)
        waitForSlide("sample-istanbul-", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-queued-journey"].firstMatch.exists)
    }

    @MainActor
    func testHomeSlideshowCanJumpToTheNextJourneyDuringPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-journeys-fixture", "--slideshow-observe-media",
                               "--slideshow-long-dwell-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        beginSlideshow(in: app)
        waitForSlide("sample-tokyo-", in: app)
        let segment = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        let inactive = app.descendants(matching: .any)["slideshow-queued-journey"].firstMatch
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        XCTAssertTrue(inactive.label.contains("2023"), inactive.label)
        XCTAssertLessThan(segment.frame.minY, inactive.frame.minY)
        attach(app, "Journey list — first trip highlighted")
        XCUIRemote.shared.press(.select)
        let play = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(waitForFocus(play))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-next"]))
        XCUIRemote.shared.press(.right)
        let skip = app.buttons["slideshow-next-journey"]
        XCTAssertTrue(waitForFocus(skip))
        XCUIRemote.shared.press(.select)
        waitForSlide("sample-istanbul-", in: app)
        XCTAssertTrue(segment.label.contains("2023"), segment.label)
        XCTAssertTrue(inactive.label.contains("2025"), inactive.label)
        XCTAssertGreaterThan(segment.frame.minY, inactive.frame.minY)
        attach(app, "Journey list — next trip highlighted")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForFocus(play))
        XCTAssertTrue(play.label.contains("继续"))
        XCTAssertFalse(skip.exists)
    }

    @MainActor
    func testJourneyScaleShowsThreeTripsWithContinuationAtEachEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-observe-media", "--slideshow-long-dwell-fixture",
                               "--slideshow-fast-controls-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        beginSlideshow(in: app)
        waitForSlide("sample-reykjavik-", in: app)

        let list = app.descendants(matching: .any)["slideshow-journey-list"].firstMatch
        let queued = app.descendants(matching: .any).matching(identifier: "slideshow-queued-journey")
        let current = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        let moreAbove = app.descendants(matching: .any)["slideshow-journey-more-above"].firstMatch
        let moreBelow = app.descendants(matching: .any)["slideshow-journey-more-below"].firstMatch
        XCTAssertTrue(list.exists)
        XCTAssertEqual(queued.count, 2)
        XCTAssertFalse(moreAbove.exists)
        XCTAssertTrue(moreBelow.exists)
        XCTAssertGreaterThan(moreBelow.frame.minY, queued.element(boundBy: 1).frame.minY)
        attach(app, "Journey scale — start")

        XCUIRemote.shared.press(.playPause)
        let play = app.buttons["slideshow-play-pause"]
        let next = app.buttons["slideshow-next"]
        let skip = app.buttons["slideshow-next-journey"]
        for prefix in ["sample-rio-", "sample-singapore-"] {
            XCTAssertTrue(waitForFocus(play))
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(waitForFocus(next))
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(waitForFocus(skip))
            XCUIRemote.shared.press(.select)
            waitForSlide(prefix, in: app)
        }
        XCTAssertEqual(queued.count, 2)
        XCTAssertTrue(moreAbove.exists)
        XCTAssertTrue(moreBelow.exists)
        XCTAssertLessThan(queued.element(boundBy: 0).frame.minY, current.frame.minY)
        XCTAssertGreaterThan(queued.element(boundBy: 1).frame.minY, current.frame.minY)
        XCTAssertLessThan(moreAbove.frame.maxY, queued.element(boundBy: 0).frame.maxY)
        XCTAssertGreaterThan(moreBelow.frame.minY, queued.element(boundBy: 1).frame.minY)
        XCUIRemote.shared.press(.playPause)
        let controls = app.descendants(matching: .any)["slideshow-controls"].firstMatch
        XCTAssertTrue(waitForDisappearance(controls, timeout: 8))
        attach(app, "Journey scale — middle")
    }

    @MainActor
    func testCountrySlideshowPlaysTheRouteThenTheOlderJourney() {
        let app = openJapanSlideshow(cityOnly: false)
        let segment = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        waitForSlide("sample-tokyo-", in: app)
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        XCTAssertTrue(app.frame.contains(segment.frame))
        attach(app, "Japan — first trip, first visit to Tokyo")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.buttons["slideshow-select-photo-sample-tokyo-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["slideshow-select-photo-sample-banff-2"].exists)
        XCUIRemote.shared.press(.playPause)
        waitForSlide("sample-paris-", in: app)
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        waitForSlide("sample-rio-", in: app)
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        waitForSlide("sample-istanbul-", in: app)
        XCTAssertTrue(segment.label.contains("2023"), segment.label)
        attach(app, "Japan — second trip starts in Osaka")
        waitForSlide("sample-sydney-", in: app)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-replay"], timeout: 16))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch))
    }

    @MainActor
    func testCityWallPlaysEveryJourneyWithoutLeavingTheCity() throws {
        let app = openJapanSlideshow(cityOnly: true)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        let segment = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        let queued = app.descendants(matching: .any)["slideshow-queued-journey"].firstMatch
        waitForSlide("sample-tokyo-", in: app)
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        XCTAssertTrue(queued.label.contains("2023"), queued.label)

        for (prefix, year) in [("sample-rio-", "2025"), ("sample-sydney-", "2023")] {
            let previous = try XCTUnwrap(media.value as? String)
            let next = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value != nil AND value != '' AND value != %@", previous),
                object: media
            )
            XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 18), .completed, app.debugDescription)
            XCTAssertTrue((media.value as? String)?.hasPrefix(prefix) == true, media.debugDescription)
            XCTAssertTrue(segment.label.contains(year), segment.label)
        }
        attach(app, "Tokyo — older journey highlighted on the same city wall")
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-replay"], timeout: 18))
    }

    @MainActor
    func testCityWallToolbarStartsTheSameJourneyRange() {
        let app = openJapanSlideshow(cityOnly: true, startFromToolbar: true, verifyMusic: true)
        waitForSlide("sample-tokyo-", in: app)
        let current = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        let queued = app.descendants(matching: .any)["slideshow-queued-journey"].firstMatch
        XCTAssertTrue(current.label.contains("2025"), current.label)
        XCTAssertTrue(queued.label.contains("2023"), queued.label)
        XCUIRemote.shared.press(.up)
        let music = app.buttons["slideshow-playback-music"]
        XCTAssertTrue(waitForFocus(music))
        waitForOnlineAudio(music, state: "playing")
        attach(app, "Tokyo — both journeys after starting from the wall toolbar")
    }

    @MainActor
    func testCountryWallCanSkipToPreviousYearsTripWhilePaused() {
        let app = openJapanSlideshow(cityOnly: false)
        let segment = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        waitForSlide("sample-tokyo-", in: app)
        XCTAssertTrue(segment.label.contains("2025"), segment.label)
        XCUIRemote.shared.press(.playPause)
        let play = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(waitForFocus(play))
        XCTAssertTrue(play.label.contains("继续"))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-next"]))
        XCUIRemote.shared.press(.right)
        let skip = app.buttons["slideshow-next-journey"]
        XCTAssertTrue(waitForFocus(skip))
        attach(app, "Japan — next trip focused")
        XCUIRemote.shared.press(.select)
        waitForSlide("sample-istanbul-", in: app)
        XCTAssertTrue(segment.label.contains("2023"), segment.label)
        XCTAssertTrue(waitForFocus(play))
        XCTAssertTrue(play.label.contains("继续"))
        XCTAssertFalse(skip.exists)
        attach(app, "Japan — paused on the older trip")
        XCUIRemote.shared.press(.select)
        waitForSlide("sample-sydney-", in: app)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-replay"], timeout: 18))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch))
    }

    @MainActor
    private func openJapanSlideshow(cityOnly: Bool, startFromToolbar: Bool = false, verifyMusic: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-journeys-fixture", "--slideshow-observe-media"]
        if verifyMusic { app.launchArguments += ["--slideshow-observe-music", "--slideshow-long-dwell-fixture"] }
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        app.openSidebarDestination("tab-countries")
        XCTAssertTrue(waitForFocus(app.buttons["library-collection-country:region:JP"]))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["library-country-photos"]))
        if cityOnly {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(app.buttons[
                "library-collection-country:region:JP/city:tokyo-return,tokyo-arrival,tokyo-older"]))
        }
        XCUIRemote.shared.press(.select)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'")).firstMatch
        XCTAssertTrue(waitForFocus(first))
        if startFromToolbar {
            let start = app.buttons["photo-wall-slideshow"]
            let review = app.buttons["photo-wall-map-review"]
            let layout = app.buttons["photo-wall-switch-layout"]
            for _ in 0..<3 {
                if start.hasFocus || review.hasFocus || layout.hasFocus { break }
                XCUIRemote.shared.press(.up)
            }
            if review.hasFocus { XCUIRemote.shared.press(.right) }
            if layout.hasFocus { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(waitForFocus(start), app.debugDescription)
            XCUIRemote.shared.press(.select)
        } else {
            XCUIRemote.shared.press(.playPause)
        }
        XCTAssertFalse(app.buttons["slideshow-opening-trips"].exists)
        beginSlideshow(in: app)
        return app
    }

    @MainActor
    private func waitForSlide(_ prefix: String, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", prefix), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 18), .completed,
                       app.debugDescription, file: file, line: line)
    }

    @MainActor
    func testCountryPhotoWallUsesTheSameSlideshowSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let overviewEntry = app.buttons["overview-explore-button"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        app.openSidebarDestination("tab-countries")

        let country = app.buttons["library-collection-country:region:IS"]
        XCTAssertTrue(country.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(country))
        XCUIRemote.shared.press(.select)
        let allPhotos = app.buttons["library-country-photos"]
        XCTAssertTrue(allPhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(allPhotos))
        XCUIRemote.shared.press(.select)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
            .firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.up)
        let start = app.buttons["photo-wall-slideshow"]
        let review = app.buttons["photo-wall-map-review"]
        if review.exists && review.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(waitForFocus(start))
        XCTAssertEqual(start.label, "放映")
        XCUIRemote.shared.press(.select)
        let openingTitle = app.staticTexts["slideshow-opening-title"]
        XCTAssertTrue(openingTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(openingTitle.label, "冰岛")
        attach(app, "Iceland slideshow opening")
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        let chapter = app.descendants(matching: .any)["slideshow-chapter"].firstMatch
        XCTAssertTrue(chapter.exists || chapter.waitForExistence(timeout: 5))
        XCTAssertTrue(slideshow.exists)
        let replay = app.buttons["slideshow-replay"]
        XCTAssertTrue(waitForFocus(replay, timeout: 20))
        XCTAssertFalse(app.buttons["slideshow-return"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(chapter.exists || chapter.waitForExistence(timeout: 5))
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForDisappearance(slideshow))
        XCTAssertTrue(waitForFocus(firstPhoto))
    }

    @MainActor
    func testNonSubscriberCanBrowseOnlineMusicWithoutChangingSoundtrack() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--apple-music-fixture", "--apple-music-no-subscription-fixture",
                               "-PhotoEarth.slideshow.automaticMusicOff", "YES"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let opening = app.buttons["slideshow-opening-music"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCTAssertEqual(opening.label, "无配乐")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(opening))
        XCUIRemote.shared.press(.select)
        let recommended = app.buttons["slideshow-online-playlist-local.recommended"]
        XCTAssertTrue(waitForFocus(recommended, timeout: 20))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-source-online"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-source-apple"]))
        XCUIRemote.shared.press(.select)
        let browse = app.buttons["slideshow-music-browse-online"]
        XCTAssertTrue(waitForFocus(browse))
        XCTAssertEqual(app.staticTexts["slideshow-music-apple-status"].label, "订阅 Apple Music 后，可从它的曲库选歌")
        XCTAssertTrue(app.staticTexts["PHOTO EARTH 自带的在线配乐无需订阅。"].exists)
        XCTAssertFalse(app.buttons["slideshow-music-off"].exists)
        attach(app, "Apple Music subscription required")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(recommended))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(opening))
        XCTAssertEqual(opening.label, "无配乐")
    }

    @MainActor
    func testSubscriberCanChooseAndReviseAppleMusicBeforeStarting() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo",
            "--apple-music-fixture",
            "--photo-ratio-fixture",
            "--slideshow-preparation-delay-fixture",
            "--slideshow-long-dwell-fixture",
            "--slideshow-music-selection-delay-fixture",
        ]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let overviewEntry = app.buttons["overview-explore-button"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        app.openSidebarDestination("tab-recent")

        // This visit has three visibly distinct posters. The standard demo uses
        // one stock image per city, so a single-city show correctly ends after one.
        let recentVisit = app.buttons["library-collection-sample-ratio-place-0"]
        XCTAssertTrue(recentVisit.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(recentVisit))
        XCUIRemote.shared.press(.select)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
            .firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.up)
        let start = app.buttons["photo-wall-slideshow"]
        let review = app.buttons["photo-wall-map-review"]
        if review.exists && review.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 10))
        let soundtrack = app.buttons["slideshow-opening-music"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        attach(app, "Earth Slideshow — opening with optional soundtrack")
        XCUIRemote.shared.press(.select)

        let recommended = app.buttons["slideshow-online-playlist-local.recommended"]
        let onlineSource = app.buttons["slideshow-music-source-online"]
        let appleMusicSource = app.buttons["slideshow-music-source-apple"]
        XCTAssertTrue(waitForFocus(recommended, timeout: 15))
        XCTAssertTrue(onlineSource.isSelected)
        XCTAssertFalse(app.buttons["slideshow-music-close"].exists)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(onlineSource))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(appleMusicSource))
        XCUIRemote.shared.press(.select)

        let picker = app.descendants(matching: .any)["slideshow-music-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(appleMusicSource.isSelected)
        let search = app.textFields["slideshow-music-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.intersects(search.frame), "The music picker header stays inside the TV canvas")
        let choice = app.buttons["slideshow-music-choice-recent:fixture:playlist:quiet-journeys"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(choice), "The first playable choice receives focus after the library loads")
        attach(app, "Earth Slideshow — Apple Music picker")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(waitForDisappearance(picker))
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]), app.debugDescription)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCTAssertEqual(soundtrack.label, "配乐 · Quiet Journeys")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(appleMusicSource.isSelected, "Reopening follows the chosen source")
        XCTAssertTrue(waitForFocus(choice))

        let candidate = app.buttons["slideshow-music-choice-recent:fixture:album:night-train"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(candidate))
        XCUIRemote.shared.press(.select)
        let preparation = app.descendants(matching: .any)["slideshow-music-selection-progress"].firstMatch
        XCTAssertTrue(waitForFocus(preparation))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(preparation))
        XCTAssertTrue(waitForFocus(soundtrack))
        XCTAssertEqual(soundtrack.label, "配乐 · Quiet Journeys", "Cancelling selection keeps the previous soundtrack")

        XCUIRemote.shared.press(.left)
        beginSlideshow(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.up)
        let slideshowPlayPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(slideshowPlayPause.waitForExistence(timeout: 5))
        let changeSoundtrack = app.buttons["slideshow-playback-music"]
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCTAssertEqual(changeSoundtrack.label, "更换配乐")
        XCTAssertFalse(app.staticTexts["更换配乐"].exists)
        XCTAssertEqual(changeSoundtrack.frame.width, changeSoundtrack.frame.height, accuracy: 8)
        let playbackPanel = app.descendants(matching: .any)["slideshow-playback-controls"].firstMatch
        let musicPanel = app.descendants(matching: .any)["slideshow-music-controls"].firstMatch
        XCTAssertTrue(playbackPanel.exists)
        XCTAssertTrue(musicPanel.exists)
        XCTAssertFalse(soundtrack.exists)
        XCTAssertEqual(app.staticTexts["slideshow-music-title"].label, "Quiet Journeys")
        XCTAssertTrue(app.buttons["slideshow-music-previous"].exists)
        XCTAssertTrue(app.buttons["slideshow-music-play-pause"].exists)
        XCTAssertTrue(app.buttons["slideshow-music-next"].exists)
        XCTAssertGreaterThan(changeSoundtrack.frame.midX, app.frame.midX)
        XCTAssertLessThan(changeSoundtrack.frame.maxY, playbackPanel.frame.minY)
        XCTAssertLessThan(musicPanel.frame.height, 180)
        XCTAssertLessThan(musicPanel.frame.width, 285)
        XCTAssertLessThan(changeSoundtrack.frame.minX - app.buttons["slideshow-music-next"].frame.maxX, 28)
        attach(app, "Soundtrack — full controls with one Up press")

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(slideshowPlayPause))
        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(slideshowPlayPause.label, "继续")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(choice))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(candidate))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForDisappearance(picker, timeout: 15), "The delayed selection must finish before focus returns")
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCTAssertEqual(slideshowPlayPause.label, "继续")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        XCTAssertTrue(candidate.isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(slideshowPlayPause))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(slideshow.exists, "Back first returns to unobstructed playback")
        XCTAssertTrue(waitForDisappearance(changeSoundtrack))
        XCTAssertTrue(waitForDisappearance(playbackPanel))
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForDisappearance(slideshow))
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFirstOnlineMusicOpenWithoutNetworkCanRetryAndReturnToSlideshow() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-long-dwell-fixture", "--online-music-offline-fixture"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)

        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        let soundtrack = app.buttons["slideshow-opening-music"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)

        let status = app.staticTexts["slideshow-music-catalog-status"]
        let retry = app.buttons["slideshow-music-catalog-retry"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "当前没有网络连接")
        XCTAssertTrue(app.staticTexts["恢复网络连接后可播放配乐。"].exists)
        XCTAssertFalse(app.buttons["slideshow-online-playlist-local.recommended"].exists)
        XCTAssertTrue(waitForFocus(retry))
        attach(app, "Soundtrack — first open offline")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(retry))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(status))
        XCTAssertTrue(waitForFocus(soundtrack))
        XCTAssertFalse(media.exists)
        XCUIRemote.shared.press(.left)
        beginSlideshow(in: app)
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.select)
        let playPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(waitForFocus(playPause))
        let playbackPanel = app.descendants(matching: .any)["slideshow-playback-controls"].firstMatch
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(playbackPanel))
        XCUIRemote.shared.press(.up)
        let changeSoundtrack = app.buttons["slideshow-playback-music"]
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCTAssertEqual(changeSoundtrack.label, "选择配乐")
        attach(app, "Soundtrack — choose during silent playback")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(retry))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCTAssertEqual(playPause.label, "暂停")
    }

    @MainActor
    func testOnlineTrackGridKeepsLongTitlesAlignedWhileScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-opening-music"]))
        XCUIRemote.shared.press(.select)
        let category = app.buttons["slideshow-online-playlist-cinematic"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-online-playlist-local.recommended"], timeout: 20))
        for _ in 0..<12 {
            if category.exists && category.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(waitForFocus(category))
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slideshow-online-track-'"))
        let longTitle = "Poison the Sultan with Saltpeter (Slow World Version)"
        let longTile = tiles.matching(NSPredicate(format: "label == %@", longTitle)).firstMatch
        XCTAssertTrue(longTile.waitForExistence(timeout: 5))
        XCTAssertEqual(longTile.frame.height, tiles.element(boundBy: 5).frame.height, accuracy: 2)
        attach(app, "曲目网格与长曲名")
        XCUIRemote.shared.press(.right)
        let first = tiles.element(boundBy: 0)
        XCTAssertTrue(waitForFocus(first))
        let firstID = first.identifier
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists)
        XCTAssertNotEqual(focused.identifier, firstID)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(category))
    }

    @MainActor
    func testDefaultSoundtrackPlaysFirstRecommendationAndRemembersOffAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-long-dwell-fixture", "--slideshow-observe-music"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let opening = app.buttons["slideshow-opening-music"]
        XCTAssertEqual(opening.label, "配乐 · 推荐")
        beginSlideshow(in: app)

        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        let choose = app.buttons["slideshow-playback-music"]
        let title = app.staticTexts["slideshow-music-title"]
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(choose))
        waitForOnlineAudio(choose, state: "playing")
        let firstTitle = title.label
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-next"]))
        XCUIRemote.shared.press(.select)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", firstTitle), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        let secondTitle = title.label
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(choose))
        XCUIRemote.shared.press(.select)
        let recommended = app.buttons["slideshow-online-playlist-local.recommended"]
        XCTAssertTrue(waitForFocus(recommended, timeout: 15))
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slideshow-online-track-'"))
        XCTAssertEqual(tiles.element(boundBy: 0).label, firstTitle)
        XCTAssertEqual(tiles.element(boundBy: 1).label, secondTitle)
        XCTAssertTrue(tiles.element(boundBy: 1).isSelected)
        turnOffSoundtrackInPicker(in: app)
        XCTAssertTrue(waitForFocus(choose))
        XCTAssertFalse(title.exists)
        XCUIRemote.shared.press(.menu)
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForFocus(app.buttons["overview-slideshow"]))
        app.terminate()
        app.launch()
        openHomeSlideshow(in: app)
        XCTAssertEqual(opening.label, "无配乐")
        beginSlideshow(in: app)
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(choose))
        XCTAssertEqual(choose.label, "选择配乐")
        XCTAssertFalse(title.exists)
        let transport = app.buttons["slideshow-play-pause"]
        XCTAssertEqual(transport.label, "暂停", "Opening the music controls keeps photos playing")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(recommended, timeout: 15))
        XCTAssertFalse(app.buttons["slideshow-music-off"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(choose))
        XCTAssertEqual(transport.label, "暂停", "Enabling music restores the running slideshow")
        waitForOnlineAudio(choose, state: "playing")
        XCTAssertTrue(title.exists)
    }

    @MainActor
    private func turnOffSoundtrackInPicker(in app: XCUIApplication) {
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-source-online"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-source-apple"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-off"]))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func testRecommendedSoundtrackKeepsOrderAndPlaysFromChosenTrack() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-long-dwell-fixture", "--slideshow-observe-music"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)
        let soundtrack = app.buttons["slideshow-opening-music"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)
        let recommended = app.buttons["slideshow-online-playlist-local.recommended"]
        XCTAssertTrue(waitForFocus(recommended, timeout: 20))
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slideshow-online-track-'"))
        let firstIDs = (0..<3).map { tiles.element(boundBy: $0).identifier }
        let titles = (0..<3).map { tiles.element(boundBy: $0).label }
        let first = app.buttons[firstIDs[0]]
        let second = app.buttons[firstIDs[1]]
        let below = tiles.element(boundBy: 5)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)
        XCTAssertEqual(first.frame.minX, below.frame.minX, accuracy: 2)
        XCTAssertGreaterThan(below.frame.minY, first.frame.maxY)
        attach(app, "在线配乐推荐网格")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"], timeout: 15))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(recommended, timeout: 15))
        XCTAssertTrue(recommended.isSelected)
        XCTAssertTrue(app.buttons[firstIDs[0]].isSelected)
        XCTAssertEqual((0..<3).map { tiles.element(boundBy: $0).identifier }, firstIDs)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(below))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(recommended))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(second))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"], timeout: 15))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(recommended, timeout: 15))
        XCTAssertTrue(app.buttons[firstIDs[1]].isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.left)
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.up)
        let choose = app.buttons["slideshow-playback-music"]
        XCTAssertTrue(waitForFocus(choose))
        let title = app.staticTexts["slideshow-music-title"]
        XCTAssertEqual(title.label, titles[1])
        waitForOnlineAudio(choose, state: "playing")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-next"]))
        XCUIRemote.shared.press(.select)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", titles[2]), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
    }

    @MainActor
    func testOnlineMusicStreamsAndUsesExistingSlideshowControls() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--slideshow-long-dwell-fixture",
            "--slideshow-observe-music", "--slideshow-observe-media",
        ]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        openHomeSlideshow(in: app)

        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        let slideshowPlayPause = app.buttons["slideshow-play-pause"]
        let soundtrack = app.buttons["slideshow-opening-music"]
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)

        let quiet = app.buttons["slideshow-online-playlist-quiet-moments"]
        let road = app.buttons["slideshow-online-playlist-open-road"]
        let recommended = app.buttons["slideshow-online-playlist-local.recommended"]
        XCTAssertTrue(waitForFocus(recommended, timeout: 20))
        XCTAssertEqual(recommended.label, "推荐")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(road.exists)
        XCTAssertTrue(waitForFocus(quiet))
        let appleMusic = app.buttons["slideshow-music-source-apple"]
        let turnOff = app.buttons["slideshow-music-off"]
        XCTAssertTrue(appleMusic.exists)
        XCTAssertTrue(turnOff.exists)
        XCTAssertTrue(turnOff.isEnabled)
        let firstQuiet = onlineTrack(in: app, slug: "quiet-village-1")
        let secondQuiet = onlineTrack(in: app, slug: "quiet-village-2")
        XCTAssertTrue(firstQuiet.waitForExistence(timeout: 5))
        XCTAssertEqual(firstQuiet.label, "Quiet Village 1")
        XCTAssertLessThan(quiet.frame.midX, firstQuiet.frame.midX)
        attach(app, "Soundtrack — categories and tracks")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(firstQuiet))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(secondQuiet))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(waitForFocus(app.buttons["slideshow-begin"]))
        XCTAssertFalse(media.exists)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(quiet, timeout: 15))
        XCTAssertTrue(quiet.isSelected)
        XCTAssertTrue(secondQuiet.isSelected)
        XCTAssertTrue(turnOff.isEnabled)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(soundtrack))
        XCUIRemote.shared.press(.left)
        beginSlideshow(in: app)
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.up)

        let changeSoundtrack = app.buttons["slideshow-playback-music"]
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        let currentPhoto = try XCTUnwrap(media.value as? String)
        XCTAssertFalse(currentPhoto.isEmpty)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(quiet, timeout: 15))
        XCTAssertTrue(quiet.isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCTAssertEqual(media.value as? String, currentPhoto)
        XCTAssertEqual(slideshowPlayPause.label, "暂停")
        XCTAssertEqual(app.staticTexts["slideshow-music-title"].label, "Quiet Village 2")
        waitForOnlineAudio(changeSoundtrack, state: "playing")
        attach(app, "Soundtrack — compact layout over a memory")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-music-next"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCUIRemote.shared.press(.playPause)
        waitForOnlineAudio(changeSoundtrack, state: "paused")
        XCUIRemote.shared.press(.playPause)
        waitForOnlineAudio(changeSoundtrack, state: "playing")

        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCUIRemote.shared.press(.up)
        let musicPlayPause = app.buttons["slideshow-music-play-pause"]
        XCTAssertTrue(waitForFocus(musicPlayPause))
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(changeSoundtrack, state: "paused")
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(changeSoundtrack, state: "playing")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(slideshowPlayPause))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(quiet, timeout: 15))
        XCTAssertTrue(secondQuiet.isSelected)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(road))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(changeSoundtrack))
        waitForOnlineAudio(changeSoundtrack, state: "playing")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(road, timeout: 15))
        XCTAssertTrue(road.isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(changeSoundtrack))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(changeSoundtrack))
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForDisappearance(media))
    }

    @MainActor
    private func openHomeSlideshow(in app: XCUIApplication) {
        let start = app.buttons["overview-slideshow"]
        let explore = app.buttons["overview-explore-button"]
        XCTAssertTrue(explore.waitForExistence(timeout: 12))
        if !explore.isEnabled {
            app.openSidebarDestination("tab-home")
        }
        if !start.hasFocus {
            XCTAssertTrue(focusHome(in: app), app.debugDescription)
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func beginSlideshow(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let begin = app.buttons["slideshow-begin"]
        XCTAssertTrue(waitForFocus(begin), app.debugDescription, file: file, line: line)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForDisappearance(begin), app.debugDescription, file: file, line: line)
    }

    @MainActor
    private func onlineTrack(in app: XCUIApplication, slug: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow-online-track-\(slug)-")).firstMatch
    }

    @MainActor
    private func waitForOnlineAudio(
        _ element: XCUIElement, state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == true AND value == %@", state)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    func testCurrentViewPhotoWallCanStartAndLeaveSlideshow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--slideshow-journeys-fixture", "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()

        let overviewEntry = app.buttons["overview-explore-button"]
        XCTAssertTrue(overviewEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(focusHome(in: app), app.debugDescription)
        XCUIRemote.shared.press(.select)

        let globe = app.descendants(matching: .any)["globe-direct-manipulation"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(globe))
        XCUIRemote.shared.press(.select)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'viewport-photo-'"))
            .firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(firstPhoto))
        XCUIRemote.shared.press(.up)

        let start = app.buttons["photo-wall-slideshow"]
        XCTAssertFalse(app.buttons["photo-wall-map-review"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 5))
        // Verify that chapter camera moves leave the frozen wall's projection
        // usable for later pages, through the second journey.
        for prefix in ["sample-tokyo-", "sample-paris-", "sample-rio-", "sample-istanbul-"] {
            waitForSlide(prefix, in: app)
        }
        let segment = app.descendants(matching: .any)["slideshow-current-journey"].firstMatch
        XCTAssertTrue(segment.label.contains("2023"), segment.label)
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForDisappearance(slideshow))
        XCTAssertTrue(waitForFocus(firstPhoto))
    }

    @MainActor
    func testMapReviewFrozenWallPlaysAndRestoresTheSamePhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--map-review-fixture", "--slideshow-observe-media"]
        app.useSimplifiedChineseTestLanguage()
        app.launch()
        XCTAssertTrue(focusHome(in: app))
        app.openSidebarDestination("tab-recent")
        XCTAssertTrue(waitForFocus(app.buttons["library-collection-sample-map-review"]))
        XCUIRemote.shared.press(.select)
        let first = app.buttons["viewport-photo-sample-paris-1"]
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.up)
        let review = app.buttons["photo-wall-map-review"]
        let slideshowEntry = app.buttons["photo-wall-slideshow"]
        if slideshowEntry.exists && slideshowEntry.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(waitForFocus(review))
        XCUIRemote.shared.press(.select)
        let map = app.descendants(matching: .any)["map-review-direct-manipulation"].firstMatch
        XCTAssertTrue(waitForFocus(map))
        XCTAssertTrue(app.staticTexts["map-review-count"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.playPause)
        let startTime = ContinuousClock.now
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != nil AND value != ''"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        print("Slideshow local fixture scope=review-wall remoteToDisplayed=\(startTime.duration(to: .now))")
        attach(app, "Map review frozen viewport slideshow")
        app.confirmSlideshowExit()
        XCTAssertTrue(waitForFocus(first))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(map))
    }

    @MainActor
    private func focusHome(in app: XCUIApplication) -> Bool {
        let entry = app.buttons["overview-explore-button"]
        let start = app.buttons["overview-slideshow"]
        if start.exists && start.hasFocus {
            XCUIRemote.shared.press(.left)
        } else {
            app.enterHomeContent()
        }
        return waitForFocus(entry)
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !element.exists
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
