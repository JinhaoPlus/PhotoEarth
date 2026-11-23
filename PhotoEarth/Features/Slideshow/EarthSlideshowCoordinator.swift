import Combine
#if DEBUG
import CryptoKit
import Darwin
#endif
import UIKit

@MainActor final class EarthSlideshowCoordinator: ObservableObject, Identifiable {
    typealias CameraAction = @MainActor (EarthSlideshowCameraTarget, Bool) -> Void
    typealias SnapshotLoader = @MainActor () async throws -> any SlideshowPageReading

    let id = UUID()
    let scope: EarthSlideshowScope
    let configuration: EarthSlideshowConfiguration
    @Published private(set) var phase: EarthSlideshowPhase = .idle
    @Published private(set) var preparation = EarthSlideshowPreparationProgress()
    @Published private(set) var awaitsPlaybackConfirmation = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = false
    @Published var showsControls = false
    @Published var soundEnabled = false
    @Published private(set) var navigationDirection = 1
    @Published private(set) var lastViewedAssetID: String?
    @Published private(set) var activeTransition: EarthSlideshowTransition?
    @Published private(set) var canvasPage: SlideshowCanvasPage?
    private var transitionDirector = SlideshowTransitionDirector()
    private var manualTransition = false

    func transitionProgress(at time: Date) -> Double {
        guard let duration = activeTransition?.duration else { return 1 }
        let remaining = scheduledDeadline?.timeIntervalSince(time) ?? scheduledRemaining
        return min(1, max(0, 1 - remaining / duration))
    }
    @Published private(set) var mediaRetryRevision = 0

    struct FilmstripItem: Identifiable {
        let id: String
        let placeID: String
        let date: Date
        let mediaKind: PhotoMediaKind
        let ratio: CGFloat
    }

    @Published private(set) var filmstrip: [FilmstripItem] = []
    @Published private var localTiles: [SlideshowCollageFrames.Tile] = []
    var collageTiles: [SlideshowCollageFrames.Tile] { localTiles.count > 1 ? localTiles : [] }
    var singlePreview: SlideshowCollageFrames.Tile? { localTiles.count == 1 ? localTiles.first : nil }
    @Published private(set) var preparingCollage = false
    @Published private(set) var visibilityRevision = 0
    private let canvasPixels = SlideshowCollageFrames.displayPixels
    private let collageFrames: SlideshowCollageFrames
    private let collageLookahead: SlideshowCollageFrames
    private var warmedIDs: [String] = []
    private var editedAssets = Set<String>()
    // Asset-to-page ownership survives paging and reverse navigation without retaining images.
    private var displayedPage: [String: String] = [:]
    private var pageDidAppear = false
    private var visibleTileCount = 0
    @Published private(set) var inspectingPhoto = false
    private var followsFilmstripOrder = false
    private var pageCount: Int { max(1, collageTiles.count) }
    private var playlistRecords: SlideshowSnapshot?
    private var filmstripTargetCount: Int?
    private var visitsByID: [String: TravelPlace] = [:]
    @Published private(set) var currentItem: EarthSlideshowItem?
    @Published private(set) var nextItemForPrefetch: EarthSlideshowItem?
    @Published private(set) var itemIndex = 0
    @Published private var openingVisit: TravelPlace?
    private var openingCandidateIDs = Set<String>()
#if DEBUG
    private(set) var observedTransition: EarthSlideshowTransition?
    private var observation: SlideshowObservation?
#endif
    private var snapshot: (any SlideshowPageReading)?
    private var pendingJourneyIndex: Int?
    private var makeSnapshot: SnapshotLoader?
    private var places: [TravelPlace]
    @Published private(set) var availableJourneys: [EarthSlideshowSegment] = []
    @Published private(set) var selectedJourneyIDs: Set<String>?
    private var pages = SlideshowPageSequence(segments: [])

    private let cameraAction: CameraAction
    private let analyzer: PhotoSimilarityAnalyzer
    private var reduceMotion: Bool
    private var photoSpacing = SlideshowPhotoSpacing()
    private var selected = Set<String>()
    private var viewed = Set<String>()
    private var visitedPlaces = Set<EarthSlideshowChapter.ID>()
    private var lastShownVisit: TravelPlace?
    private var unavailable: [String: Int] = [:]
    private var retryingMedia = false
    private var retriedAssetID: String?
    @Published private var excluded: Set<String>
    private var preparationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var generation = UUID()
    private var scheduledAction: ScheduledAction?
    private var scheduledDeadline: Date?
    private var scheduledRemaining: TimeInterval = 0
    private let analytics: ProductAnalytics
    private let analyticsLibrary: JourneyEventContext.Library?
    private var requestTime: ContinuousClock.Instant?
    private var requestConsent: UInt64 = 0
    private var didReportMusicPicker = false
    private var soundtrack = JourneyEventContext.Music.none
    private var didReportPlaybackStart = false
    private var suspended = false
    private var resumesAfterSuspension = false

    private enum ScheduledAction {
        case finishIntro, finishChapterTitle, finishItemTransition, advanceItem, finishChapterBridge, finishEnding
    }

    init(scope: EarthSlideshowScope, places: [TravelPlace], excluded: Set<String> = [],
         analyticsLibrary: JourneyEventContext.Library? = nil, analytics: ProductAnalytics? = nil,
         configuration: EarthSlideshowConfiguration = .standard, reduceMotion: Bool,
         analyzer: PhotoSimilarityAnalyzer? = nil, imageScheduler: SharedPhotoImageScheduler? = nil,
         makeSnapshot: @escaping SnapshotLoader,
         cameraAction: @escaping CameraAction) {
        self.analyticsLibrary = analyticsLibrary
        self.analytics = analytics ?? .shared
        self.excluded = excluded
        self.collageFrames = SlideshowCollageFrames(scheduler: imageScheduler)
        self.collageLookahead = SlideshowCollageFrames(scheduler: imageScheduler)
        self.scope = scope
        self.places = places
        self.configuration = configuration
        self.reduceMotion = reduceMotion
        self.analyzer = analyzer ?? PhotoSimilarityAnalyzer()
        self.makeSnapshot = makeSnapshot
        self.cameraAction = cameraAction
    }

    private func resetPages() {
        let segments = selectedJourneyIDs.map { ids in availableJourneys.filter { ids.contains($0.id) } }
        pages = SlideshowPageSequence(segments: segments ?? availableJourneys)
    }

    func chooseJourneys(_ ids: Set<String>?) {
        guard scope.kind == .library, awaitsPlaybackConfirmation || isFailed,
              ids != selectedJourneyIDs || isFailed else { return }
        if let ids {
            guard !ids.isEmpty, ids.isSubset(of: availableJourneys.map(\.id)) else { return }
        }
        selectedJourneyIDs = ids
        prepareFromStart(waitingForConfirmation: true)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func coverAssetID(for journey: EarthSlideshowSegment) -> String? {
        journey.coverAssetID(excluding: excluded)
    }

    private var currentJourneyIndex: Int? {
        currentChapter.flatMap { pages.segmentIndex(forVisitID: $0.visit.id) }
    }
    var currentJourney: EarthSlideshowSegment? { currentJourneyIndex.map { pages.segments[$0] } }
    var currentJourneyNumber: Int { currentJourneyIndex.map { $0 + 1 } ?? 0 }
    var journeyCount: Int { pages.segments.count }
    var journeys: [EarthSlideshowSegment] { pages.segments }
    var displayedChapter: EarthSlideshowChapter? {
        phase == .earthIntro ? openingVisit.map { .init(visit: $0) } : currentChapter
    }
    var displayedJourneyIndex: Int? {
        displayedChapter.flatMap { pages.segmentIndex(forVisitID: $0.visit.id) }
    }
    var canSkipToNextJourney: Bool {
        switch phase {
        case .earthIntro, .chapterTitle, .earthChapterBridge, .presentingItem, .transitioningItem:
            return pendingJourneyIndex == nil && currentJourneyNumber > 0 && currentJourneyNumber < journeyCount
        default: return false
        }
    }

    var currentChapter: EarthSlideshowChapter? {
        guard filmstrip.indices.contains(itemIndex), let visit = visitsByID[filmstrip[itemIndex].placeID] else { return nil }
        return .init(visit: visit)
    }
    var viewedCount: Int { viewed.count }

    // Keep the ordered strip lightweight. Only the current and next playback
    // records stay resident when the viewer browses far from the playhead.
    private func playbackItem(at index: Int) throws -> EarthSlideshowItem? {
        guard filmstrip.indices.contains(index) else { return nil }
        let item = filmstrip[index]
        if currentItem?.id == item.id { return currentItem }
        if nextItemForPrefetch?.id == item.id { return nextItemForPrefetch }
        guard let playlistRecords else { throw EarthSlideshowPlanError.unavailable }
        let record = try playlistRecords.record(visitID: item.placeID, date: item.date, id: item.id)
        return .init(record: record)
    }

    private func refreshPlaybackItems() throws {
        let current = try playbackItem(at: itemIndex)
        let next = try playbackItem(at: itemIndex + pageCount)
        currentItem = current
        nextItemForPrefetch = next
    }

    private func candidates(at index: Int) -> [FilmstripItem] {
        guard filmstrip.indices.contains(index) else { return [] }
        let first = filmstrip[index]
        let owner = displayedPage[first.id]
        let prefix = filmstrip[index...].prefix(3).prefix { member in
            member.mediaKind == .photo && !editedAssets.contains(member.id) && member.ratio > 0 && member.placeID == first.placeID
                && Calendar.current.isDate(member.date, inSameDayAs: first.date)
                && abs(member.date.timeIntervalSince(first.date)) <= 1_800
                && displayedPage[member.id] == owner
        }
        let count = SlideshowCollageLayout.count(for: prefix.map(\.ratio), in: canvasPixels)
        return Array(prefix.prefix(count))
    }

    var preloadsNextSingle: Bool {
        !preparingCollage && (canvasPage == nil || canvasPage?.descriptor.ids.first == currentItem?.id)
            && candidates(at: itemIndex + pageCount).count <= 1
    }

    private func warmNextPage() {
        guard phase == .presentingItem, pageDidAppear, !suspended, pendingJourneyIndex == nil else { return }
        let members = candidates(at: itemIndex + pageCount)
        let ids = members.map(\.id)
        guard ids != warmedIDs else { return }
        collageLookahead.cancel()
        warmedIDs = ids
        if ids.count >= 2 { collageLookahead.load(members, canvas: canvasPixels, priority: .prefetch) { _ in } }
    }

    private func resetPresentationPage() {
        collageLookahead.cancel()
        warmedIDs = []
        collageFrames.cancel()
        localTiles = []
        preparingCollage = false
        pageDidAppear = false
        visibleTileCount = 0
    }

    private func preparePresentationPage() {
        guard !suspended, !inspectingPhoto else { return }
        let members = candidates(at: itemIndex)
        guard members.count >= 2 else { return }
        preparingCollage = true
        collageFrames.load(members, canvas: canvasPixels) { [weak self] tiles in
            guard let self else { return }
            localTiles = tiles
            preparingCollage = false
            do { nextItemForPrefetch = try playbackItem(at: itemIndex + pageCount) }
            catch { fail(error) }
        }
    }

    func releaseSinglePreview(for id: String) {
        if singlePreview?.id == id { localTiles = [] }
    }

    func markCollageDisplayed(_ ids: [String]) {
        guard !suspended, !pageDidAppear, !ids.isEmpty, ids == collageTiles.map(\.id),
              currentItem != nil, currentChapter != nil,
              phase == .presentingItem || phase == .transitioningItem else { return }
        commitCanvas(tiles: collageTiles)
        pageDidAppear = true
        if activeTransition?.kind != .stagger { markTilesVisible(ids, count: ids.count) }
        finishDisplayingPage()
    }

    func markTilesVisible(_ ids: [String], count: Int) {
        guard !suspended, count > visibleTileCount, count <= ids.count, ids.count > 1,
              ids == canvasPage?.descriptor.ids, ids == collageTiles.map(\.id),
              let item = currentItem, let chapter = currentChapter, item.id == ids.first else { return }
        visitedPlaces.insert(chapter.id)
        lastShownVisit = chapter.visit
        lastViewedAssetID = item.id
        for index in visibleTileCount..<count {
            let id = ids[index]
            viewed.insert(id)
            if displayedPage[id] == nil { displayedPage[id] = item.id }
#if DEBUG
            if let observation, let shown = try? playbackItem(at: itemIndex + index) {
                observation.displayed(shown.record, visitedPlaces: visitedPlaces.count, retainedItems: filmstrip.count)
            }
#endif
        }
        visibleTileCount = count
    }

    func prepareFilmstrip(around id: String?) {
        guard let id, let index = filmstrip.firstIndex(where: { $0.id == id }) else {
            filmstripTargetCount = nil
            return
        }
        filmstripTargetCount = index + 18
        fill()
    }

    func start(waitingForConfirmation: Bool = false) {
        endReport("restarted")
        requestTime = .now
        requestConsent = analytics.consentRevision
        didReportPlaybackStart = false
        didReportMusicPicker = false
        analytics.capture(.slideshowRequested, value: scope.kind.rawValue, context: .init(library: analyticsLibrary))
        prepareFromStart(waitingForConfirmation: waitingForConfirmation)
    }

    private func prepareFromStart(waitingForConfirmation: Bool = false) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-observe-media") {
            observation = try? SlideshowObservation()
        }
#endif
        invalidateProducer()
        cancelTimer()
        resetPresentationPage()
        canvasPage = nil
        activeTransition = nil
        transitionDirector = .init()
        displayedPage.removeAll()
        editedAssets.removeAll()
        inspectingPhoto = false
        followsFilmstripOrder = false
        filmstrip = []
        playlistRecords = nil
        currentItem = nil
        nextItemForPrefetch = nil
        filmstripTargetCount = nil
        itemIndex = 0
        openingVisit = nil
        openingCandidateIDs.removeAll()
        selected.removeAll()
        viewed.removeAll()
        visitedPlaces.removeAll()
        unavailable.removeAll()
        analyzer.reset()
        photoSpacing = SlideshowPhotoSpacing()
        resetPages()
        pendingJourneyIndex = nil
        retryingMedia = false
        retriedAssetID = nil
        isPaused = false
        isBuffering = false
        resumesAfterSuspension = false
        suspended = false
        awaitsPlaybackConfirmation = waitingForConfirmation
        showsControls = false
        navigationDirection = 1
        lastViewedAssetID = nil
        lastShownVisit = nil
        activeTransition = nil
        preparation = EarthSlideshowPreparationProgress(stage: .reading)
        phase = .preparing
        fill()
    }

    private var canPrepare: Bool {
        !suspended && (!isPaused || filmstripTargetCount != nil || pendingJourneyIndex != nil || (isBuffering && currentItem == nil))
    }

    /// Loading and selecting one page is one cancellable operation. The
    /// traversal commits its cursor only after the selected batch is accepted.
    private func fill() {
        guard preparationTask == nil, canPrepare,
              phase != .cancelled, phase != .completed, phase != .ending,
              phase != .idle else { return }
        if case .failed = phase { return }
        let token = generation
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == token { preparationTask = nil }
            }
            do {
                if snapshot == nil {
                    guard let makeSnapshot else { throw EarthSlideshowPlanError.unavailable }
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--slideshow-preparation-delay-fixture") {
                        try await Task.sleep(for: .seconds(4))
                    }
#endif
                    let frozen = try await makeSnapshot()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    let members = frozen.visitIDs()
                    places = (frozen.places ?? places).filter { members.contains($0.id) }
                    let sequence = SlideshowPageSequence(places: places, journeys: frozen.journeys)
                    visitsByID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    availableJourneys = sequence.segments
                    pages = sequence
                    snapshot = frozen
                    self.makeSnapshot = nil
                }
                guard let snapshot else { throw EarthSlideshowPlanError.unavailable }
                while generation == token, canPrepare, isBuffering || filmstrip.count - itemIndex <= 4 || filmstrip.count < (filmstripTargetCount ?? 0),
                      let request = pages.begin() {
                    do {
                        let page = try await snapshot.page(request, limit: filmstrip.isEmpty ? 3 : 8)
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        let candidates = page.records.filter { record in
                            !self.excluded.contains(record.id) && (self.retryingMedia ? self.unavailable[record.id] != nil : !self.selected.contains(record.id))
                        }
                        let records: [PhotoAssetRecord]
                        var selection: PhotoSimilarityAnalyzer.Selection?
                        if retryingMedia {
                            records = candidates
                        } else {
                            let eligibleCandidates = candidates.filter(photoSpacing.allows)
                            if filmstrip.isEmpty, lastShownVisit == nil, !eligibleCandidates.isEmpty {
                                openingCandidateIDs = Set(eligibleCandidates.map(\.id))
                                beginOpeningWhenReady(at: request.visit)
                            }
                            selection = try await analyze(eligibleCandidates, token: token)
                            records = selection?.records ?? []
                        }
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        let eligible = records.filter { record in
                            guard !self.excluded.contains(record.id), !self.viewed.contains(record.id) else { return false }
                            // Media retries only revisit items already admitted to this show.
                            return self.retryingMedia || self.photoSpacing.admit(record)
                        }
                        let firstAdded = filmstrip.count
                        do { try append(eligible, visit: request.visit) }
                        catch { fail(error); return }
                        selection?.commit(keeping: eligible)
                        pages.finish(request, next: page.next)
                        if pendingJourneyIndex != nil, filmstrip.indices.contains(firstAdded) {
                            pendingJourneyIndex = nil
                            showItem(at: firstAdded, manual: true)
                        } else if pendingJourneyIndex == nil, isBuffering, nextUnseenIndex != nil {
                            isBuffering = false
                            advance(forward: true)
                        }
                    } catch is CancellationError { return }
                    catch { if generation == token { pages.fail(request) } }
                    await Task.yield()
                }
                guard generation == token, canPrepare else { return }
                if filmstrip.isEmpty || isBuffering {
                    handleEndOfSupply()
                }
            } catch is CancellationError { }
            catch {
                if generation == token { fail(error) }
            }
        }
    }

    private func analyze(_ candidates: [PhotoAssetRecord], token: UUID) async throws -> PhotoSimilarityAnalyzer.Selection {
        preparation.stage = .analyzing
        preparation.candidateCount += candidates.count
        return try await analyzer.selectPage(candidates, longEdge: configuration.similarityLongEdge,
                                             prepareOpening: filmstrip.isEmpty) { _ in
            if self.generation == token { self.preparation.analyzedCount += 1 }
        }
    }

    private func append(_ records: [PhotoAssetRecord], visit: TravelPlace) throws {
        guard !records.isEmpty else { return }
        let needsCurrentItem = currentItem == nil
        let archive = try playlistRecords ?? SlideshowSnapshot()
        try archive.append(records)
        playlistRecords = archive
        for record in records {
            selected.insert(record.id)
            unavailable.removeValue(forKey: record.id)
            filmstrip.append(.init(id: record.id, placeID: visit.id, date: record.creationDate,
                                  mediaKind: record.mediaKind,
                                  ratio: record.pixelHeight > 0 ? CGFloat(record.pixelWidth) / CGFloat(record.pixelHeight) : 0))
        }
        try refreshPlaybackItems()
        warmNextPage()
        preparation.readyCount += records.count
        preparation.stage = .ready
        if needsCurrentItem, pendingJourneyIndex == nil {
            preparePresentationPage()
            openingCandidateIDs.removeAll()
            isBuffering = false
            if lastShownVisit == nil, phase == .preparing || phase == .earthIntro {
                beginOpeningWhenReady(at: visit)
            } else if let lastShownVisit {
                transition(from: .init(visit: lastShownVisit), manual: isPaused)
            } else {
                presentCurrentItem()
            }
        }
    }

    func openedMusicPicker() {
        guard !didReportMusicPicker, requestTime != nil, analytics.consentRevision == requestConsent else { return }
        didReportMusicPicker = true
        analytics.capture(.musicPickerOpened, context: .init(library: analyticsLibrary))
    }

    func beginPlayback(music: JourneyEventContext.Music = .none) {
        guard awaitsPlaybackConfirmation else { return }
        soundtrack = music
        awaitsPlaybackConfirmation = false
        beginOpeningWhenReady()
    }

    private func beginOpeningWhenReady(at candidate: TravelPlace? = nil) {
        guard phase == .preparing || phase == .earthIntro,
              let visit = currentChapter?.visit ?? candidate ?? openingVisit else { return }
        let needsCameraMove = phase == .preparing || openingVisit?.id != visit.id
        openingVisit = visit
        guard !awaitsPlaybackConfirmation, !isPaused else { return }
        if currentItem != nil, !didReportPlaybackStart {
            if requestTime != nil, requestConsent == analytics.consentRevision {
                analytics.capture(.slideshowStarted, value: scope.kind.rawValue,
                                  context: .init(library: analyticsLibrary, music: soundtrack))
            }
            didReportPlaybackStart = true
        }
        if needsCameraMove {
            phase = .earthIntro
            cameraAction(.chapter(visit, isOpening: true), reduceMotion)
            schedule(.finishIntro, after: reduceMotion ? 0.8 : configuration.earthIntroDuration)
        } else {
            finishOpeningIfReady()
        }
    }

    private func finishOpeningIfReady() {
        guard phase == .earthIntro, scheduledAction == nil, currentItem != nil, !isPaused else { return }
        presentCurrentItem()
    }

    private func handleEndOfSupply() {
        switch pages.state {
        case .ready, .reading: return
        case .retryable: fail(EarthSlideshowPlanError.unavailable)
        case .exhausted:
            isBuffering = false
            if !unavailable.isEmpty {
                fail(EarthSlideshowPlanError.unavailable)
            } else if let visit = lastShownVisit ?? currentChapter?.visit {
                if pendingJourneyIndex != nil {
                    isPaused = false
                    pendingJourneyIndex = nil
                }
                beginEnding(with: visit)
            } else {
                fail(EarthSlideshowPlanError.empty)
            }
        }
    }

    private func fail(_ error: Error) {
        cancelTimer()
        isBuffering = false
        phase = .failed((error as? LocalizedError)?.errorDescription ?? EarthSlideshowPlanError.unavailable.localizedDescription)
        showsControls = true
    }

    func retry() {
        guard snapshot != nil else { prepareFromStart(); return }
        invalidateProducer()
        if pages.state == .retryable { pages.retry() }
        else if !unavailable.isEmpty {
            retryingMedia = true
            resetPages()
            if let target = pendingJourneyIndex { pages.start(atSegment: target) }
        } else { prepareFromStart(); return }
        showsControls = false
        if pendingJourneyIndex == nil { isPaused = false }
        isBuffering = true
        phase = currentItem == nil ? .preparing : .presentingItem
        fill()
    }

    func restart() { start() }
    func showControls() { showsControls = true }
    func hideControls() { showsControls = false }
    func toggleControls() { showsControls.toggle() }

    func togglePause() {
        switch phase {
        case .idle, .preparing, .completed, .failed, .cancelled: return
        default: setPaused(!isPaused)
        }
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            if let deadline = scheduledDeadline { scheduledRemaining = max(0, deadline.timeIntervalSinceNow) }
            timerTask?.cancel()
            timerTask = nil
            scheduledDeadline = nil
            invalidateProducer()
            if pendingJourneyIndex != nil || filmstripTargetCount != nil { fill() }
        } else {
            if let action = scheduledAction {
                // Backgrounding releases the visible frames. Resume a paused dwell
                // only once that page is visible again.
                if action != .advanceItem || pageDidAppear {
                    schedule(action, after: max(0.05, scheduledRemaining))
                }
            }
            else if phase == .preparing || phase == .earthIntro { beginOpeningWhenReady() }
            else if !isBuffering { scheduleDwellIfReady() }
            fill()
        }
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        if phase == .transitioningItem { cancelTimer() }
        canvasPage = nil
        activeTransition = nil
        resetPresentationPage()
        guard !isPaused else {
            invalidateProducer()
            return
        }
        resumesAfterSuspension = true
        setPaused(true)
    }

    func resumeAfterSuspension() {
        guard suspended else { return }
        suspended = false
        preparePresentationPage()
        guard resumesAfterSuspension else {
            fill()
            return
        }
        resumesAfterSuspension = false
        setPaused(false)
    }

    func markCurrentItemReady(_ assetID: String, image: UIImage? = nil) {
        guard !suspended, !preparingCollage, collageTiles.isEmpty, let item = currentItem, item.id == assetID, let chapter = currentChapter else { return }
        switch phase {
        case .presentingItem, .transitioningItem:
            let tiles = image.map { [SlideshowCollageFrames.Tile(id: assetID, ratio: filmstrip[itemIndex].ratio, image: $0)] } ?? []
            commitCanvas(tiles: tiles)
            pageDidAppear = true
            if !inspectingPhoto, displayedPage[assetID] == nil { displayedPage[assetID] = assetID }
            lastViewedAssetID = assetID
            viewed.insert(assetID)
            visitedPlaces.insert(chapter.id)
#if DEBUG
            observation?.displayed(item.record, visitedPlaces: visitedPlaces.count, retainedItems: filmstrip.count)
#endif
            lastShownVisit = chapter.visit
        default: return
        }
        finishDisplayingPage()
    }

    private func commitCanvas(tiles: [SlideshowCollageFrames.Tile]) {
        guard let item = currentItem, let chapter = currentChapter else { return }
        let members = filmstrip[itemIndex...].prefix(max(1, tiles.count))
        guard let last = members.last else { return }
        let descriptor = SlideshowPageDescriptor(ids: members.map(\.id), ratios: members.map(\.ratio),
            visitID: chapter.visit.id, firstDate: item.record.creationDate, lastDate: last.date,
            favorite: item.record.isFavorite, dynamic: item.record.mediaKind.isPlayable)
        if canvasPage?.descriptor == descriptor {
            if let image = tiles.first?.image, tiles.count == 1, image !== canvasPage?.tiles.first?.image {
                canvasPage = .init(descriptor: descriptor, record: item.record, visit: chapter.visit, tiles: tiles)
            }
            // Selecting the same photograph again while another page is pending.
            if phase == .transitioningItem, activeTransition == nil { presentCurrentItem() }
            return
        }
#if DEBUG
        observedTransition = nil
#endif
        let previous = canvasPage?.descriptor
        canvasPage = .init(descriptor: descriptor, record: item.record, visit: chapter.visit, tiles: tiles)
        if phase == .transitioningItem {
            if let previous {
                let effect = transitionDirector.transition(from: previous, to: descriptor, manual: manualTransition, reduced: reduceMotion)
                activeTransition = effect
#if DEBUG
                observedTransition = effect
#endif
                schedule(.finishItemTransition, after: effect.duration)
            } else {
                presentCurrentItem()
            }
        }
    }

    func updateReduceMotion(_ enabled: Bool) {
        guard enabled != reduceMotion else { return }
        reduceMotion = enabled
        if enabled, phase == .transitioningItem, activeTransition != nil {
            cancelTimer()
            presentCurrentItem()
        }
    }

    func markCurrentItemUnavailable(_ assetID: String, revision: Int) {
        guard !suspended, !isPaused, pendingJourneyIndex == nil,
              currentItem?.id == assetID, !pageDidAppear, !preparingCollage, collageTiles.isEmpty,
              revision == mediaRetryRevision else { return }
        if retriedAssetID != assetID {
            // Give a temporary failure a fresh PhotoKit request here. Rewinding
            // from a later journey just to retry would break the itinerary.
            retriedAssetID = assetID
            mediaRetryRevision += 1
            return
        }
        retriedAssetID = nil
        unavailable[assetID] = currentJourneyIndex
        removeEntries([assetID])
    }

    private func finishDisplayingPage() {
        warmNextPage()
        guard !isBuffering, !isPaused else { return }
        if scheduledAction == nil {
            scheduleDwellIfReady()
        } else if case .advanceItem = scheduledAction, timerTask == nil {
            schedule(.advanceItem, after: max(0.05, scheduledRemaining))
        }
    }

    private func scheduleDwellIfReady(dynamicPlaybackStarted: Bool = false) {
        if phase == .presentingItem, !isPaused, pageDidAppear, let item = currentItem {
            schedule(.advanceItem, after: dwellDuration(for: item.record, dynamicPlaybackStarted: dynamicPlaybackStarted))
        }
    }

    func synchronizeDwellWithDynamicPlayback(_ assetID: String) {
        guard let item = currentItem, item.id == assetID, item.record.mediaKind.isPlayable,
              !isBuffering else { return }
        scheduleDwellIfReady(dynamicPlaybackStarted: true)
    }

    func dynamicPlaybackDidFinish(_ assetID: String) {
        guard let item = currentItem, item.id == assetID, item.record.mediaKind.isPlayable,
              phase == .presentingItem, !isPaused, !isBuffering, viewed.contains(assetID) else { return }
        schedule(.advanceItem, after: configuration.dynamicEndHold)
    }

    func invalidateEditedPhotos(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if canvasPage.map({ !ids.isDisjoint(with: $0.descriptor.ids) }) == true { canvasPage = nil }
        visibilityRevision += 1
        editedAssets.formUnion(ids)
        warmedIDs = []
        collageLookahead.cancel()
        let active = localTiles.contains { ids.contains($0.id) }
        if active || preparingCollage {
            resetPresentationPage()
            if case .advanceItem = scheduledAction { cancelTimer() }
            preparePresentationPage()
            mediaRetryRevision += 1
        }
        warmNextPage()
    }

    func removeAssets(_ ids: Set<String>) {
        if canvasPage.map({ !ids.isDisjoint(with: $0.descriptor.ids) }) == true { canvasPage = nil }
        excluded.formUnion(ids)
        if !openingCandidateIDs.isEmpty {
            openingCandidateIDs.subtract(ids)
            if openingCandidateIDs.isEmpty {
                openingVisit = nil
                if phase == .earthIntro {
                    cancelTimer()
                    phase = .preparing
                }
            }
        }
        for id in ids { unavailable.removeValue(forKey: id) }
        if let lastViewedAssetID, ids.contains(lastViewedAssetID) { self.lastViewedAssetID = nil }
        removeEntries(ids)
    }

    private func removeEntries(_ ids: Set<String>) {
        guard !ids.isEmpty, !filmstrip.isEmpty else { return }
        let affected = filmstrip.contains { ids.contains($0.id) }
        guard affected else { return }
        visibilityRevision += 1
        collageLookahead.cancel()
        warmedIDs = []
        let removedCurrent = currentItem.map { ids.contains($0.id) } == true
            || collageTiles.contains { ids.contains($0.id) } || preparingCollage
        displayedPage = displayedPage.filter { !ids.contains($0.key) && !ids.contains($0.value) }
        if removedCurrent { resetPresentationPage() }
        let oldIndex = itemIndex
        let priorChapter = currentChapter
        let before = filmstrip.prefix(oldIndex).filter { ids.contains($0.id) }.count
        filmstrip.removeAll { ids.contains($0.id) }
        itemIndex = max(0, oldIndex - before)
        do { try refreshPlaybackItems() } catch { fail(error); return }
        guard removedCurrent else { warmNextPage(); fill(); return }
        inspectingPhoto = false
        preparePresentationPage()
        if (phase == .preparing || phase == .earthIntro), filmstrip.indices.contains(itemIndex) {
            beginOpeningWhenReady()
            fill()
            return
        }
        cancelTimer()
        if filmstrip.indices.contains(itemIndex) { transition(from: priorChapter, manual: isPaused) }
        else {
            // The playhead waits just after the remaining history until the next page arrives.
            openingVisit = nil
            isBuffering = true
            phase = .preparing
            fill()
        }
    }

    func move(forward: Bool) {
        switch phase {
        case .earthIntro, .chapterTitle, .presentingItem, .transitioningItem, .earthChapterBridge:
            advance(forward: forward, manual: true)
        default: break
        }
    }

    func selectPausedItem(_ assetID: String) {
        guard isPaused, pendingJourneyIndex == nil,
              let index = filmstrip.firstIndex(where: { $0.id == assetID }) else { return }
        followsFilmstripOrder = true
        if index == itemIndex, pageCount == 1, !preparingCollage,
           phase == .presentingItem || phase == .transitioningItem {
            inspectingPhoto = true
            return
        }
        cancelTimer()
        navigationDirection = index >= itemIndex ? 1 : -1
        showItem(at: index, manual: true, single: true)
    }

    func skipToNextJourney() {
        guard canSkipToNextJourney, let currentJourneyIndex else { return }
        let target = currentJourneyIndex + 1
        if preparingCollage { resetPresentationPage() }
        collageLookahead.cancel()
        warmedIDs = []
        cancelTimer()
        navigationDirection = 1
        unavailable = unavailable.filter { $0.value >= target }
        let following = min(filmstrip.endIndex, itemIndex + pageCount)
        let next = filmstrip.indices.dropFirst(following).first { index in
            guard let segment = pages.segmentIndex(forVisitID: filmstrip[index].placeID) else { return false }
            return segment >= target
        }
        // A previous-photo press after the jump returns to the photo the
        // viewer left, even when several skipped frames were prefetched.
        filmstrip.removeSubrange(following..<(next ?? filmstrip.endIndex))
        if next != nil {
            showItem(at: following, manual: true)
        } else {
            do { try refreshPlaybackItems() } catch { fail(error); return }
            invalidateProducer()
            pages.start(atSegment: target)
            pendingJourneyIndex = target
            retryingMedia = false
            isBuffering = true
            phase = .presentingItem
        }
        fill()
    }

    private var nextUnseenIndex: Int? {
        filmstrip.indices.dropFirst(itemIndex + pageCount).first { followsFilmstripOrder || !viewed.contains(filmstrip[$0].id) }
    }

    private func advance(forward: Bool, manual: Bool = false) {
        guard currentItem != nil, pendingJourneyIndex == nil else { return }
        var next = forward ? (manual ? itemIndex + pageCount : nextUnseenIndex ?? filmstrip.count) : itemIndex - 1
        if !forward, next >= 0, let owner = displayedPage[filmstrip[next].id] {
            while next > 0, displayedPage[filmstrip[next - 1].id] == owner { next -= 1 }
        }
        guard next >= 0 else { return }
        cancelTimer()
        navigationDirection = forward ? 1 : -1
        guard filmstrip.indices.contains(next) else {
            isBuffering = true
            switch pages.state {
            case .ready, .reading: phase = .presentingItem; fill()
            case .exhausted, .retryable: handleEndOfSupply()
            }
            return
        }
        showItem(at: next, manual: manual)
        fill()
    }

    private func showItem(at next: Int, manual: Bool, single: Bool = false) {
        let priorChapter = currentChapter
        retriedAssetID = nil
        isBuffering = false
        activeTransition = nil
        inspectingPhoto = single
        resetPresentationPage()
        itemIndex = next
        do { try refreshPlaybackItems() } catch { fail(error); return }
        preparePresentationPage()
        transition(from: priorChapter, manual: manual)
    }

    private func transition(from previous: EarthSlideshowChapter?, manual: Bool) {
        guard let chapter = currentChapter, currentItem != nil else { return }
        manualTransition = manual
        activeTransition = nil
        if manual && isPaused {
            presentCurrentItem()
        } else if previous?.id != chapter.id && scope.kind != .city {
            canvasPage = nil
            cameraAction(.chapter(chapter.visit, isOpening: false), reduceMotion)
            phase = .earthChapterBridge
            schedule(.finishChapterBridge, after: reduceMotion ? 0.7 : configuration.earthBridgeDuration)
        } else if previous.flatMap({ pages.segmentIndex(forVisitID: $0.visit.id) }) != currentJourneyIndex {
            canvasPage = nil
            phase = .chapterTitle
            schedule(.finishChapterTitle, after: configuration.chapterTitleDuration)
        } else {
            // Hold the displayed page until the incoming single or entire collage is ready.
            phase = .transitioningItem
        }
    }

    private func presentCurrentItem() {
        if activeTransition?.kind == .stagger, let ids = canvasPage?.descriptor.ids {
            markTilesVisible(ids, count: ids.count)
        }
        activeTransition = nil
        phase = .presentingItem
        warmNextPage()
        scheduleDwellIfReady()
    }

    private func finishScheduledAction(_ action: ScheduledAction) {
        scheduledAction = nil
        scheduledDeadline = nil
        scheduledRemaining = 0
        switch action {
        case .finishIntro:
            finishOpeningIfReady()
        case .finishChapterBridge:
            canvasPage = nil
            phase = .chapterTitle
            schedule(.finishChapterTitle, after: configuration.chapterTitleDuration)
        case .finishChapterTitle, .finishItemTransition: presentCurrentItem()
        case .advanceItem: advance(forward: true)
        case .finishEnding:
            endReport("completed")
            phase = .completed
            showsControls = true
        }
    }

    private func endReport(_ result: String) {
        guard let start = requestTime else { return }
        requestTime = nil
        guard requestConsent == analytics.consentRevision else { return }
        analytics.capture(.slideshowFinished, value: result,
                          context: .init(library: analyticsLibrary, scope: scope.kind, music: soundtrack,
                                         elapsed: .init(start.duration(to: .now))))
    }

    func cancel() {
        if case .failed = phase { endReport("failed") }
        else { endReport(didReportPlaybackStart ? "closed_after_start" : "closed_before_start") }
        invalidateProducer()
        cancelTimer()
        snapshot = nil
        makeSnapshot = nil
        pendingJourneyIndex = nil
        resetPresentationPage()
        canvasPage = nil
        activeTransition = nil
        transitionDirector = .init()
        displayedPage.removeAll()
        editedAssets.removeAll()
        inspectingPhoto = false
        followsFilmstripOrder = false
        filmstrip = []
        playlistRecords = nil
        currentItem = nil
        nextItemForPrefetch = nil
        filmstripTargetCount = nil
        analyzer.reset()
        photoSpacing = SlideshowPhotoSpacing()
        isBuffering = false
        awaitsPlaybackConfirmation = false
        phase = .cancelled
    }

    private func invalidateProducer() {
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        pages.interrupt()
    }

    private func beginEnding(with visit: TravelPlace) {
        activeTransition = nil
        canvasPage = nil
        cameraAction(.ending(visit), reduceMotion)
        phase = .ending
        schedule(.finishEnding, after: reduceMotion ? 0.8 : configuration.earthEndingDuration)
    }

    private func dwellDuration(for record: PhotoAssetRecord, dynamicPlaybackStarted: Bool) -> TimeInterval {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-transition-fixture") { return 1.8 }
        if ProcessInfo.processInfo.arguments.contains("--slideshow-long-dwell-fixture") {
            return 30
        }
#endif
        switch record.mediaKind {
        case .photo where pageCount == 3: return 6.5
        case .photo where pageCount == 2: return 5
        case .photo: return configuration.stillDuration
        case .livePhoto: return configuration.livePhotoDuration
        case .video:
            let duration = record.duration > 0
                ? min(record.duration, configuration.maximumVideoDuration)
                : configuration.maximumVideoDuration
            return dynamicPlaybackStarted ? duration : min(duration, configuration.stillDuration)
        }
    }

    private func schedule(_ action: ScheduledAction, after duration: TimeInterval) {
        timerTask?.cancel()
        scheduledAction = action
        scheduledRemaining = max(0.01, duration)
        guard !isPaused else { return }
        let session = generation
        let delay = scheduledRemaining
        scheduledDeadline = Date().addingTimeInterval(delay)
        timerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, generation == session,
                  scheduledAction != nil else { return }
            finishScheduledAction(action)
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        scheduledAction = nil
        scheduledDeadline = nil
        scheduledRemaining = 0
    }

    isolated deinit {
        preparationTask?.cancel()
        timerTask?.cancel()
    }
}

#if DEBUG
/// Opt-in, local playback evidence for a development build. The key only lives for this show.
private final class SlideshowObservation {
    private let key = SymmetricKey(size: .bits256)
    private let file: FileHandle
    private var previous: String?
    private var sequence = 0
    private var years = Set<Int>()
    private let calendar = Calendar(identifier: .gregorian)

    init() throws {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("slideshow-observation.jsonl")
        try Data().write(to: url, options: .atomic)
        file = try FileHandle(forWritingTo: url)
    }

    func displayed(_ record: PhotoAssetRecord, visitedPlaces: Int, retainedItems: Int) {
        let assetID = record.id
        guard previous != assetID else { return }
        previous = assetID
        sequence += 1
        let digest = HMAC<SHA256>.authenticationCode(for: Data(assetID.utf8), using: key)
        let id = Data(digest).base64EncodedString()
        years.insert(calendar.component(.year, from: record.creationDate))
        var row: [String: Any] = ["sequence": sequence, "time": Date().timeIntervalSince1970, "digest": id,
                                  "places": visitedPlaces, "years": years.count, "kind": record.mediaKind.rawValue,
                                  "retainedItems": retainedItems]
        if sequence == 1 || sequence.isMultiple(of: 12) {
            var info = task_vm_info_data_t()
            let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.stride
            var count = mach_msg_type_number_t(capacity)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if status == KERN_SUCCESS { row["footprintBytes"] = info.phys_footprint }
        }
        if var data = try? JSONSerialization.data(withJSONObject: row) {
            data.append(0x0a)
            try? file.write(contentsOf: data)
        }
    }

    deinit { try? file.close() }
}
#endif
