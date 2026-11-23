import Combine
import Foundation
import MusicKit

enum SlideshowMusicAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

enum SlideshowAppleMusicAccessState: Equatable, Sendable {
    case needsAuthorization
    case checking
    case available
    case notSubscribed
    case denied
    case restricted
    case temporarilyUnavailable
}

enum SlideshowMusicChoiceKind: String, Equatable, Sendable {
    case song
    case album
    case playlist
    case station
}

struct SlideshowMusicChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: SlideshowMusicChoiceKind
    let artworkURL: URL?
}

struct SlideshowMusicBrowseContent: Equatable, Sendable {
    var recentlyPlayed: [SlideshowMusicChoice]
    var playlists: [SlideshowMusicChoice]
    var songs: [SlideshowMusicChoice]

    static let empty = SlideshowMusicBrowseContent(
        recentlyPlayed: [],
        playlists: [],
        songs: []
    )

    var isEmpty: Bool {
        recentlyPlayed.isEmpty && playlists.isEmpty && songs.isEmpty
    }
}

struct SlideshowMusicNowPlaying: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    var onlineTrack: OnlineSlideshowPlaylist.Track? = nil
}

struct SlideshowMusicPlaybackSnapshot: Equatable, Sendable {
    var isPlaying: Bool
    var nowPlaying: SlideshowMusicNowPlaying?
    var failed = false

    static let stopped = SlideshowMusicPlaybackSnapshot(isPlaying: false, nowPlaying: nil)
}

@MainActor
protocol SlideshowMusicPermissionProviding: AnyObject {
    var authorizationStatus: SlideshowMusicAuthorizationState { get }
    func requestAuthorization() async -> SlideshowMusicAuthorizationState
}

@MainActor
protocol SlideshowMusicPlaying: AnyObject {
    func playbackUpdates() -> AsyncStream<SlideshowMusicPlaybackSnapshot>
    func play() async throws -> SlideshowMusicPlaybackSnapshot
    func pause() -> SlideshowMusicPlaybackSnapshot
    func stop()
    func skipToNext() async throws -> SlideshowMusicPlaybackSnapshot
    func skipToPrevious() async throws -> SlideshowMusicPlaybackSnapshot
    func playbackSnapshot() -> SlideshowMusicPlaybackSnapshot
}

@MainActor
protocol SlideshowAppleMusicDriving: SlideshowMusicPlaying {
    func canPlayCatalogContent() async throws -> Bool
    func subscriptionUpdates() -> AsyncStream<Bool>
    func browse() async throws -> SlideshowMusicBrowseContent
    func search(_ term: String) async throws -> [SlideshowMusicChoice]
    func prepare(_ choice: SlideshowMusicChoice) async throws -> SlideshowMusicPlaybackSnapshot
}

@MainActor
final class SlideshowMusicController: ObservableObject {
    @Published private(set) var accessState: SlideshowAppleMusicAccessState = .needsAuthorization
    @Published private(set) var browseContent = SlideshowMusicBrowseContent.empty
    @Published private(set) var searchResults: [SlideshowMusicChoice] = []
    @Published private(set) var selectedChoice: SlideshowMusicChoice?
    @Published private(set) var nowPlaying: SlideshowMusicNowPlaying?
    @Published private(set) var isActuallyPlaying = false
    @Published private(set) var wantsMusicPlayback = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingBrowse = false
    @Published private(set) var isSearching = false
    @Published private(set) var isPreparingSelection = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackError: String?

    var isUsingOnlineMusic: Bool {
        guard let queue else { return false }
        return queue === onlineDriver
    }

    private let readAuthorization: @MainActor () -> SlideshowMusicAuthorizationState
    private let requestPermission: @MainActor () async -> SlideshowMusicAuthorizationState
    private let makeDriver: @MainActor () -> any SlideshowAppleMusicDriving
    private var driver: (any SlideshowAppleMusicDriving)?
    let recommendations: OnlineMusicRecommendations
    private let onlineDriver: OnlineSlideshowMusicDriver
    private var queue: (any SlideshowMusicPlaying)?
    private var preparingAppleDriver: (any SlideshowAppleMusicDriving)?
    private var selectionTask: Task<Bool, Never>?
    private var session = UUID()
    private var subscriptionTask: Task<Void, Never>?
    private var playbackObservationTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var hasActivated = false
    private var hasLoadedBrowse = false
    private var slideshowPaused = false
    private var presentationActive = false
    private var originalAudioActive = false
    private var sceneActive = true

    init(readAuthorization: @escaping @MainActor () -> SlideshowMusicAuthorizationState,
         requestPermission: @escaping @MainActor () async -> SlideshowMusicAuthorizationState,
         makeDriver: @escaping @MainActor () -> any SlideshowAppleMusicDriving,
         onlineDriver: OnlineSlideshowMusicDriver? = nil,
         recommendations: OnlineMusicRecommendations? = nil) {
        self.recommendations = recommendations ?? OnlineMusicRecommendations()
        self.readAuthorization = readAuthorization
        self.requestPermission = requestPermission
        self.makeDriver = makeDriver
        self.onlineDriver = onlineDriver ?? OnlineSlideshowMusicDriver()
    }

    convenience init<Driver: SlideshowAppleMusicDriving & SlideshowMusicPermissionProviding>(driver: Driver) {
        self.init(readAuthorization: { driver.authorizationStatus },
                  requestPermission: { await driver.requestAuthorization() },
                  makeDriver: { driver })
    }

    static func makeDefault() -> SlideshowMusicController {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--apple-music-fixture") {
            return SlideshowMusicController(driver: FixtureSlideshowMusicDriver())
        }
#endif
        return SlideshowMusicController(
            readAuthorization: { MusicKitSlideshowMusicDriver.authorizationState(MusicAuthorization.currentStatus) },
            requestPermission: { MusicKitSlideshowMusicDriver.authorizationState(await MusicAuthorization.request()) },
            makeDriver: { MusicKitSlideshowMusicDriver() }
        )
    }

    func activate() async {
        guard !hasActivated else { return }
        hasActivated = true
        await refreshAccess()
    }

    /// Refreshing an existing decision never opens a system permission prompt.
    /// The prompt is reserved for an explicit press on Choose Music.
    func refreshAccess() async {
        guard hasActivated else { return }
        errorMessage = nil
        switch readAuthorization() {
        case .notDetermined:
            accessState = .needsAuthorization
            releaseUnauthorizedDriver()
        case .denied:
            accessState = .denied
            releaseUnauthorizedDriver()
        case .restricted:
            accessState = .restricted
            releaseUnauthorizedDriver()
        case .authorized:
            await checkSubscription()
        }
    }

    @discardableResult
    func connect() async -> Bool {
        guard !isConnecting else { return accessState == .available }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let token = session
        let existingStatus = readAuthorization()
        let status = existingStatus == .notDetermined ? await requestPermission() : existingStatus
        guard session == token, !Task.isCancelled else { return false }
        switch status {
        case .notDetermined:
            accessState = .needsAuthorization
        case .denied:
            accessState = .denied
        case .restricted:
            accessState = .restricted
        case .authorized:
            await checkSubscription()
        }
        return accessState == .available
    }

    func loadBrowseIfNeeded() async {
        guard let driver, accessState == .available, !isLoadingBrowse else { return }
        guard !hasLoadedBrowse else { return }
        isLoadingBrowse = true
        errorMessage = nil
        defer { isLoadingBrowse = false }
        do {
            browseContent = try await driver.browse()
            hasLoadedBrowse = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.unavailableMessage
        }
    }

    func reloadBrowse() async {
        hasLoadedBrowse = false
        await loadBrowseIfNeeded()
    }

    func search(_ rawTerm: String) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        guard let driver, accessState == .available else { return }
        isSearching = true
        errorMessage = nil
        do {
            let results = try await driver.search(term)
            guard !Task.isCancelled else { return }
            searchResults = results
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            errorMessage = Self.unavailableMessage
        }
        isSearching = false
    }

    @discardableResult
    func select(_ choice: SlideshowMusicChoice) async -> Bool {
        guard let driver, accessState == .available else { return false }
        return await prepareSelection { [self] token in
            guard accessState == .available else { return false }
            preparingAppleDriver = driver
            errorMessage = nil
            do {
                let snapshot = try await driver.prepare(choice)
                guard session == token, !Task.isCancelled, accessState == .available else { return false }
                installQueue(driver, choice: choice, snapshot: snapshot)
                return true
            } catch {
                guard session == token, !Task.isCancelled, accessState == .available else { return false }
                errorMessage = Self.unavailableMessage
                return false
            }
        }
    }

    var onlineTrackID: OnlineSlideshowPlaylist.Track.ID? {
        isUsingOnlineMusic ? onlineDriver.currentTrackID : nil
    }

    @discardableResult
    func selectOnline(_ playlist: OnlineSlideshowPlaylist, startingAt trackID: OnlineSlideshowPlaylist.Track.ID,
                      explicitTrackChoice: Bool) async -> Bool {
        guard let track = playlist.tracks.first(where: { $0.id == trackID }) else { return false }
        if isUsingOnlineMusic, selectedChoice?.id == playlist.id, onlineTrackID == trackID, playbackError == nil {
            if explicitTrackChoice { recommendations.recordChoice(track) }
            return true
        }
        return await prepareSelection { [self] token in
            do {
                let snapshot = try await onlineDriver.prepare(playlist, startingAt: trackID)
                guard session == token, !Task.isCancelled else { return false }
                let choice = SlideshowMusicChoice(
                    id: playlist.id, title: playlist.displayTitle, subtitle: nil, kind: .playlist, artworkURL: nil
                )
                installQueue(onlineDriver, choice: choice, snapshot: snapshot)
                if explicitTrackChoice { recommendations.recordChoice(track) }
                return true
            } catch {
                return false
            }
        }
    }

    func cancelSelection() {
        selectionTask?.cancel()
    }

    private func prepareSelection(_ prepare: @escaping @MainActor (UUID) async -> Bool) async -> Bool {
        guard selectionTask == nil, !Task.isCancelled else { return false }
        let token = session
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return false }
            return await prepare(token)
        }
        selectionTask = task
        isPreparingSelection = true
        defer {
            if session == token {
                selectionTask = nil
                preparingAppleDriver = nil
                isPreparingSelection = false
                pauseForOriginalAudioOrScheduleReconciliation()
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func toggleMusicPlayback() {
        guard selectedChoice != nil, queue != nil else { return }
        wantsMusicPlayback.toggle()
        playbackError = nil
        pauseForOriginalAudioOrScheduleReconciliation()
    }

    func skipToNext() async {
        guard let queue, selectedChoice != nil else { return }
        playbackError = nil
        do {
            let snapshot = try await queue.skipToNext()
            guard self.queue === queue, !Task.isCancelled else { return }
            apply(snapshot)
            await reconcilePlayback()
        } catch {
            guard self.queue === queue, !Task.isCancelled else { return }
            playbackError = isUsingOnlineMusic ? Self.onlineUnavailableMessage : Self.unavailableMessage
        }
    }

    func skipToPrevious() async {
        guard let queue, selectedChoice != nil else { return }
        playbackError = nil
        do {
            let snapshot = try await queue.skipToPrevious()
            guard self.queue === queue, !Task.isCancelled else { return }
            apply(snapshot)
            await reconcilePlayback()
        } catch {
            guard self.queue === queue, !Task.isCancelled else { return }
            playbackError = isUsingOnlineMusic ? Self.onlineUnavailableMessage : Self.unavailableMessage
        }
    }

    func updatePlaybackContext(
        slideshowPaused: Bool,
        presentationActive: Bool,
        originalAudioActive: Bool,
        sceneActive: Bool
    ) {
        let transportChanged = self.slideshowPaused != slideshowPaused
            || self.presentationActive != presentationActive
            || self.sceneActive != sceneActive
        guard transportChanged || self.originalAudioActive != originalAudioActive else { return }
        self.slideshowPaused = slideshowPaused
        self.presentationActive = presentationActive
        self.originalAudioActive = originalAudioActive
        self.sceneActive = sceneActive
        if isUsingOnlineMusic {
            onlineDriver.setDucked(originalAudioActive)
            guard transportChanged else { return }
        }
        pauseForOriginalAudioOrScheduleReconciliation()
    }

    func clearMusic() {
        reconciliationTask?.cancel()
        playbackObservationTask?.cancel()
        reconciliationTask = nil
        playbackObservationTask = nil
        queue?.stop()
        queue = nil
        selectedChoice = nil
        nowPlaying = nil
        wantsMusicPlayback = false
        isActuallyPlaying = false
        playbackError = nil
    }

    func stopAndReset() {
        recommendations.resetSession()
        subscriptionTask?.cancel()
        subscriptionTask = nil
        cancelSelection()
        selectionTask = nil
        if let preparingAppleDriver, queue !== preparingAppleDriver { preparingAppleDriver.stop() }
        preparingAppleDriver = nil
        if !isUsingOnlineMusic { onlineDriver.stop() }
        clearMusic()
        driver = nil
        session = UUID()
        accessState = .needsAuthorization
        hasActivated = false
        hasLoadedBrowse = false
        browseContent = .empty
        searchResults = []
        isConnecting = false
        isLoadingBrowse = false
        isSearching = false
        isPreparingSelection = false
        errorMessage = nil
    }

    private func checkSubscription() async {
        guard readAuthorization() == .authorized else { return }
        let driver = self.driver ?? makeDriver()
        self.driver = driver
        if subscriptionTask == nil { observeSubscription(driver) }
        let token = session
        accessState = .checking
        do {
            let canPlay = try await driver.canPlayCatalogContent()
            guard session == token, readAuthorization() == .authorized, !Task.isCancelled else { return }
            accessState = canPlay ? .available : .notSubscribed
            if canPlay {
                pauseForOriginalAudioOrScheduleReconciliation()
            } else {
                haltForAccessLoss()
            }
        } catch is CancellationError {
            return
        } catch {
            guard session == token, readAuthorization() == .authorized, !Task.isCancelled else { return }
            accessState = .temporarilyUnavailable
            errorMessage = Self.unavailableMessage
            if queue === driver { apply(driver.pause()) }
        }
    }

    private func observeSubscription(_ driver: any SlideshowAppleMusicDriving) {
        subscriptionTask?.cancel()
        let updates = driver.subscriptionUpdates()
        subscriptionTask = Task { @MainActor [weak self] in
            for await canPlay in updates {
                guard let self, !Task.isCancelled else { return }
                guard readAuthorization() == .authorized else {
                    await refreshAccess()
                    return
                }
                accessState = canPlay ? .available : .notSubscribed
                if canPlay {
                    pauseForOriginalAudioOrScheduleReconciliation()
                } else {
                    haltForAccessLoss()
                }
            }
        }
    }

    private func installQueue(
        _ driver: any SlideshowMusicPlaying,
        choice: SlideshowMusicChoice,
        snapshot: SlideshowMusicPlaybackSnapshot
    ) {
        reconciliationTask?.cancel()
        if queue !== driver {
            queue?.stop()
            queue = driver
            observePlayback(driver)
        }
        if isUsingOnlineMusic { onlineDriver.setDucked(originalAudioActive) }
        selectedChoice = choice
        wantsMusicPlayback = true
        playbackError = nil
        apply(snapshot)
    }

    private func observePlayback(_ driver: any SlideshowMusicPlaying) {
        playbackObservationTask?.cancel()
        let updates = driver.playbackUpdates()
        playbackObservationTask = Task { @MainActor [weak self] in
            for await snapshot in updates {
                guard let self, self.queue === driver, !Task.isCancelled else { return }
                apply(snapshot)
            }
        }
    }

    private func releaseUnauthorizedDriver() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        haltForAccessLoss()
        driver = nil
    }

    private func haltForAccessLoss() {
        if let preparingAppleDriver {
            cancelSelection()
            if queue !== preparingAppleDriver { preparingAppleDriver.stop() }
        }
        guard let driver, queue === driver else { return }
        clearMusic()
    }

    private func pauseForOriginalAudioOrScheduleReconciliation() {
        reconciliationTask?.cancel()
        if originalAudioActive, !isUsingOnlineMusic, let queue, preparingAppleDriver !== queue {
            reconciliationTask = nil
            apply(queue.pause())
            return
        }
        reconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcilePlayback()
        }
    }

    private func reconcilePlayback() async {
        guard let queue, selectedChoice != nil else { return }
        if let preparingAppleDriver, queue === preparingAppleDriver { return }
        guard isUsingOnlineMusic || accessState == .available else {
            apply(queue.pause())
            return
        }
        let shouldPlay = wantsMusicPlayback
            && !slideshowPaused
            && presentationActive
            && (isUsingOnlineMusic || !originalAudioActive)
            && sceneActive
        do {
            let snapshot = shouldPlay ? try await queue.play() : queue.pause()
            guard self.queue === queue, !Task.isCancelled else { return }
            apply(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard self.queue === queue, !Task.isCancelled else { return }
            apply(queue.pause())
            playbackError = isUsingOnlineMusic ? Self.onlineUnavailableMessage : Self.unavailableMessage
        }
    }

    private func apply(_ snapshot: SlideshowMusicPlaybackSnapshot) {
        isActuallyPlaying = snapshot.isPlaying
        if snapshot.failed && isUsingOnlineMusic {
            wantsMusicPlayback = false
            playbackError = Self.onlineUnavailableMessage
        }
        if let nowPlaying = snapshot.nowPlaying {
            if snapshot.isPlaying, let track = nowPlaying.onlineTrack {
                recommendations.recordPlayback(track)
            }
            self.nowPlaying = nowPlaying
        } else if let selectedChoice {
            nowPlaying = SlideshowMusicNowPlaying(
                title: selectedChoice.title,
                subtitle: selectedChoice.subtitle,
                artworkURL: selectedChoice.artworkURL
            )
        }
    }

    static var onlineUnavailableMessage: String {
        AppLocalization.string(
            "slideshow.music.online.unavailable",
            defaultValue: "Online music is unavailable. Your slideshow can continue."
        )
    }

    private static var unavailableMessage: String {
        AppLocalization.string(
            "slideshow.music.unavailable",
            defaultValue: "Apple Music is temporarily unavailable. Your slideshow can continue without it."
        )
    }
}

@MainActor
private final class MusicKitSlideshowMusicDriver: SlideshowAppleMusicDriving {
    private enum Payload {
        case song(Song)
        case album(Album)
        case playlist(Playlist)
        case recent(RecentlyPlayedMusicItem)
    }

    private lazy var player = ApplicationMusicPlayer.shared
    private var payloads: [String: Payload] = [:]
    private var playbackContinuation: AsyncStream<SlideshowMusicPlaybackSnapshot>.Continuation?
    private var playbackObservationID: UUID?
    private var preparationID: UUID?
    private var stateObservation: AnyCancellable?
    private var queueObservation: AnyCancellable?

    func canPlayCatalogContent() async throws -> Bool {
        try await MusicSubscription.current.canPlayCatalogContent
    }

    func subscriptionUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await subscription in MusicSubscription.subscriptionUpdates {
                    guard !Task.isCancelled else { return }
                    continuation.yield(subscription.canPlayCatalogContent)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func playbackUpdates() -> AsyncStream<SlideshowMusicPlaybackSnapshot> {
        AsyncStream { continuation in
            playbackContinuation?.finish()
            let observationID = UUID()
            playbackObservationID = observationID
            playbackContinuation = continuation
            bindPlaybackObservations()
            continuation.yield(playbackSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.playbackObservationID == observationID else { return }
                    self?.playbackContinuation = nil
                    self?.playbackObservationID = nil
                    self?.stateObservation?.cancel()
                    self?.stateObservation = nil
                    self?.queueObservation?.cancel()
                    self?.queueObservation = nil
                }
            }
        }
    }

    func browse() async throws -> SlideshowMusicBrowseContent {
        var successfulRequests = 0
        var firstError: Error?
        var recentItems: [RecentlyPlayedMusicItem] = []
        var playlists: [Playlist] = []
        var songs: [Song] = []

        do {
            var request = MusicRecentlyPlayedContainerRequest()
            request.limit = 12
            recentItems = Array(try await request.response().items)
            successfulRequests += 1
        } catch {
            firstError = error
        }

        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 18
            playlists = Array(try await request.response().items)
            successfulRequests += 1
        } catch {
            if firstError == nil { firstError = error }
        }

        do {
            var request = MusicRecentlyPlayedRequest<Song>()
            request.limit = 18
            songs = Array(try await request.response().items)
            successfulRequests += 1
        } catch {
            if firstError == nil { firstError = error }
        }

        if successfulRequests == 0, let firstError { throw firstError }

        return SlideshowMusicBrowseContent(
            recentlyPlayed: recentItems.map(choice),
            playlists: playlists.map(choice),
            songs: songs.map(choice)
        )
    }

    func search(_ term: String) async throws -> [SlideshowMusicChoice] {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, Album.self, Playlist.self]
        )
        request.limit = 12
        let response = try await request.response()
        return response.songs.map(choice)
            + response.albums.map(choice)
            + response.playlists.map(choice)
    }

    func prepare(_ choice: SlideshowMusicChoice) async throws -> SlideshowMusicPlaybackSnapshot {
        guard let payload = payloads[choice.id] else { throw DriverError.missingSelection }
        try Task.checkCancellation()
        let previousQueue = player.queue
        let previousEntry = previousQueue.currentEntry
        let previousTime = player.playbackTime
        let preparationID = UUID()
        self.preparationID = preparationID
        player.stop()
        var queue: ApplicationMusicPlayer.Queue
        switch payload {
        case .song(let song):
            queue = ApplicationMusicPlayer.Queue(for: [song])
        case .album(let album):
            queue = ApplicationMusicPlayer.Queue(for: [album])
        case .playlist(let playlist):
            queue = ApplicationMusicPlayer.Queue(for: [playlist])
        case .recent(let item):
            queue = ApplicationMusicPlayer.Queue(for: [item])
        }
        queue.affectsListeningHistory = false
        player.queue = queue
        // ApplicationMusicPlayer replaces its observable Queue value here.
        // Rebind so automatic advancement also refreshes the on-screen title.
        bindQueueObservation()
        player.state.repeatMode = .all
        player.state.shuffleMode = .off
        do {
            try await player.prepareToPlay()
            try Task.checkCancellation()
            guard self.preparationID == preparationID else { throw CancellationError() }
            self.preparationID = nil
            return emitPlaybackSnapshot()
        } catch {
            if self.preparationID == preparationID {
                // MusicKit stages against one shared player. Restore the old
                // queue before playback can resume after cancelling the picker.
                self.preparationID = nil
                player.stop()
                player.queue = previousQueue
                player.queue.currentEntry = previousEntry
                player.playbackTime = previousTime
                bindQueueObservation()
                emitPlaybackSnapshot()
            }
            throw error
        }
    }

    func play() async throws -> SlideshowMusicPlaybackSnapshot {
        try await player.play()
        return playbackSnapshot()
    }

    func pause() -> SlideshowMusicPlaybackSnapshot {
        player.pause()
        return playbackSnapshot()
    }

    func stop() {
        preparationID = nil
        player.stop()
    }

    func skipToNext() async throws -> SlideshowMusicPlaybackSnapshot {
        try await player.skipToNextEntry()
        return playbackSnapshot()
    }

    func skipToPrevious() async throws -> SlideshowMusicPlaybackSnapshot {
        try await player.skipToPreviousEntry()
        return playbackSnapshot()
    }

    func playbackSnapshot() -> SlideshowMusicPlaybackSnapshot {
        Self.snapshot(of: player)
    }

    private func bindPlaybackObservations() {
        stateObservation?.cancel()
        stateObservation = player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                // ObservableObject publishes immediately before mutation.
                await Task.yield()
                self?.emitPlaybackSnapshot()
            }
        }
        bindQueueObservation()
    }

    private func bindQueueObservation() {
        queueObservation?.cancel()
        guard playbackContinuation != nil else {
            queueObservation = nil
            return
        }
        queueObservation = player.queue.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.emitPlaybackSnapshot()
            }
        }
    }

    @discardableResult
    private func emitPlaybackSnapshot() -> SlideshowMusicPlaybackSnapshot {
        let snapshot = playbackSnapshot()
        if preparationID == nil { playbackContinuation?.yield(snapshot) }
        return snapshot
    }

    private func choice(_ item: RecentlyPlayedMusicItem) -> SlideshowMusicChoice {
        let kind: SlideshowMusicChoiceKind
        switch item {
        case .album: kind = .album
        case .playlist: kind = .playlist
        case .station: kind = .station
        @unknown default: kind = .station
        }
        let result = SlideshowMusicChoice(
            id: choiceID(kind: kind, musicID: item.id),
            title: item.title,
            subtitle: item.subtitle,
            kind: kind,
            artworkURL: item.artwork?.url(width: 480, height: 480)
        )
        payloads[result.id] = .recent(item)
        return result
    }

    private func choice(_ item: Playlist) -> SlideshowMusicChoice {
        let result = SlideshowMusicChoice(
            id: choiceID(kind: .playlist, musicID: item.id),
            title: item.name,
            subtitle: item.curatorName,
            kind: .playlist,
            artworkURL: item.artwork?.url(width: 480, height: 480)
        )
        payloads[result.id] = .playlist(item)
        return result
    }

    private func choice(_ item: Song) -> SlideshowMusicChoice {
        let result = SlideshowMusicChoice(
            id: choiceID(kind: .song, musicID: item.id),
            title: item.title,
            subtitle: item.artistName,
            kind: .song,
            artworkURL: item.artwork?.url(width: 480, height: 480)
        )
        payloads[result.id] = .song(item)
        return result
    }

    private func choice(_ item: Album) -> SlideshowMusicChoice {
        let result = SlideshowMusicChoice(
            id: choiceID(kind: .album, musicID: item.id),
            title: item.title,
            subtitle: item.artistName,
            kind: .album,
            artworkURL: item.artwork?.url(width: 480, height: 480)
        )
        payloads[result.id] = .album(item)
        return result
    }

    private func choiceID(kind: SlideshowMusicChoiceKind, musicID: MusicItemID) -> String {
        "\(kind.rawValue):\(musicID.rawValue)"
    }

    private static func snapshot(of player: ApplicationMusicPlayer) -> SlideshowMusicPlaybackSnapshot {
        let entry = player.queue.currentEntry
        return SlideshowMusicPlaybackSnapshot(
            isPlaying: player.state.playbackStatus == .playing,
            nowPlaying: entry.map {
                SlideshowMusicNowPlaying(
                    title: $0.title,
                    subtitle: $0.subtitle,
                    artworkURL: $0.artwork?.url(width: 240, height: 240)
                )
            }
        )
    }

    fileprivate static func authorizationState(
        _ status: MusicAuthorization.Status
    ) -> SlideshowMusicAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
    }

    private enum DriverError: Error {
        case missingSelection
    }
}

#if DEBUG
@MainActor
private final class FixtureSlideshowMusicDriver: SlideshowAppleMusicDriving, SlideshowMusicPermissionProviding {
    private(set) var authorizationStatus: SlideshowMusicAuthorizationState = .notDetermined
    private var selected: SlideshowMusicChoice?
    private var playing = false

    private let choices = [
        SlideshowMusicChoice(
            id: "fixture:playlist:quiet-journeys",
            title: "Quiet Journeys",
            subtitle: "Photo Earth",
            kind: .playlist,
            artworkURL: nil
        ),
        SlideshowMusicChoice(
            id: "fixture:album:night-train",
            title: "Night Train",
            subtitle: "Northern Lights",
            kind: .album,
            artworkURL: nil
        ),
        SlideshowMusicChoice(
            id: "fixture:song:sea-of-memory",
            title: "Sea of Memory",
            subtitle: "Atlas Ensemble",
            kind: .song,
            artworkURL: nil
        ),
    ]

    func requestAuthorization() async -> SlideshowMusicAuthorizationState {
        authorizationStatus = .authorized
        return .authorized
    }

    func canPlayCatalogContent() async throws -> Bool { true }

    func subscriptionUpdates() -> AsyncStream<Bool> {
        AsyncStream { _ in }
    }

    func playbackUpdates() -> AsyncStream<SlideshowMusicPlaybackSnapshot> {
        AsyncStream { continuation in continuation.yield(playbackSnapshot()) }
    }

    func browse() async throws -> SlideshowMusicBrowseContent {
        SlideshowMusicBrowseContent(
            recentlyPlayed: Array(choices.prefix(2)),
            playlists: [choices[0]],
            songs: [choices[2]]
        )
    }

    func search(_ term: String) async throws -> [SlideshowMusicChoice] {
        choices.filter {
            $0.title.localizedCaseInsensitiveContains(term)
                || ($0.subtitle?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    func prepare(_ choice: SlideshowMusicChoice) async throws -> SlideshowMusicPlaybackSnapshot {
        if selected != nil,
           ProcessInfo.processInfo.arguments.contains("--slideshow-music-selection-delay-fixture") {
            try await Task.sleep(for: .seconds(8))
        }
        selected = choice
        playing = false
        return playbackSnapshot()
    }

    func play() async throws -> SlideshowMusicPlaybackSnapshot {
        playing = selected != nil
        return playbackSnapshot()
    }

    func pause() -> SlideshowMusicPlaybackSnapshot {
        playing = false
        return playbackSnapshot()
    }

    func stop() {
        playing = false
        selected = nil
    }

    func skipToNext() async throws -> SlideshowMusicPlaybackSnapshot { playbackSnapshot() }
    func skipToPrevious() async throws -> SlideshowMusicPlaybackSnapshot { playbackSnapshot() }

    func playbackSnapshot() -> SlideshowMusicPlaybackSnapshot {
        SlideshowMusicPlaybackSnapshot(
            isPlaying: playing,
            nowPlaying: selected.map {
                SlideshowMusicNowPlaying(
                    title: $0.title,
                    subtitle: $0.subtitle,
                    artworkURL: $0.artworkURL
                )
            }
        )
    }
}
#endif
