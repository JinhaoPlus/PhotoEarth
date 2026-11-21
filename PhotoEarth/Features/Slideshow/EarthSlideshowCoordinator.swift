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
    private var openingCandidates: (@MainActor () -> [PhotoAssetRecord])?
    private var makeSnapshot: SnapshotLoader?
    private var places: [TravelPlace]
    private var pages = SlideshowPageSequence(places: [])
    private let cameraAction: CameraAction
    private let analyzer: PhotoSimilarityAnalyzer
    private let reduceMotion: Bool
    private var selected = Set<String>()
    private var viewed = Set<String>()
    private var visitedPlaces = Set<String>()
    private var lastShownVisit: TravelPlace?
    private var unavailable = Set<String>()
    private var retryingMedia = false
    private var attemptedAutomaticMediaRetry = false
    private var excluded = Set<String>()
    private var preparationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var generation = UUID()
    private var scheduledAction: ScheduledAction?
    private var scheduledDeadline: Date?
    private var scheduledRemaining: TimeInterval = 0
    private var suspended = false
    private var resumesAfterSuspension = false

    private enum ScheduledAction {
        case finishIntro, finishChapterTitle, finishItemTransition, advanceItem, finishChapterBridge, finishEnding
    }

    init(scope: EarthSlideshowScope, places: [TravelPlace],
         configuration: EarthSlideshowConfiguration = .standard, reduceMotion: Bool,
         analyzer: PhotoSimilarityAnalyzer? = nil, openingCandidates: (@MainActor () -> [PhotoAssetRecord])? = nil,
         makeSnapshot: @escaping SnapshotLoader,
         cameraAction: @escaping CameraAction) {
        self.scope = scope
        self.places = places
        self.configuration = configuration
        self.reduceMotion = reduceMotion
        self.analyzer = analyzer ?? PhotoSimilarityAnalyzer()
        self.makeSnapshot = makeSnapshot
        self.openingCandidates = openingCandidates
        self.cameraAction = cameraAction
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
        pages = SlideshowPageSequence(places: places)
        retryingMedia = false
        attemptedAutomaticMediaRetry = false
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

    /// Loading and selecting one page is one cancellable operation. The
    /// traversal commits its cursor only after the selected batch is accepted.
    private func fill() {
        guard preparationTask == nil, !isPaused,
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
                    async let loading = makeSnapshot()
                    if entries.isEmpty, let openingCandidates {
                        let candidates = openingCandidates().filter { !self.excluded.contains($0.id) }
                        if let first = candidates.first, let visit = places.first(where: { $0.id == first.placeID }) {
                            let selection = try await analyze(Array(candidates.filter { $0.placeID == visit.id }.prefix(3)), token: token)
                            try Task.checkCancellation()
                            guard generation == token else { return }
                            let allowed = Set(openingCandidates().map(\.id))
                            let eligible = selection.records.filter { allowed.contains($0.id) && !self.excluded.contains($0.id) }
                            if !eligible.isEmpty {
                                selection.commit()
                                append(eligible, visit: visit)
                            }
                        }
                    }
                    let frozen = try await loading
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    let members = frozen.visitIDs()
                    places = (frozen.places ?? places).filter { members.contains($0.id) }
                    pages = SlideshowPageSequence(places: places)
                    snapshot = frozen
                    self.makeSnapshot = nil
                    self.openingCandidates = nil
                }
                guard let snapshot else { throw EarthSlideshowPlanError.unavailable }
                while generation == token, !isPaused, isBuffering || entries.count - itemIndex <= 4,
                      let request = pages.begin() {
                    do {
                        let page = try await snapshot.page(request, limit: entries.isEmpty ? 3 : 8)
                        let candidates = page.records.filter { record in
                            !self.excluded.contains(record.id) && (self.retryingMedia ? self.unavailable.contains(record.id) : !self.selected.contains(record.id))
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
                        append(eligible, visit: request.visit)
                        if isBuffering, nextUnseenIndex != nil {
                            isBuffering = false
                            advance(forward: true)
                        }
                    } catch is CancellationError { return }
                    catch { pages.fail(request) }
                    await Task.yield()
                }
                guard generation == token, !isPaused else { return }
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
        let preceding = entries.last.flatMap { $0.visit.id == visit.id ? $0.item.record : nil }
        let context = [preceding].compactMap { $0 } + records
        let transitions = SlideshowTransitionDirector().transitions(for: context).suffix(records.count)
        for (record, transition) in zip(records, transitions) {
            selected.insert(record.id)
            unavailable.remove(record.id)
            entries.append(Entry(visit: visit, item: .init(record: record, transition: transition)))
        }
        preparation.readyCount += records.count
        preparation.stage = .ready
        if startEmpty {
            itemIndex = 0
            isBuffering = false
            if phase == .preparing {
                beginOpeningWhenReady()
            } else { presentCurrentItem() }
        }
    }

    func beginPlayback() {
        guard awaitsPlaybackConfirmation else { return }
        awaitsPlaybackConfirmation = false
        beginOpeningWhenReady()
    }

    private func beginOpeningWhenReady() {
        guard phase == .preparing, !awaitsPlaybackConfirmation, !isPaused,
              let visit = entries.first?.visit else { return }
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
                if attemptedAutomaticMediaRetry {
                    fail(EarthSlideshowPlanError.unavailable)
                } else {
                    attemptedAutomaticMediaRetry = true
                    retry()
                }
            }
            else if let visit = lastShownVisit ?? currentChapter?.visit { beginEnding(with: visit) }
            else { fail(EarthSlideshowPlanError.empty) }
        }
    }

    private func fail(_ error: Error) {
        cancelTimer()
        isBuffering = false
        phase = .failed((error as? LocalizedError)?.errorDescription ?? EarthSlideshowPlanError.unavailable.localizedDescription)
        showsControls = true
    }

    func retry() {
        guard snapshot != nil else { start(); return }
        invalidateProducer()
        if pages.state == .retryable { pages.retry() }
        else if !unavailable.isEmpty {
            retryingMedia = true
            pages = SlideshowPageSequence(places: places)
        } else { start(); return }
        showsControls = false
        isPaused = false
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
        guard !isPaused else { return }
        resumesAfterSuspension = true
        setPaused(true)
    }

    func resumeAfterSuspension() {
        suspended = false
        guard resumesAfterSuspension else { return }
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

    func markCurrentItemUnavailable(_ assetID: String) {
        guard currentItem?.id == assetID, !viewed.contains(assetID), !isPaused else { return }
        unavailable.insert(assetID)
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
        unavailable.subtract(ids)
        if let lastViewedAssetID, ids.contains(lastViewedAssetID) { self.lastViewedAssetID = nil }
        removeEntries(ids)
    }

    private func removeEntries(_ ids: Set<String>) {
        guard !ids.isEmpty, let current = currentItem else { return }
        let oldIndex = itemIndex
        let oldPlace = currentChapter?.id
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
        if entries.indices.contains(itemIndex) { transition(from: oldPlace, manual: false) }
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
        guard isPaused, selectionRecords.contains(where: { $0.id == assetID }),
              let index = entries.firstIndex(where: { $0.item.id == assetID }),
              index != itemIndex || (phase != .presentingItem && phase != .transitioningItem) else { return }
        cancelTimer()
        navigationDirection = index >= itemIndex ? 1 : -1
        showItem(at: index, manual: true)
    }

    private var nextUnseenIndex: Int? {
        entries.indices.dropFirst(itemIndex + 1).first { !viewed.contains(entries[$0].item.id) }
    }

    private func advance(forward: Bool, manual: Bool = false) {
        guard currentItem != nil else { return }
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
        let oldPlace = currentChapter?.id
        isBuffering = false
        itemIndex = next
        if itemIndex > 32 {
            let drop = itemIndex - 32
            entries.removeFirst(drop)
            itemIndex -= drop
        }
        transition(from: oldPlace, manual: manual)
    }

    private func transition(from oldPlace: String?, manual: Bool) {
        guard let chapter = currentChapter, let item = currentItem else { return }
        presentationOrder += 1
        if manual && isPaused {
            presentCurrentItem()
        } else if oldPlace != chapter.id {
            cameraAction(.chapter(chapter.visit, isOpening: false), reduceMotion)
            phase = .earthChapterBridge
            schedule(.finishChapterBridge, after: reduceMotion ? 0.7 : configuration.earthBridgeDuration)
        } else if reduceMotion {
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
            phase = .completed
            showsControls = true
        }
    }

    func cancel() {
        invalidateProducer()
        cancelTimer()
        snapshot = nil
        makeSnapshot = nil
        openingCandidates = nil
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
