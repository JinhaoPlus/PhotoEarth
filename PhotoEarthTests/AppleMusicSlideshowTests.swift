import AVFoundation
import Foundation
import Testing
@testable import PhotoEarth

@Suite(.serialized)
@MainActor
struct AppleMusicSlideshowTests {
    @Test(arguments: [SlideshowMusicAuthorizationState.notDetermined, .denied, .restricted])
    func silentSlideshowNeverCreatesAMusicDriver(authorization: SlideshowMusicAuthorizationState) async {
        let driver = TestSlideshowMusicDriver(authorization: authorization)
        var creations = 0
        let controller = SlideshowMusicController(
            readAuthorization: { driver.authorizationStatus },
            requestPermission: { await driver.requestAuthorization() },
            makeDriver: { creations += 1; return driver })
        await controller.activate()
        controller.updatePlaybackContext(slideshowPaused: false, presentationActive: true,
                                         originalAudioActive: false, sceneActive: true)
        await controller.refreshAccess()
        await controller.loadBrowseIfNeeded()
        await controller.search("test")
        let selected = await controller.select(driver.fixtureChoice)
        #expect(!selected)
        controller.toggleMusicPlayback()
        await controller.skipToNext()
        await controller.skipToPrevious()
        await Task.yield()
        controller.stopAndReset()
        controller.stopAndReset()
        #expect(creations == 0)
        #expect(driver.authorizationRequestCount == 0)
        #expect(driver.subscriptionCheckCount == 0)
        #expect(driver.subscriptionObservationCount == 0)
        #expect(driver.playbackObservationCount == 0)
        #expect(driver.stopCount == 0)
        #expect(driver.pauseCount == 0)
    }

    @Test func decliningAnExplicitConnectionDoesNotCreateAMusicDriver() async {
        let driver = TestSlideshowMusicDriver(authorization: .notDetermined, requestedAuthorization: .denied)
        var creations = 0
        let controller = SlideshowMusicController(
            readAuthorization: { driver.authorizationStatus },
            requestPermission: { await driver.requestAuthorization() },
            makeDriver: { creations += 1; return driver })
        await controller.activate()
        let connected = await controller.connect()
        #expect(!connected)
        #expect(controller.accessState == .denied)
        controller.stopAndReset()
        #expect(creations == 0)
        #expect(driver.authorizationRequestCount == 1)
    }

    @Test(arguments: [SlideshowMusicAuthorizationState.authorized, .denied, .restricted])
    func choosingMusicRespectsTheExistingSystemDecision(authorization: SlideshowMusicAuthorizationState) async {
        let driver = TestSlideshowMusicDriver(authorization: authorization, canPlayCatalogContent: true)
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        let connected = await controller.connect()
        #expect(connected == (authorization == .authorized))
        #expect(driver.authorizationRequestCount == 0)
    }

    @Test func explicitConnectionChecksSubscriptionAndUnlocksSelection() async {
        let driver = TestSlideshowMusicDriver(
            authorization: .notDetermined,
            requestedAuthorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()

        let connected = await controller.connect()

        #expect(connected)
        #expect(controller.accessState == .available)
        #expect(driver.authorizationRequestCount == 1)
        #expect(driver.subscriptionCheckCount == 1)
        #expect(driver.subscriptionObservationCount == 1)
        #expect(driver.playbackObservationCount == 0)
        controller.stopAndReset()
        #expect(driver.stopCount == 0)
    }

    @Test func AuthorizedNonSubscriberKeepsSlideshowUsableWithoutMusic() async {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: false
        )
        let controller = SlideshowMusicController(driver: driver)

        await controller.activate()

        #expect(controller.accessState == .notSubscribed)
        #expect(controller.selectedChoice == nil)
        #expect(!controller.wantsMusicPlayback)
    }

    @Test func subscriptionFailureIsNotMisreportedAsNoSubscription() async {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            subscriptionCheckFails: true
        )
        let controller = SlideshowMusicController(driver: driver)

        await controller.activate()

        #expect(controller.accessState == .temporarilyUnavailable)
        #expect(controller.errorMessage != nil)
    }

    @Test func selectedMusicFollowsSlideshowPauseAndYieldsToOriginalAudio() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: true,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )

        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { driver.prepareCount == 1 && driver.pauseCount > 0 }
        #expect(!controller.isActuallyPlaying)

        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        try await waitUntil { controller.isActuallyPlaying }

        let counts = (driver.playCount, driver.pauseCount)
        for _ in 0..<3 {
            controller.updatePlaybackContext(
                slideshowPaused: false,
                presentationActive: true,
                originalAudioActive: false,
                sceneActive: true
            )
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(controller.isActuallyPlaying)
        #expect(driver.playCount == counts.0)
        #expect(driver.pauseCount == counts.1)

        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: true,
            sceneActive: true
        )
        #expect(!controller.isActuallyPlaying)

        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        try await waitUntil { controller.isActuallyPlaying }

        controller.toggleMusicPlayback()
        try await waitUntil { !controller.isActuallyPlaying }
        let playCountAfterManualPause = driver.playCount
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: true,
            sceneActive: true
        )
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.playCount == playCountAfterManualPause)
        #expect(!controller.wantsMusicPlayback)
    }

    @Test func onlineMusicDucksAndRecoversWhileBothPlayersKeepAdvancing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestAudio(to: url)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recommendations = OnlineMusicRecommendations(defaults: defaults)
        let musicPlayer = AVPlayer()
        let originalPlayer = AVPlayer(url: url)
        defer { originalPlayer.pause() }
        let driver = TestSlideshowMusicDriver(authorization: .denied)
        let controller = SlideshowMusicController(
            readAuthorization: { driver.authorizationStatus },
            requestPermission: { await driver.requestAuthorization() },
            makeDriver: { driver },
            onlineDriver: OnlineSlideshowMusicDriver(makePlayer: { musicPlayer }),
            recommendations: recommendations
        )
        defer { controller.stopAndReset() }
        func setOriginalAudio(_ active: Bool) {
            controller.updatePlaybackContext(
                slideshowPaused: false, presentationActive: true, originalAudioActive: active, sceneActive: true
            )
        }

        let track = OnlineSlideshowPlaylist.Track(title: "Fixture", artist: "", url: url, themeID: "fixture")
        let playlist = OnlineSlideshowPlaylist(id: "fixture", tracks: [track], presentation: nil)
        setOriginalAudio(false)
        try #require(await controller.selectOnline(playlist, startingAt: track.id, explicitTrackChoice: false))
        try await waitUntil(timeout: .seconds(3)) { controller.isActuallyPlaying }
        #expect(musicPlayer.volume == 1)
        #expect(recommendations.recentCategoryChoices.isEmpty)
        #expect(recommendations.recentlyPlayedStreams == [track.id.absoluteString])

        originalPlayer.play()
        try await waitUntil(timeout: .seconds(3)) { originalPlayer.timeControlStatus == .playing }
        let musicTime = musicPlayer.currentTime()
        let originalTime = originalPlayer.currentTime()
        setOriginalAudio(true)
        #expect(controller.isActuallyPlaying)
        try await waitUntil { musicPlayer.volume == 0.5 }
        #expect(controller.isActuallyPlaying)
        #expect(musicPlayer.currentTime() > musicTime)
        #expect(originalPlayer.currentTime() > originalTime)

        originalPlayer.pause()
        setOriginalAudio(false)
        try await waitUntil { musicPlayer.volume == 1 }
        #expect(controller.isActuallyPlaying)
        controller.toggleMusicPlayback()
        try await waitUntil { !controller.isActuallyPlaying }
        setOriginalAudio(true)
        setOriginalAudio(false)
        #expect(!controller.wantsMusicPlayback)
        #expect(musicPlayer.timeControlStatus == .paused)

        let mix = recommendations.playlists(for: [playlist])[0]
        try #require(await controller.selectOnline(mix, startingAt: track.id, explicitTrackChoice: true))
        #expect(controller.selectedChoice?.id == OnlineSlideshowPlaylist.recommendedID)
        await controller.skipToNext()
        #expect(controller.nowPlaying?.onlineTrack?.themeID == playlist.id)
        #expect(recommendations.recentCategoryChoices == [playlist.id])
    }

    @Test func losingCatalogPlaybackStopsMusicWithoutCancellingTheSlideshow() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { controller.isActuallyPlaying }

        driver.sendSubscriptionUpdate(false)

        try await waitUntil { controller.accessState == .notSubscribed }
        #expect(driver.stopCount > 0)
        #expect(!controller.wantsMusicPlayback)
        #expect(!controller.isActuallyPlaying)
    }

    @Test func browseAndCatalogSearchExposeSongsAlbumsAndPlaylists() async {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()

        await controller.loadBrowseIfNeeded()
        await controller.search("journey")

        #expect(controller.browseContent.recentlyPlayed == [driver.fixtureChoice])
        #expect(controller.searchResults == [driver.fixtureChoice])
        #expect(driver.browseCount == 1)
        #expect(driver.searchTerms == ["journey"])
    }

    @Test func playerQueueUpdatesRefreshNowPlayingMetadata() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: true,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { driver.pauseCount > 0 }

        let nextTrack = SlideshowMusicNowPlaying(
            title: "Night Train",
            subtitle: "Northern Lights",
            artworkURL: nil
        )
        driver.sendPlaybackUpdate(
            SlideshowMusicPlaybackSnapshot(isPlaying: false, nowPlaying: nextTrack)
        )

        try await waitUntil { controller.nowPlaying == nextTrack }
    }

    @Test func cancellingPendingMusicSelectionResumesThePreviousQueue() async throws {
        let driver = TestSlideshowMusicDriver(authorization: .authorized, canPlayCatalogContent: true)
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: false, presentationActive: true, originalAudioActive: false, sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { controller.isActuallyPlaying }
        controller.updatePlaybackContext(
            slideshowPaused: true, presentationActive: true, originalAudioActive: false, sceneActive: true
        )
        try await waitUntil { !controller.isActuallyPlaying }

        let candidate = SlideshowMusicChoice(
            id: "candidate", title: "Candidate", subtitle: nil, kind: .song, artworkURL: nil
        )
        driver.preparationDelay = .seconds(8)
        let selection = Task { await controller.select(candidate) }
        try await waitUntil { driver.prepareCount == 2 }

        controller.cancelSelection()
        controller.updatePlaybackContext(
            slideshowPaused: false, presentationActive: true, originalAudioActive: false, sceneActive: true
        )
        #expect(await selection.value == false)
        try await waitUntil { controller.isActuallyPlaying }
        #expect(controller.selectedChoice == driver.fixtureChoice)
        #expect(controller.nowPlaying?.title == driver.fixtureChoice.title)
        #expect(!controller.isPreparingSelection)
        #expect(driver.stopCount == 0)
    }

    @Test func foregroundAccessRefreshStopsMusicAfterAuthorizationIsRevoked() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { controller.isActuallyPlaying }

        driver.setAuthorization(.denied)
        await controller.refreshAccess()

        #expect(controller.accessState == .denied)
        #expect(!controller.wantsMusicPlayback)
        #expect(!controller.isActuallyPlaying)
        #expect(driver.stopCount > 0)
    }

    @Test func skippingAQueueWhileMusicIsPausedDoesNotRestartAudio() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { controller.isActuallyPlaying }
        controller.toggleMusicPlayback()
        try await waitUntil { !controller.isActuallyPlaying }

        await controller.skipToNext()

        #expect(driver.skipCount == 1)
        #expect(!controller.wantsMusicPlayback)
        #expect(!controller.isActuallyPlaying)
    }

    @Test func leavingTheSlideshowStopsAndClearsTheApplicationMusicQueueState() async throws {
        let driver = TestSlideshowMusicDriver(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
        let controller = SlideshowMusicController(driver: driver)
        await controller.activate()
        controller.updatePlaybackContext(
            slideshowPaused: false,
            presentationActive: true,
            originalAudioActive: false,
            sceneActive: true
        )
        #expect(await controller.select(driver.fixtureChoice))
        try await waitUntil { controller.isActuallyPlaying }

        controller.stopAndReset()
        try await Task.sleep(for: .milliseconds(40))

        #expect(driver.stopCount > 0)
        #expect(controller.selectedChoice == nil)
        #expect(controller.nowPlaying == nil)
        #expect(!controller.wantsMusicPlayback)
        #expect(!controller.isActuallyPlaying)
        #expect(controller.browseContent.isEmpty)
        #expect(controller.searchResults.isEmpty)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Apple Music state")
    }
}

@MainActor
private final class TestSlideshowMusicDriver: SlideshowAppleMusicDriving, SlideshowMusicPermissionProviding {
    private(set) var authorizationStatus: SlideshowMusicAuthorizationState
    let requestedAuthorization: SlideshowMusicAuthorizationState
    let catalogPlaybackAvailable: Bool
    let subscriptionCheckFails: Bool

    private(set) var authorizationRequestCount = 0
    private(set) var subscriptionCheckCount = 0
    private(set) var subscriptionObservationCount = 0
    private(set) var playbackObservationCount = 0
    private(set) var browseCount = 0
    private(set) var searchTerms: [String] = []
    private(set) var prepareCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var skipCount = 0
    var preparationDelay: Duration?

    let fixtureChoice = SlideshowMusicChoice(
        id: "test:playlist:journey",
        title: "Journey",
        subtitle: "Test Library",
        kind: .playlist,
        artworkURL: nil
    )

    private var selectedChoice: SlideshowMusicChoice?
    private var isPlaying = false
    private var subscriptionContinuation: AsyncStream<Bool>.Continuation?
    private var playbackContinuation: AsyncStream<SlideshowMusicPlaybackSnapshot>.Continuation?

    init(
        authorization: SlideshowMusicAuthorizationState,
        requestedAuthorization: SlideshowMusicAuthorizationState = .authorized,
        canPlayCatalogContent: Bool = false,
        subscriptionCheckFails: Bool = false
    ) {
        authorizationStatus = authorization
        self.requestedAuthorization = requestedAuthorization
        catalogPlaybackAvailable = canPlayCatalogContent
        self.subscriptionCheckFails = subscriptionCheckFails
    }

    func requestAuthorization() async -> SlideshowMusicAuthorizationState {
        authorizationRequestCount += 1
        authorizationStatus = requestedAuthorization
        return requestedAuthorization
    }

    func canPlayCatalogContent() async throws -> Bool {
        subscriptionCheckCount += 1
        if subscriptionCheckFails { throw TestError.subscriptionUnavailable }
        return catalogPlaybackAvailable
    }

    func subscriptionUpdates() -> AsyncStream<Bool> {
        subscriptionObservationCount += 1
        return AsyncStream { subscriptionContinuation = $0 }
    }

    func playbackUpdates() -> AsyncStream<SlideshowMusicPlaybackSnapshot> {
        playbackObservationCount += 1
        return AsyncStream {
            playbackContinuation = $0
            $0.yield(playbackSnapshot())
        }
    }

    func browse() async throws -> SlideshowMusicBrowseContent {
        browseCount += 1
        return SlideshowMusicBrowseContent(
            recentlyPlayed: [fixtureChoice],
            playlists: [fixtureChoice],
            songs: []
        )
    }

    func search(_ term: String) async throws -> [SlideshowMusicChoice] {
        searchTerms.append(term)
        return [fixtureChoice]
    }

    func prepare(_ choice: SlideshowMusicChoice) async throws -> SlideshowMusicPlaybackSnapshot {
        prepareCount += 1
        if let preparationDelay { try await Task.sleep(for: preparationDelay) }
        selectedChoice = choice
        isPlaying = false
        return emitPlayback()
    }

    func play() async throws -> SlideshowMusicPlaybackSnapshot {
        playCount += 1
        isPlaying = selectedChoice != nil
        return emitPlayback()
    }

    func pause() -> SlideshowMusicPlaybackSnapshot {
        pauseCount += 1
        isPlaying = false
        return emitPlayback()
    }

    func stop() {
        stopCount += 1
        isPlaying = false
        _ = emitPlayback()
    }

    func skipToNext() async throws -> SlideshowMusicPlaybackSnapshot {
        skipCount += 1
        isPlaying = selectedChoice != nil
        return emitPlayback()
    }

    func skipToPrevious() async throws -> SlideshowMusicPlaybackSnapshot {
        skipCount += 1
        isPlaying = selectedChoice != nil
        return emitPlayback()
    }

    func playbackSnapshot() -> SlideshowMusicPlaybackSnapshot {
        SlideshowMusicPlaybackSnapshot(
            isPlaying: isPlaying,
            nowPlaying: selectedChoice.map {
                SlideshowMusicNowPlaying(
                    title: $0.title,
                    subtitle: $0.subtitle,
                    artworkURL: $0.artworkURL
                )
            }
        )
    }

    func sendSubscriptionUpdate(_ available: Bool) {
        subscriptionContinuation?.yield(available)
    }

    func sendPlaybackUpdate(_ snapshot: SlideshowMusicPlaybackSnapshot) {
        playbackContinuation?.yield(snapshot)
    }

    func setAuthorization(_ authorization: SlideshowMusicAuthorizationState) {
        authorizationStatus = authorization
    }

    @discardableResult
    private func emitPlayback() -> SlideshowMusicPlaybackSnapshot {
        let snapshot = playbackSnapshot()
        playbackContinuation?.yield(snapshot)
        return snapshot
    }

    private enum TestError: Error {
        case subscriptionUnavailable
    }
}
