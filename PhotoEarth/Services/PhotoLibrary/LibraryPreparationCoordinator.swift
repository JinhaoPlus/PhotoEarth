import Foundation

/// Owns the job, not its presentation. Every suspension point has either a
/// durable checkpoint or an input batch that is safe to replay.
@MainActor
final class LibraryPreparationCoordinator {
    private static let labelCheckpointInterval: TimeInterval = 5
    private let library: any PhotoLibraryUpdating
    private let store: SQLiteTravelIndexStore
    private let resolver: PlaceLabelResolver
    private let configuration: TravelClusteringConfiguration
    private let currentIndex: () -> TravelIndex?
    private let onIndex: (TravelIndex) -> Void
    private let onUnchanged: (Bool) -> Void
    private let onLabel: (TravelPlace) -> Void
    private let onProgress: (LibraryPreparationProgress) -> Void
    private let onDiscovery: ([TravelPlace]) -> Void
    private let onRemoved: (Set<String>) -> Void
    private let onAvailable: (Set<String>, Bool) -> Void
    private let onScopeChanged: () -> Void
    private let onUnavailable: () async -> Void
    private(set) var progress = LibraryPreparationProgress()
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var changeDebounce: Task<Void, Never>?
    private var active = true
    private var requestedMode: LibraryPreparationMode?
    private var generation = UUID()
    private var lastCheckpoint = Date.distantPast
    private var validPhotos = 0
    private var structuralChange = false
    private var observing = false

    init(library: any PhotoLibraryUpdating, store: SQLiteTravelIndexStore,
         resolver: PlaceLabelResolver, configuration: TravelClusteringConfiguration,
         currentIndex: @escaping () -> TravelIndex?, onIndex: @escaping (TravelIndex) -> Void,
         onUnchanged: @escaping (Bool) -> Void, onLabel: @escaping (TravelPlace) -> Void, onProgress: @escaping (LibraryPreparationProgress) -> Void,
         onDiscovery: @escaping ([TravelPlace]) -> Void, onRemoved: @escaping (Set<String>) -> Void,
         onAvailable: @escaping (Set<String>, Bool) -> Void,
         onScopeChanged: @escaping () -> Void = {}, onUnavailable: @escaping () async -> Void) {
        self.onUnchanged = onUnchanged
        self.onScopeChanged = onScopeChanged
        self.library = library; self.store = store; self.resolver = resolver; self.configuration = configuration
        self.currentIndex = currentIndex; self.onIndex = onIndex; self.onLabel = onLabel
        self.onProgress = onProgress; self.onDiscovery = onDiscovery; self.onRemoved = onRemoved
        self.onAvailable = onAvailable
        self.onUnavailable = onUnavailable
    }

    func restoreAndStart() async {
        if let saved = try? await store.loadPreparationProgress() { progress = saved }
        if currentIndex() != nil, let work = try? await store.placeLabelWork(now: Date(), limit: 0) {
            progress.updateLabelWork(work)
            if progress.phase == .partial {
                if progress.userPaused { progress.phase = .paused; progress.notice = nil }
                else if work.ready == 0 { progress.finishLabelPass() }
                else { progress.phase = .labeling; progress.notice = nil }
                try? await persist(force: true)
            }
        }
        onProgress(progress)
        ensureObserving()
        guard !progress.userPaused, active else { return }
        await request(currentIndex() == nil ? .initial : .update)
    }

    private func ensureObserving() {
        if !observing {
            observing = true
            library.observeChanges { [weak self] in
                Task { @MainActor [weak self] in self?.libraryChanged() }
            }
        }
    }

    func request(_ mode: LibraryPreparationMode) async {
        ensureObserving()
        wake?.cancel(); wake = nil
        if worker != nil {
            if mode == .rebuild || (mode == .update && (progress.phase == .labeling || !progress.phase.isWorking)) {
                requestedMode = requestedMode == .rebuild ? .rebuild : mode
                progress.notice = .restartAfterSave
                try? await persist(force: true)
            }
            return
        }
        guard active else { return }
        progress.userPaused = false
        progress.mode = mode
        progress.needsMetadata = mode != .labels
        progress.notice = nil
        let run = UUID()
        generation = run
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(mode, generation: run)
            if self.generation == run { self.worker = nil }
        }
    }

    func pause(userInitiated: Bool) async {
        if userInitiated { progress.userPaused = true }
        wake?.cancel(); wake = nil
        let previous = worker
        generation = UUID()
        previous?.cancel()
        worker = nil
        if progress.phase.isWorking || userInitiated { progress.phase = .paused }
        onProgress(progress)
        // Persist user intent before draining a shared lookup that a visible
        // photo may still need. Termination during that wait must stay paused.
        try? await persist(force: true)
        _ = await previous?.value
    }

    func setActive(_ value: Bool) async {
        guard active != value else { return }
        active = value
        if !value { await pause(userInitiated: false) }
        else if !progress.userPaused { await request(.update) }
        else { await reconcilePausedScope() }
    }

    func stop() async {
        active = false
        changeDebounce?.cancel()
        library.stopObservingChanges()
        observing = false
        await pause(userInitiated: false)
    }

    private func libraryChanged() {
        changeDebounce?.cancel()
        changeDebounce = Task { [weak self] in
            guard let self, self.active else { return }
            let access = await self.library.authorizationStatus()
            guard access == .authorized || access == .limited else {
                await self.onUnavailable(); return
            }
            if let live = self.library as? PhotoKitLibrary, self.currentIndex() != nil,
               access == .limited || !TravelScanPreferences.load().excludedAlbums.isEmpty {
                do {
                    let version = try JourneyPlaceCatalog.shared.version
                    let key = try await live.publicationKey(access: access, catalogVersion: version, locale: AppLocalization.locale.identifier)
                    let previous = try await self.store.loadSyncState().authorization
                    try Task.checkCancellation()
                    if key.transition(from: previous) == .withdraw {
                        self.onScopeChanged()
                        await self.pause(userInitiated: false)
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.onScopeChanged()
                    await self.pause(userInitiated: false)
                }
            }
            guard !self.progress.userPaused else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard self.active else { return }
            if self.worker != nil { self.requestedMode = self.requestedMode == .rebuild ? .rebuild : .update }
            else { await self.request(.update) }
        }
    }

    private func reconcilePausedScope() async {
        guard let live = library as? PhotoKitLibrary, currentIndex() != nil else { return }
        let access = await live.authorizationStatus()
        guard access == .authorized || access == .limited else { await onUnavailable(); return }
        do {
            let version = try JourneyPlaceCatalog.shared.version
            let key = try await live.publicationKey(access: access, catalogVersion: version, locale: AppLocalization.locale.identifier)
            let previous = try await store.loadSyncState().authorization
            if key.transition(from: previous) == .withdraw { onScopeChanged() }
        } catch { onScopeChanged() }
    }

    private func run(_ initialMode: LibraryPreparationMode, generation run: UUID) async {
        let analytics = ProductAnalytics.shared
        let consent = analytics.consentRevision
        func report(_ event: ProductEvent) {
            if generation == run, consent == analytics.consentRevision {
                analytics.capture(event, value: progress.mode.rawValue)
            }
        }
        do {
            var mode = initialMode
            while true {
                try check(run)
                // A rebuild/update can be queued behind an in-flight label
                // request. Publish the mode that actually starts this pass,
                // rather than leaving the previous worker's mode in the UI.
                progress.mode = mode
                progress.needsMetadata = mode != .labels
                progress.notice = nil
                if mode != .labels { try await synchronize(mode, generation: run) }
                try check(run)
                if let requested = requestedMode {
                    requestedMode = nil; mode = requested; continue
                }
                let interrupted = try await completeLabels(generation: run)
                if interrupted, let requested = requestedMode {
                    requestedMode = nil; mode = requested; continue
                }
                if let live = library as? PhotoKitLibrary {
                    let changed = try await live.auditCameras(removed: { [weak self] ids in
                        await self?.removeAfterInspection(ids, run: run)
                    }, shouldYield: { [weak self] in await self?.auditShouldYield(run) ?? true })
                    try check(run)
                    if changed || requestedMode != nil {
                        mode = requestedMode ?? .update
                        requestedMode = nil
                        continue
                    }
                }
                report(.preparationCompleted)
                return
            }
        } catch is CancellationError {
            // pause() owns the final checkpoint; never overwrite a newer run.
        } catch LibraryPreparationError.unavailable {
            guard generation == run else { return }
            report(.preparationFailed)
            progress.phase = .failed
            progress.notice = .libraryUnavailable
            onProgress(progress)
            try? await persist(force: true)
            await onUnavailable()
        } catch {
            guard generation == run else { return }
            report(.preparationFailed)
            progress.phase = .failed
            progress.notice = .saveFailed
            onProgress(progress)
            try? await persist(force: true)
        }
    }

    private func removeAfterInspection(_ ids: Set<String>, run: UUID) {
        guard generation == run else { return }
        onRemoved(ids)
    }

    private func auditShouldYield(_ run: UUID) -> Bool { generation != run || requestedMode != nil }

    private func synchronize(_ mode: LibraryPreparationMode, generation run: UUID) async throws {
        let access = await library.authorizationStatus()
        guard access == .authorized || access == .limited else { throw LibraryPreparationError.unavailable }
        let live = library as? PhotoKitLibrary
        let catalog = live == nil ? nil : try JourneyPlaceCatalog.shared
        var authorization = access == .limited ? "limited" : "authorized"
        let sync = try await store.loadSyncState()
        var previousCameraRevision: Int?
        var regroupStoredMetadata = false
        if let catalog, let live {
            let key = try await live.publicationKey(access: access, catalogVersion: catalog.version, locale: AppLocalization.locale.identifier, activateScope: true)
            try check(run)
            if currentIndex() != nil, key.transition(from: sync.authorization) == .withdraw { onScopeChanged() }
            previousCameraRevision = key.previousCameraRevision(from: sync.authorization)
            regroupStoredMetadata = key.canRegroupStoredMetadata(from: sync.authorization)
            authorization = try key.serialized()
        }
        var full = mode == .rebuild || sync.token == nil || access == .limited
            || Date().timeIntervalSince(sync.lastFullCheck ?? .distantPast) >= 7 * 86_400
            || (!regroupStoredMetadata && (mode == .initial || currentIndex() == nil
                || (sync.authorization != authorization && previousCameraRevision == nil)))
        progress.phase = .checking
        progress.needsMetadata = true
        progress.checkedPhotos = 0
        progress.totalPhotos = 0
        progress.retryAt = nil
        try await persist(force: true)
        while true {
            try check(run)
            validPhotos = 0; structuralChange = full || regroupStoredMetadata
            // T0 is captured BEFORE the snapshot. Only replayed changes advance it.
            let token = full ? try await library.currentChangeToken() : sync.token!
            let pass = MetadataScanPass()
            if structuralChange || previousCameraRevision != nil {
                pass.staging = try await store.beginMetadataScan(copyCurrent: !full)
            }
            if full, let staging = pass.staging {
                _ = try await library.enumeratePhotos { [weak self] batch in
                    guard let self else { throw CancellationError() }
                    try await self.receive(batch, staging: staging, generation: run, full: true)
                }
            }
            let changes: LibraryChangeResult
            do {
                changes = try await library.enumerateChanges(since: token) { [weak self] batch in
                    guard let self else { throw CancellationError() }
                    try await self.receiveChanges(batch, pass: pass, generation: run)
                }
            } catch LibraryPreparationError.expiredToken where !full {
                full = true
                continue
            }
            try check(run)
            if !full, regroupStoredMetadata, changes.changedAssetCount == 0,
               try await !store.matchesSourcePhotoCount(changes.sourcePhotoCount) {
                full = true
                continue
            }
            guard let staging = pass.staging else {
                guard try await canPublish(live, authorization: authorization, run: run) else { return }
                guard try await store.commitUnchanged(from: sync, changes: changes, authorization: authorization) else {
                    full = true
                    continue
                }
                try check(run)
                onUnchanged(changes.token != sync.token)
                progress.needsMetadata = false
                try await persist(force: true)
                return
            }
            if !full, let previousCameraRevision, let live {
                var cursor = ""
                while true {
                    let ids = try await live.scanLedger.removals(after: previousCameraRevision, startingAfter: cursor)
                    guard let last = ids.last else { break }
                    try await receive(.init(records: [], removedIDs: ids, checked: changes.changedAssetCount), staging: staging, generation: run, full: false)
                    cursor = last
                }
            }
            let located = try await store.stagedPhotoCount(run: staging)
            var lastRemoved = ""
            while true {
                let removed = try await store.removedStagedAssets(run: staging, after: lastRemoved)
                guard let last = removed.last else { break }
                onRemoved(Set(removed)); lastRemoved = last
                try check(run)
            }
            progress.locatedPhotos = located
            progress.phase = structuralChange ? .organizing : .saving
            progress.checkedPhotos = 0
            try await persist(force: true)
            let index: TravelIndex?
            if structuralChange {
                while !(await store.canActivateMetadata()) {
                    try check(run)
                    progress.phase = .waiting
                    progress.notice = .waitForWall
                    try await persist(force: true)
                    try await Task.sleep(for: .seconds(1))
                }
                progress.phase = .organizing
                progress.notice = nil
                try await persist(force: true)
                let box = PreparationProgressRelay { [weak self] count, places in
                    guard let self, self.generation == run else { return }
                    self.progress.checkedPhotos = count
                    self.onProgress(self.progress)
                    self.onDiscovery(places)
                }
                guard try await canPublish(live, authorization: authorization, run: run) else { return }
                index = try await store.activateMetadata(run: staging, sourcePhotoCount: changes.sourcePhotoCount,
                                                          token: changes.token, fullCheck: full, authorization: authorization,
                                                          configuration: configuration, catalog: catalog) { count, places in
                    box.publish(count, places)
                }
            } else {
                guard try await canPublish(live, authorization: authorization, run: run) else { return }
                index = try await store.commitDisplayChanges(run: staging, token: changes.token,
                                                              sourcePhotoCount: changes.sourcePhotoCount, authorization: authorization)
            }
            try check(run)
            guard let index else { throw LibraryPreparationError.saveFailed }
            if requestedMode != nil {
                guard try await canPublish(live, authorization: authorization, run: run) else { return }
            }
            onIndex(index)
            progress.needsMetadata = false
            try await persist(force: true)
            return
        }
    }

    private func canPublish(_ live: PhotoKitLibrary?, authorization: String, run: UUID) async throws -> Bool {
        try check(run)
        guard let live else { return true }
        let access = await live.authorizationStatus()
        guard access == .authorized || access == .limited else { throw LibraryPreparationError.unavailable }
        let version = try JourneyPlaceCatalog.shared.version
        let fresh = try await live.publicationKey(access: access, catalogVersion: version, locale: AppLocalization.locale.identifier)
        try check(run)
        let transition = fresh.transition(from: authorization)
        if transition == .withdraw { onScopeChanged() }
        if transition != .reuse { requestedMode = .rebuild }
        return transition == .reuse
    }

    @MainActor
    private final class MetadataScanPass {
        var staging: UUID?
    }

    private func receiveChanges(_ batch: PhotoMetadataBatch, pass: MetadataScanPass, generation run: UUID) async throws {
        try check(run)
        guard !batch.records.isEmpty || !batch.removedIDs.isEmpty else { return }
        if pass.staging == nil {
            pass.staging = try await store.beginMetadataScan(copyCurrent: true)
        }
        if let staging = pass.staging {
            try await receive(batch, staging: staging, generation: run, full: false)
        }
    }

    private func receive(_ batch: PhotoMetadataBatch, staging: UUID, generation run: UUID, full: Bool) async throws {
        try check(run)
        let changed = try await store.stageMetadata(batch, run: staging)
        try check(run)
        structuralChange = structuralChange || changed
        let validIDs = Set(batch.records.map(\.id))
        onAvailable(validIDs, true)
        let removed = Set(batch.removedIDs).subtracting(validIDs)
        if !removed.isEmpty { onRemoved(removed) }
        if full {
            validPhotos += batch.records.count
            progress.checkedPhotos = batch.checked
            progress.totalPhotos = batch.total
            progress.locatedPhotos = validPhotos
        }
        if full || !batch.records.isEmpty {
            // Regional previews are not final visits or city counts.
            let places = batch.records.prefix(180).map { photo in
                TravelPlace(id: "scan-\(Int(floor(photo.coordinate.latitude / 2)))-\(Int(floor(photo.coordinate.longitude / 2)))",
                            name: "", country: nil, coordinate: photo.coordinate,
                            startDate: photo.creationDate, endDate: photo.creationDate, photoCount: 1, coverAssetID: nil)
            }
            onDiscovery(places)
        }
        try await persist(force: full && batch.checked == batch.total)
    }

    private func completeLabels(generation run: UUID) async throws -> Bool {
        progress.attemptedPlaces = 0
        while true {
            try check(run)
            if requestedMode != nil { return true }
            let work = try await store.placeLabelWork(now: Date())
            try check(run)
            if requestedMode != nil { return true }
            progress.updateLabelWork(work)
            if work.jobs.isEmpty {
                progress.finishLabelPass()
                try await persist(force: true)
                try check(run)
                if let date = progress.retryAt { scheduleWake(at: date) }
                return false
            }
            if progress.phase != .labeling || progress.attemptedPlaces == 0 {
                progress.phase = .labeling
                try await persist(force: true)
            }
            for job in work.jobs {
                try check(run)
                if requestedMode != nil { return true }
                let resolution = await resolver.resolution(for: job.place, priority: .library)
                let label = resolution.label
                try check(run)
                // A completed atlas lookup is final for this catalogue revision.
                let retry = resolution.shouldRetry
                    ? Date().addingTimeInterval(min(7 * 86_400, 3_600 * pow(2, Double(min(job.attempts, 8)))))
                    : nil
                if let place = try await store.recordLabelAttempt(
                    job.place,
                    label: label,
                    attempts: job.attempts + 1,
                    nextRetryAt: retry,
                    terminal: !resolution.shouldRetry && label?.isComplete != true
                ) {
                    try check(run)
                    if !PlaceDisplayLabel(place: job.place).isComplete,
                       PlaceDisplayLabel(place: place).isComplete {
                        progress.completePlaces = min(progress.totalPlaces, progress.completePlaces + 1)
                        progress.coveredPhotos += place.photoCount
                    }
                    progress.readyPlaces = max(0, (progress.readyPlaces ?? 0) - 1)
                    if let retry {
                        progress.retryAt = min(progress.retryAt ?? retry, retry)
                    } else {
                        progress.remainingPlaces = max(0, progress.remainingPlaces - 1)
                    }
                    onLabel(place)
                    onDiscovery([place])
                }
                progress.attemptedPlaces += 1
                // The label row itself is already durable. Publish the exact
                // in-memory counters immediately, but checkpoint this derived
                // progress less often instead of reloading the whole index and
                // writing a second transaction after every lookup.
                onProgress(progress)
                try await persist(force: false, minimumInterval: Self.labelCheckpointInterval)
            }
        }
    }

    /// A foreground lookup or a visibility change can finish or expose work while the job is paused.
    func refreshIdleLabelWork() async {
        guard worker == nil, !progress.needsMetadata else { return }
        let run = generation
        guard let work = try? await store.placeLabelWork(now: Date(), limit: 0),
              generation == run, worker == nil, !Task.isCancelled else { return }
        progress.updateLabelWork(work)
        if !progress.userPaused, progress.phase == .complete, active {
            if work.pending == 0 { wake?.cancel(); wake = nil }
            else if work.ready == 0, let retry = work.nextRetry { scheduleWake(at: retry) }
        }
        onProgress(progress)
    }

    private func persist(
        force: Bool,
        minimumInterval: TimeInterval = 0.5
    ) async throws {
        guard force || Date().timeIntervalSince(lastCheckpoint) >= minimumInterval else { return }
        progress.updatedAt = Date()
        let snapshot = progress
        try await store.savePreparationProgress(snapshot)
        lastCheckpoint = Date()
        onProgress(snapshot)
    }

    private func scheduleWake(at date: Date) {
        wake?.cancel()
        wake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow))) } catch { return }
            guard let self, self.active, !self.progress.userPaused else { return }
            await self.request(.labels)
        }
    }

    private func check(_ run: UUID) throws {
        try Task.checkCancellation()
        guard generation == run, active else { throw CancellationError() }
    }
}

/// The synchronous SQLite loop emits at most twice/second, never per photo.
private final class PreparationProgressRelay: Sendable {
    let callback: @MainActor @Sendable (Int, [TravelPlace]) -> Void
    init(_ callback: @escaping @MainActor @Sendable (Int, [TravelPlace]) -> Void) { self.callback = callback }
    nonisolated func publish(_ count: Int, _ places: [TravelPlace]) {
        Task { @MainActor in callback(count, places) }
    }
}
