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
        XCTAssertTrue(app.buttons["slideshow-opening-music"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-media"].firstMatch.exists)
        attach(app, "Earth Slideshow — opening with Start focused")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(begin))
        XCTAssertTrue(waitForFocus(app.buttons["overview-slideshow"]), app.debugDescription)
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
        beginSlideshow(in: app)
        let media = app.descendants(matching: .any)["slideshow-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        let selection = app.descendants(matching: .any)["slideshow-photo-selection"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != nil AND value != ''"), object: media)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        print("Slideshow local fixture scope=library remoteToDisplayed=\(startTime.duration(to: .now))")
        XCTAssertFalse(selection.exists)
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-playback-progress"].firstMatch.exists)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-play-pause"]))
        XCUIRemote.shared.press(.down)
        let firstID = try XCTUnwrap(media.value as? String)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-select-photo-\(firstID)"]))
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
        XCTAssertTrue(waitForDisappearance(selection))
        XCTAssertEqual(media.value as? String, selectedID)
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

        let recentVisit = app.buttons["library-collection-sample-reykjavik"]
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
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(start), "The visible slideshow entry must be reachable from the photo grid")
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-chapter"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-media"].firstMatch.waitForExistence(timeout: 10))
        let selection = app.descendants(matching: .any)["slideshow-photo-selection"].firstMatch
        let location = app.descendants(matching: .any)["slideshow-location-globe"].firstMatch
        XCTAssertFalse(selection.exists)
        XCTAssertTrue(location.waitForExistence(timeout: 5))
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

        XCUIRemote.shared.press(.playPause)
        let controls = app.descendants(matching: .any)["slideshow-controls"].firstMatch
        let playPause = app.buttons["slideshow-play-pause"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.label.contains("继续"), "Play/Pause must freeze the whole slideshow clock")
        XCTAssertTrue(waitForFocus(playPause))
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["slideshow-return"].exists)
        XCTAssertGreaterThan(selection.frame.maxY, app.frame.maxY - 120)
        attach(app, "Earth Slideshow — paused controls over a memory")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(playPause.label.contains("暂停"), "Resuming starts the control auto-hide window")
        XCTAssertTrue(waitForDisappearance(selection))
        XCTAssertTrue(
            waitForDisappearance(controls, timeout: 8),
            "Playback and music chrome should automatically retreat while the slideshow keeps playing"
        )
        let restoredLocation = app.descendants(matching: .any)["slideshow-location-globe"].firstMatch
        XCTAssertTrue(restoredLocation.waitForExistence(timeout: 5))
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
        XCTAssertFalse(slideshow.exists)
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
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-chapter"].firstMatch.waitForExistence(timeout: 8))
        let replay = app.buttons["slideshow-replay"]
        XCTAssertTrue(waitForFocus(replay, timeout: 20))
        XCTAssertFalse(app.buttons["slideshow-return"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-chapter"].firstMatch.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(slideshow.exists)
        XCTAssertTrue(waitForFocus(firstPhoto))
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

        let quiet = app.buttons["slideshow-online-playlist-quiet-moments"]
        let onlineSource = app.buttons["slideshow-music-source-online"]
        let appleMusicSource = app.buttons["slideshow-music-source-apple"]
        XCTAssertTrue(waitForFocus(quiet, timeout: 15))
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
        XCTAssertTrue(waitForFocus(slideshowPlayPause))
        XCUIRemote.shared.press(.up)
        let musicPlayPause = app.buttons["slideshow-music-play-pause"]
        let musicPanel = app.descendants(matching: .any)["slideshow-music-controls"].firstMatch
        let playbackPanel = app.descendants(matching: .any)["slideshow-playback-controls"].firstMatch
        let musicTitle = app.descendants(matching: .any)["slideshow-music-title"].firstMatch
        let musicArtist = app.descendants(matching: .any)["slideshow-music-artist"].firstMatch
        XCTAssertTrue(musicPlayPause.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(musicPlayPause))
        XCTAssertFalse(soundtrack.exists)
        XCTAssertFalse(app.buttons["slideshow-music-choose"].exists)
        XCTAssertTrue(musicPlayPause.label.contains("暂停配乐"))
        XCTAssertTrue(musicPanel.exists)
        XCTAssertTrue(playbackPanel.exists)
        // tvOS includes the focused button halo on one axis of an
        // accessibility container. Its unaffected axis remains the stable
        // 300 pt card measurement; the SwiftUI background is 300 × 300 pt.
        let musicPanelDimensions = [musicPanel.frame.width, musicPanel.frame.height].sorted()
        XCTAssertEqual(musicPanelDimensions[0], 300, accuracy: 8)
        XCTAssertLessThan(musicPanelDimensions[1], 400)
        XCTAssertGreaterThan(musicPanel.frame.midX, app.frame.midX)
        XCTAssertLessThan(musicPanel.frame.midY, app.frame.midY)
        XCTAssertGreaterThanOrEqual(musicPanel.frame.minY, app.frame.minY)
        XCTAssertGreaterThan(playbackPanel.frame.midY, app.frame.midY)
        XCTAssertTrue(musicPanel.label.contains("背景音乐"), "The icon-only panel keeps its VoiceOver group name")
        XCTAssertFalse(app.staticTexts["背景音乐"].exists, "The music group title is no longer visibly rendered")
        XCTAssertEqual(musicTitle.label, "Quiet Journeys")
        XCTAssertEqual(musicArtist.label, "Photo Earth")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(app.frame.intersects(musicPlayPause.frame), "Music controls stay inside the TV canvas")
        attach(app, "Earth Slideshow — selected background music")

        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(slideshowPlayPause.label, "继续")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(slideshowPlayPause))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(slideshow.exists, "Back first returns to unobstructed playback")
        XCTAssertTrue(waitForDisappearance(musicPanel))
        XCTAssertTrue(waitForDisappearance(playbackPanel))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(slideshow), "A second Back press leaves the unobstructed slideshow")
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
        XCTAssertTrue(app.staticTexts["连接网络后重试，或返回并开始放映。"].exists)
        XCTAssertFalse(app.buttons["slideshow-online-playlist-quiet-moments"].exists)
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
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["slideshow-play-pause"]))
        XCTAssertFalse(app.descendants(matching: .any)["slideshow-music-controls"].firstMatch.exists)
    }

    @MainActor
    func testOnlineMusicStreamsAndUsesExistingSlideshowControls() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--slideshow-long-dwell-fixture",
            "--slideshow-observe-music",
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
        XCTAssertTrue(quiet.waitForExistence(timeout: 15))
        XCTAssertTrue(road.exists)
        XCTAssertTrue(waitForFocus(quiet))
        let appleMusic = app.buttons["slideshow-music-source-apple"]
        let turnOff = app.buttons["slideshow-music-off"]
        XCTAssertTrue(appleMusic.exists)
        XCTAssertTrue(turnOff.exists)
        XCTAssertFalse(turnOff.isEnabled)
        let firstQuiet = onlineTrack(in: app, slug: "quiet-village-1")
        let secondQuiet = onlineTrack(in: app, slug: "quiet-village-2")
        XCTAssertTrue(firstQuiet.waitForExistence(timeout: 5))
        XCTAssertEqual(firstQuiet.label, "Quiet Village 1")
        XCTAssertLessThan(quiet.frame.midX, firstQuiet.frame.midX)
        attach(app, "Soundtrack — categories and tracks")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(firstQuiet))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(secondQuiet))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(waitForFocus(soundtrack))
        XCTAssertFalse(media.exists)
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
        XCTAssertTrue(waitForFocus(slideshowPlayPause))
        XCUIRemote.shared.press(.up)

        let musicPlayPause = app.buttons["slideshow-music-play-pause"]
        let musicPanel = app.descendants(matching: .any)["slideshow-music-controls"].firstMatch
        let title = app.descendants(matching: .any)["slideshow-music-title"].firstMatch
        let previous = app.buttons["slideshow-music-previous"]
        let next = app.buttons["slideshow-music-next"]
        XCTAssertTrue(waitForFocus(musicPlayPause))
        XCTAssertFalse(soundtrack.exists)
        waitForOnlineAudio(musicPanel, state: "playing")
        XCTAssertEqual(title.label, "Quiet Village 2")

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(previous))
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(title, label: "Quiet Village 1")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(next))
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(title, label: "Quiet Village 2")
        waitForOnlineAudio(musicPanel, state: "playing")
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(previous))
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(title, label: "Quiet Village 1")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(musicPlayPause))
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(musicPanel, state: "paused")
        XCTAssertTrue(media.exists)
        XCUIRemote.shared.press(.select)
        waitForOnlineAudio(musicPanel, state: "playing")

        XCUIRemote.shared.press(.playPause)
        waitForOnlineAudio(musicPanel, state: "paused")
        XCUIRemote.shared.press(.playPause)
        waitForOnlineAudio(musicPanel, state: "playing")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForDisappearance(musicPanel))
        XCUIRemote.shared.press(.menu)
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
        _ element: XCUIElement, state: String? = nil, label: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = if let state {
            NSPredicate(format: "exists == true AND value == %@", state)
        } else {
            NSPredicate(format: "exists == true AND label == %@", label ?? "")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    func testCurrentViewPhotoWallCanStartAndLeaveSlideshow() throws {
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
        XCTAssertFalse(app.buttons["photo-wall-map-review"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(start))
        XCUIRemote.shared.press(.select)
        beginSlideshow(in: app)

        let slideshow = app.descendants(matching: .any)["earth-slideshow"].firstMatch
        XCTAssertTrue(slideshow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["slideshow-chapter"].firstMatch.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(slideshow.exists)
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
        XCUIRemote.shared.press(.menu)
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
