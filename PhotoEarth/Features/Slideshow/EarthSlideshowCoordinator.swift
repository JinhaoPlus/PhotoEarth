import Combine
#if DEBUG
import CryptoKit
import Darwin
#endif
import Foundation

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
    @Published private(set) var activeTransitionDuration: TimeInterval?
    @Published private(set) var mediaRetryRevision = 0
    private(set) var presentationOrder = 0

    private struct Entry {
        let visit: TravelPlace
        let item: EarthSlideshowItem
    }
    @Published private var entries: [Entry] = []
    @Published private(set) var itemIndex = 0
#if DEBUG
    private var observation: SlideshowObservation?
#endif
    private var snapshot: (any SlideshowPageReading)?
    private var pendingJourneyIndex: Int?
    private var makeSnapshot: SnapshotLoader?
    private var places: [TravelPlace]
    private var pages = SlideshowPageSequence(places: [])
    private let cameraAction: CameraAction
    private let analyzer: PhotoSimilarityAnalyzer
    private let reduceMotion: Bool
    private var selected = Set<String>()
    private var viewed = Set<String>()
    private var visitedPlaces = Set<EarthSlideshowChapter.ID>()
    private var lastShownVisit: TravelPlace?
    private var unavailable: [String: Int] = [:]
    private var retryingMedia = false
    private var retriedAssetID: String?
    private var excluded = Set<String>()
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

    init(scope: EarthSlideshowScope, places: [TravelPlace],
         analyticsLibrary: JourneyEventContext.Library? = nil, analytics: ProductAnalytics? = nil,
         configuration: EarthSlideshowConfiguration = .standard, reduceMotion: Bool,
         analyzer: PhotoSimilarityAnalyzer? = nil,
         makeSnapshot: @escaping SnapshotLoader,
         cameraAction: @escaping CameraAction) {
        self.analyticsLibrary = analyticsLibrary
        self.analytics = analytics ?? .shared
        self.scope = scope
        self.places = places
        self.configuration = configuration
        self.reduceMotion = reduceMotion
        self.analyzer = analyzer ?? PhotoSimilarityAnalyzer()
        self.makeSnapshot = makeSnapshot
        self.cameraAction = cameraAction
    }

    private var currentJourneyIndex: Int? {
        currentChapter.flatMap { pages.segmentIndex(forVisitID: $0.visit.id) }
    }
    var currentJourney: EarthSlideshowSegment? { currentJourneyIndex.map { pages.segments[$0] } }
    var currentJourneyNumber: Int { currentJourneyIndex.map { $0 + 1 } ?? 0 }
    var journeyCount: Int { pages.segments.count }
    var canSkipToNextJourney: Bool {
        switch phase {
        case .earthIntro, .chapterTitle, .earthChapterBridge, .presentingItem, .transitioningItem:
            return pendingJourneyIndex == nil && currentJourneyNumber > 0 && currentJourneyNumber < journeyCount
        default: return false
        }
    }

    var currentChapter: EarthSlideshowChapter? {
        guard entries.indices.contains(itemIndex) else { return nil }
        return .init(visit: entries[itemIndex].visit)
    }
    var currentItem: EarthSlideshowItem? { entries.indices.contains(itemIndex) ? entries[itemIndex].item : nil }
    var nextItemForPrefetch: EarthSlideshowItem? {
        entries.indices.contains(itemIndex + 1) ? entries[itemIndex + 1].item : nil
    }
    var selectionRecords: [PhotoAssetRecord] {
        guard entries.indices.contains(itemIndex) else { return [] }
        let count = min(9, entries.count)
        let start = min(max(0, itemIndex - count / 2), entries.count - count)
        return entries[start..<(start + count)].map(\.item.record)
    }
    var viewedCount: Int { viewed.count }
    var retainedCount: Int { entries.count }

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
        entries = []
        itemIndex = 0
        selected.removeAll()
        viewed.removeAll()
        visitedPlaces.removeAll()
        unavailable.removeAll()
        analyzer.reset()
        pages = SlideshowPageSequence(places: places, journeys: snapshot?.journeys ?? [])
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
        activeTransitionDuration = nil
        preparation = EarthSlideshowPreparationProgress(stage: .reading)
        phase = .preparing
        fill()
    }

    private var canPrepare: Bool {
        !suspended && (!isPaused || pendingJourneyIndex != nil || (isBuffering && entries.isEmpty))
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
                    pages = SlideshowPageSequence(places: places, journeys: frozen.journeys)
                    snapshot = frozen
                    self.makeSnapshot = nil
                }
                guard let snapshot else { throw EarthSlideshowPlanError.unavailable }
                while generation == token, canPrepare, isBuffering || entries.count - itemIndex <= 4,
                      let request = pages.begin() {
                    do {
                        let page = try await snapshot.page(request, limit: entries.isEmpty ? 3 : 8)
                        let candidates = page.records.filter { record in
                            !self.excluded.contains(record.id) && (self.retryingMedia ? self.unavailable[record.id] != nil : !self.selected.contains(record.id))
                        }
                        let records: [PhotoAssetRecord]
                        var selection: PhotoSimilarityAnalyzer.Selection?
                        if retryingMedia {
                            records = candidates
                        } else {
                            selection = try await analyze(candidates, token: token)
                            records = selection?.records ?? []
                        }
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        let eligible = records.filter { !self.excluded.contains($0.id) && !self.viewed.contains($0.id) }
                        selection?.commit()
                        pages.finish(request, next: page.next)
                        let firstAdded = entries.count
                        append(eligible, visit: request.visit)
                        if pendingJourneyIndex != nil, entries.indices.contains(firstAdded) {
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
                if entries.isEmpty || isBuffering {
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
                                             prepareOpening: entries.isEmpty) { _ in
            if self.generation == token { self.preparation.analyzedCount += 1 }
        }
    }

    private func append(_ records: [PhotoAssetRecord], visit: TravelPlace) {
        guard !records.isEmpty else { return }
        let startEmpty = entries.isEmpty
        let preceding = entries.last?.item.record
        let context = [preceding].compactMap { $0 } + records
        let transitions = SlideshowTransitionDirector().transitions(for: context).suffix(records.count)
        for (record, transition) in zip(records, transitions) {
            selected.insert(record.id)
            unavailable.removeValue(forKey: record.id)
            entries.append(Entry(visit: visit, item: .init(record: record, transition: transition)))
        }
        preparation.readyCount += records.count
        preparation.stage = .ready
        if startEmpty, pendingJourneyIndex == nil {
            itemIndex = 0
            isBuffering = false
            if phase == .preparing, !didReportPlaybackStart {
                beginOpeningWhenReady()
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

    private func beginOpeningWhenReady() {
        guard phase == .preparing, !awaitsPlaybackConfirmation, !isPaused,
              let visit = entries.first?.visit else { return }
        if !didReportPlaybackStart {
            if requestTime != nil, requestConsent == analytics.consentRevision {
                analytics.capture(.slideshowStarted, value: scope.kind.rawValue,
                                  context: .init(library: analyticsLibrary, music: soundtrack))
            }
            didReportPlaybackStart = true
        }
        phase = .earthIntro
        cameraAction(.chapter(visit, isOpening: true), reduceMotion)
        schedule(.finishIntro, after: reduceMotion ? 0.8 : configuration.earthIntroDuration)
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
            pages = SlideshowPageSequence(places: places, journeys: snapshot?.journeys ?? [])
            if let target = pendingJourneyIndex { pages.start(atSegment: target) }
        } else { prepareFromStart(); return }
        showsControls = false
        if pendingJourneyIndex == nil { isPaused = false }
        isBuffering = true
        phase = entries.isEmpty ? .preparing : .presentingItem
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
            if pendingJourneyIndex != nil { fill() }
        } else {
            if let action = scheduledAction { schedule(action, after: max(0.05, scheduledRemaining)) }
            else if phase == .preparing { beginOpeningWhenReady() }
            else if !isBuffering { scheduleDwellIfReady() }
            fill()
        }
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        guard !isPaused else {
            invalidateProducer()
            return
        }
        resumesAfterSuspension = true
        setPaused(true)
    }

    func resumeAfterSuspension() {
        suspended = false
        guard resumesAfterSuspension else {
            fill()
            return
        }
        resumesAfterSuspension = false
        setPaused(false)
    }

    func markCurrentItemReady(_ assetID: String) {
        guard !suspended, let item = currentItem, item.id == assetID, let chapter = currentChapter else { return }
        switch phase {
        case .presentingItem, .transitioningItem:
            lastViewedAssetID = assetID
            viewed.insert(assetID)
            visitedPlaces.insert(chapter.id)
#if DEBUG
            observation?.displayed(item.record, visitedPlaces: visitedPlaces.count, retainedItems: entries.count)
#endif
            lastShownVisit = chapter.visit
        default: return
        }
        if scheduledAction == nil, !isBuffering { scheduleDwellIfReady() }
    }

    func markCurrentItemUnavailable(_ assetID: String, revision: Int) {
        guard !suspended, !isPaused, pendingJourneyIndex == nil,
              currentItem?.id == assetID, !viewed.contains(assetID),
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

    private func scheduleDwellIfReady(dynamicPlaybackStarted: Bool = false) {
        if phase == .presentingItem, !isPaused, let item = currentItem, viewed.contains(item.id) {
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

    func removeAssets(_ ids: Set<String>) {
        excluded.formUnion(ids)
        for id in ids { unavailable.removeValue(forKey: id) }
        if let lastViewedAssetID, ids.contains(lastViewedAssetID) { self.lastViewedAssetID = nil }
        removeEntries(ids)
    }

    private func removeEntries(_ ids: Set<String>) {
        guard !ids.isEmpty, let current = currentItem else { return }
        let oldIndex = itemIndex
        let priorChapter = currentChapter
        let before = entries.prefix(oldIndex).filter { ids.contains($0.item.id) }.count
        entries.removeAll { ids.contains($0.item.id) }
        itemIndex = max(0, oldIndex - before)
        guard ids.contains(current.id) else { fill(); return }
        cancelTimer()
        if phase == .preparing, entries.indices.contains(itemIndex) {
            beginOpeningWhenReady()
            fill()
            return
        }
        if entries.indices.contains(itemIndex) { transition(from: priorChapter, manual: isPaused) }
        else {
            // Discard the historical window when its tail disappears. Returning
            // to a previous memory would replay a frame automatically.
            entries.removeAll()
            itemIndex = 0
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
        guard isPaused, pendingJourneyIndex == nil, selectionRecords.contains(where: { $0.id == assetID }),
              let index = entries.firstIndex(where: { $0.item.id == assetID }),
              index != itemIndex || (phase != .presentingItem && phase != .transitioningItem) else { return }
        cancelTimer()
        navigationDirection = index >= itemIndex ? 1 : -1
        showItem(at: index, manual: true)
    }

    func skipToNextJourney() {
        guard canSkipToNextJourney, let currentJourneyIndex else { return }
        let target = currentJourneyIndex + 1
        cancelTimer()
        navigationDirection = 1
        unavailable = unavailable.filter { $0.value >= target }
        let following = entries.index(after: itemIndex)
        let next = entries.indices.dropFirst(following).first { index in
            guard let segment = pages.segmentIndex(forVisitID: entries[index].visit.id) else { return false }
            return segment >= target
        }
        // A previous-photo press after the jump returns to the photo the
        // viewer left, even when several skipped frames were prefetched.
        entries.removeSubrange(following..<(next ?? entries.endIndex))
        if next != nil {
            showItem(at: following, manual: true)
        } else {
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
        entries.indices.dropFirst(itemIndex + 1).first { !viewed.contains(entries[$0].item.id) }
    }

    private func advance(forward: Bool, manual: Bool = false) {
        guard currentItem != nil, pendingJourneyIndex == nil else { return }
        let next = forward && !manual ? nextUnseenIndex ?? entries.count : itemIndex + (forward ? 1 : -1)
        guard next >= 0 else { return }
        cancelTimer()
        navigationDirection = forward ? 1 : -1
        guard entries.indices.contains(next) else {
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

    private func showItem(at next: Int, manual: Bool) {
        let priorChapter = currentChapter
        retriedAssetID = nil
        isBuffering = false
        itemIndex = next
        if itemIndex > 32 {
            let drop = itemIndex - 32
            entries.removeFirst(drop)
            itemIndex -= drop
        }
        transition(from: priorChapter, manual: manual)
    }

    private func transition(from previous: EarthSlideshowChapter?, manual: Bool) {
        guard let chapter = currentChapter, let item = currentItem else { return }
        presentationOrder += 1
        if manual && isPaused {
            presentCurrentItem()
        } else if previous?.id != chapter.id && scope.kind != .city {
            cameraAction(.chapter(chapter.visit, isOpening: false), reduceMotion)
            phase = .earthChapterBridge
            schedule(.finishChapterBridge, after: reduceMotion ? 0.7 : configuration.earthBridgeDuration)
        } else if previous.flatMap({ pages.segmentIndex(forVisitID: $0.visit.id) }) != currentJourneyIndex {
            phase = .chapterTitle
            schedule(.finishChapterTitle, after: configuration.chapterTitleDuration)
        } else if reduceMotion && item.transition.kind != .dateReveal {
            presentCurrentItem()
        } else {
            let duration = manual ? min(0.48, item.transition.duration) : item.transition.duration
            activeTransitionDuration = duration
            phase = .transitioningItem
            schedule(.finishItemTransition, after: duration)
        }
    }

    private func presentCurrentItem() {
        activeTransitionDuration = nil
        phase = .presentingItem
        scheduleDwellIfReady()
    }

    private func finishScheduledAction(_ action: ScheduledAction) {
        scheduledAction = nil
        scheduledDeadline = nil
        scheduledRemaining = 0
        switch action {
        case .finishIntro, .finishChapterBridge:
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
        entries = []
        analyzer.reset()
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
        activeTransitionDuration = nil
        cameraAction(.ending(visit), reduceMotion)
        phase = .ending
        schedule(.finishEnding, after: reduceMotion ? 0.8 : configuration.earthEndingDuration)
    }

    private func dwellDuration(for record: PhotoAssetRecord, dynamicPlaybackStarted: Bool) -> TimeInterval {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-long-dwell-fixture") {
            return 30
        }
#endif
        switch record.mediaKind {
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
