import Combine
import Foundation
import Photos

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case welcome
        case scanning
        case globe
        case empty
        case denied
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var index: TravelIndex? {
        didSet {
            indexedPlaces = PhotoWallPlaces(index?.places ?? [])
            overview.receive(index, minimumVisitItems: minimumJourneyItems)
        }
    }
    private(set) var indexedPlaces = PhotoWallPlaces()
    lazy var overview = OverviewContentModel(app: self)
    @Published var selectedPlaceID: String?
    @Published var isShowingGallery = false
    @Published private(set) var isUsingSampleData = false
    @Published private(set) var hidesTransitPhotos = UserDefaults.standard.object(forKey: "photoEarth.hidesTransitPhotos") as? Bool ?? true
    @Published private(set) var minimumJourneyItems: Int
    private let journeyDefaults: UserDefaults

    func setMinimumJourneyItems(_ count: Int) {
        let value = JourneyVisitThreshold.normalized(count)
        guard minimumJourneyItems != value else { return }
        withdrawTopShelf()
        shelfRequest = UUID()
        if case .journey = pendingTopShelfRoute { pendingTopShelfRoute = nil }
        minimumJourneyItems = value
        ProductAnalytics.shared.capture(.settingsChanged, value: "journey_minimum")
        journeyDefaults.set(value, forKey: JourneyVisitThreshold.storageKey)
        if let index { overview.receive(index, minimumVisitItems: value) }
        refreshTopShelf()
    }

    @Published private(set) var isUpdatingTransitFilter = false
    @Published private(set) var transitFilterError: String?

    var analyticsLibrary: JourneyEventContext.Library {
        if isExploringPublicGlobe { return .publicGlobe }
        return isUsingSampleData ? .sample : .personal
    }

    var supportsTransitFiltering: Bool { !isUsingSampleData && indexStore is SQLiteTravelIndexStore }

    func setHidesTransitPhotos(_ enabled: Bool) async {
        guard !isUpdatingTransitFilter, let store = indexStore as? SQLiteTravelIndexStore else { return }
        isUpdatingTransitFilter = true
        withdrawTopShelf()
        transitFilterError = nil
        defer { isUpdatingTransitFilter = false; refreshTopShelf() }
        do {
            if let updated = try await store.setTransitFiltering(enabled) {
                apply(updated, usingSampleData: false)
            }
            hidesTransitPhotos = enabled
            ProductAnalytics.shared.capture(.settingsChanged, value: "transit_filter")
            UserDefaults.standard.set(enabled, forKey: "photoEarth.hidesTransitPhotos")
        } catch {
            transitFilterError = AppLocalization.string("settings.transit_error", defaultValue: "Couldn’t update this setting. Please try again.")
        }
    }

    @Published private(set) var showsJourneysOnTopShelf = UserDefaults.standard.object(forKey: "photoEarth.topShelfJourneys") as? Bool ?? true
    @Published private(set) var pendingTopShelfRoute: JourneyShelfDestination?
    @Published private(set) var isExploringPublicGlobe = false

    enum ShelfAction {
        case globe
        case journey(PlaceCollection)
    }

    func closePublicGlobe() { isExploringPublicGlobe = false }
    private let topShelf = JourneyShelfPublication()
    private var shelfRequest = UUID()
#if DEBUG
    private let shelfQA = JourneyShelfQA()
#endif

    func setShowsJourneysOnTopShelf(_ enabled: Bool) {
        guard enabled != showsJourneysOnTopShelf else { return }
        if !enabled {
            guard topShelf.clear() else { return }
            if case .journey = pendingTopShelfRoute { pendingTopShelfRoute = nil }
        }
        showsJourneysOnTopShelf = enabled
        ProductAnalytics.shared.capture(.settingsChanged, value: "top_shelf")
        UserDefaults.standard.set(enabled, forKey: "photoEarth.topShelfJourneys")
        if enabled { refreshTopShelf() }
    }

    private func refreshTopShelf() {
        guard isSceneActive, showsJourneysOnTopShelf, usesLivePhotoLibrary, let index,
              let store = indexStore as? SQLiteTravelIndexStore else { return }
        topShelf.refresh(self, index: index, store: store)
    }

    private func withdrawTopShelf() {
        if privateLibraryAllowed && photoLibrary is PhotoKitLibrary { topShelf.clear() }
    }

    func requestTopShelfURL(_ url: URL) {
        guard let destination = JourneyShelfDestination(url: url, showsJourneys: showsJourneysOnTopShelf) else { return }
        shelfRequest = UUID()
        pendingTopShelfRoute = destination
#if DEBUG
        switch destination {
        case .globe: shelfQA.receivedRoute = "globe"
        case .journey(let route): shelfQA.receivedRoute = route
        }
#endif
    }

    func takeTopShelfAction() async -> ShelfAction? {
        guard let destination = pendingTopShelfRoute, phase != .loading else { return nil }
        if destination == .globe {
            if index != nil, isPreparationPresented && scanScope == nil {
                closePreparation()
                return nil
            }
            pendingTopShelfRoute = nil
            isExploringPublicGlobe = !usesLivePhotoLibrary || index == nil || phase != .globe
#if DEBUG
            shelfQA.openedRoute = "globe"
#endif
            return .globe
        }
        guard case .journey(let route) = destination, phase == .globe, !isPreparationPresented, index != nil else { return nil }
        pendingTopShelfRoute = nil
        let ticket = shelfRequest
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !Task.isCancelled, ticket == shelfRequest, phase == .globe, showsJourneysOnTopShelf, usesLivePhotoLibrary,
              let index, let saved = JourneyShelfKeychain.read(), saved.imageVersion == JourneyShelfSnapshot.currentImageVersion,
              let item = saved.items.first(where: { $0.route == route }), !excludedAssetIDs.contains(item.assetID) {
            let validity = JourneyShelfPhoto.delivery(saved, checkingWall: true)
            guard validity.readable, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject,
                  validity.permits(item, proof: JourneyShelfPhoto.proof(for: asset, excluding: TravelScanPreferences.load().excludedAlbums)) else { return nil }
            guard let collection = JourneyShelfSelection.recent(in: index, minimumVisitItems: minimumJourneyItems)
                .first(where: { $0.collection.id == route })?.collection else { return nil }
            var needsSync = validity.oversizedWallDelta
            if !needsSync, !validity.touched.isEmpty, let store = indexStore as? SQLiteTravelIndexStore {
                needsSync = (try? await store.journeyContainsChangedMembers(validity.touched, places: collection.placeIDs)) ?? true
            }
            guard ticket == shelfRequest, showsJourneysOnTopShelf, usesLivePhotoLibrary, phase == .globe else { return nil }
            let latest = JourneyShelfPhoto.delivery(saved, checkingWall: true)
            if !needsSync, latest.readable, !latest.oversizedWallDelta,
               latest.touched.isSubset(of: validity.touched), self.index?.contentRevision == index.contentRevision,
               JourneyShelfKeychain.read() == saved {
#if DEBUG
                shelfQA.openedRoute = collection.id
#endif
                isExploringPublicGlobe = false
                return .journey(collection)
            }
            guard .now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return nil }
        }
        return nil
    }

    private let photoLibrary: any PhotoLibraryProviding
    private let indexStore: any TravelIndexStoring
    @Published private(set) var coverRevision = 0
    private var coverNotices = Set<AnyCancellable>()
    private var coverInvalidation: Task<Void, Never>?
    private lazy var scenicCovers: ScenicCoverSelector? = {
        guard let store = indexStore as? SQLiteTravelIndexStore else { return nil }
        NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)
            .sink { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let ids = (notice.userInfo?["changed"] as? Set<String> ?? [])
                        .union(notice.userInfo?["removed"] as? Set<String> ?? [])
                    self.scenicCovers?.invalidate()
                    self.coverRevision += 1
                    let previous = self.coverInvalidation
                    self.coverInvalidation = Task {
                        await previous?.value
                        try? await store.invalidateCoverAnalyses(for: ids)
                    }
                }
            }.store(in: &coverNotices)
        return ScenicCoverSelector(store: store)
    }()
    private let preferencesStore: any PreferenceSyncing
    @Published private(set) var placeLabelStates: [String: PlaceLabelLoadState] = [:]
    private let placeLabelResolver: PlaceLabelResolver
    private var labelGeneration = UUID()
    private var pendingPlaceNameWrites: [String: TravelPlace] = [:]
    private let clusterer: TravelClusterer
    private var preferences = SyncedPreferences()
    private var samplePhotos: [PhotoAssetRecord] = []
    private var sampleLatestByPlace: [String: PhotoPreviewMetadata] = [:]
    private var samplePhotoIndex: PhotoSpatialIndex?
    let preparationPresentation = PreparationPresentationState()
    private(set) var preparationProgress: LibraryPreparationProgress {
        get { preparationPresentation.progress }
        set { preparationPresentation.update(newValue) }
    }
    @Published private(set) var isPreparationPresented = false
    @Published private(set) var isInitialLibraryReady = false
    private var keepsPreparationVisible = false
    private var isSceneActive = true
    private var preparationHandoffTask: Task<Void, Never>?
    private(set) var scanDiscovery: ScanDiscovery {
        get { preparationPresentation.discovery }
        set { preparationPresentation.discovery = newValue }
    }
    private(set) var recentlyPreparedPlace: TravelPlace? {
        get { preparationPresentation.recentPlace }
        set { preparationPresentation.recentPlace = newValue }
    }
    @Published private(set) var excludedAssetIDs: Set<String> = []
    @Published private(set) var lastLibraryCheck: Date?
    struct ScanScopePresentation: Identifiable {
        let id = UUID()
        let startsFirstScan: Bool
    }

    @Published private(set) var scanScope: ScanScopePresentation?
    @Published private(set) var sampleConnectionDenied = false
    @Published private(set) var scanScopeRevision = 0
    private var isRequestingPhotoAccess = false
    private static let deferredScanScopeKey = "travelScan.deferredInitialChoice.v1"
    private var preparation: LibraryPreparationCoordinator?
    private var maintainsLibrary = true
    private var privateLibraryAllowed = true
    private var hasStarted = false
    private var scanPoints: [String: TravelPlace] = [:]
    private var lastDiscoveryPublish = Date.distantPast
    private var librarySession = UUID()

    var canBrowsePreparedLibrary: Bool { index != nil }
    var canReturnToPreparation: Bool { preparation != nil }
    var usesLivePhotoLibrary: Bool { privateLibraryAllowed && photoLibrary is PhotoKitLibrary && !isUsingSampleData }

    init(sampleOnly: Bool = false) {
        privateLibraryAllowed = !sampleOnly
        journeyDefaults = .standard
        minimumJourneyItems = JourneyVisitThreshold.load()
#if DEBUG
        let isWelcomeFixture = ProcessInfo.processInfo.arguments.contains("--welcome-fixture")
        let isTransitFixture = ProcessInfo.processInfo.arguments.contains("--transit-fixture")
        let isAnniversaryFixture = ProcessInfo.processInfo.arguments.contains("--anniversary-fixture")
        if ProcessInfo.processInfo.arguments.contains("--preparation-fixture") || isWelcomeFixture || isTransitFixture || isAnniversaryFixture {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(isWelcomeFixture ? "PhotoEarth/WelcomeFixture" : "PhotoEarth/PreparationFixture", isDirectory: true)
            if !ProcessInfo.processInfo.arguments.contains("--keep-preparation-fixture") {
                try? FileManager.default.removeItem(at: folder)
            }
            let records = isAnniversaryFixture
                ? PreparationFixtureLibrary.anniversaryRecords(empty: ProcessInfo.processInfo.arguments.contains("--anniversary-empty"))
                : (isTransitFixture ? PreparationFixtureLibrary.transitRecords : SampleTravelIndex.make().photos)
            photoLibrary = PreparationFixtureLibrary(records: records,
                                                      initiallyRequiresAuthorization: isWelcomeFixture)
            indexStore = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("fixture.sqlite"), hidesTransitPhotos: isTransitFixture)
            preferencesStore = LocalPreferenceStore()
            clusterer = TravelClusterer()
            placeLabelResolver = PlaceLabelResolver { coordinate in
                try await Task.sleep(for: .seconds(2))
                return try JourneyPlaceCatalog.shared.label(coordinate, locale: AppLocalization.locale)
            }
            return
        }
#endif
        self.photoLibrary = PhotoKitLibrary()
        self.indexStore = SQLiteTravelIndexStore()
#if DEBUG
        self.preferencesStore = LocalPreferenceStore()
#else
        self.preferencesStore = ICloudPreferenceStore()
#endif
        self.clusterer = TravelClusterer()
        self.placeLabelResolver = PlaceLabelResolver()
    }

    init(
        photoLibrary: any PhotoLibraryProviding,
        indexStore: any TravelIndexStoring,
        preferencesStore: any PreferenceSyncing,
        clusterer: TravelClusterer,
        placeLabelResolver: PlaceLabelResolver? = nil,
        automaticallyMaintainsLibrary: Bool = false,
        journeyDefaults: UserDefaults = .standard
    ) {
        self.photoLibrary = photoLibrary
        self.indexStore = indexStore
        self.preferencesStore = preferencesStore
        self.clusterer = clusterer
        self.journeyDefaults = journeyDefaults
        minimumJourneyItems = JourneyVisitThreshold.load(from: journeyDefaults)
        self.placeLabelResolver = placeLabelResolver ?? PlaceLabelResolver()
        maintainsLibrary = automaticallyMaintainsLibrary
    }

    var selectedPlace: TravelPlace? {
        index?.place(id: selectedPlaceID) ?? index?.places.first
    }

    func start() async {
        guard privateLibraryAllowed, !hasStarted else { return }
        hasStarted = true
        JourneyPlaceCatalog.removeRetiredDownloads()
#if DEBUG
        shelfQA.observe(self, store: indexStore as? SQLiteTravelIndexStore)
#endif
        if !showsJourneysOnTopShelf { withdrawTopShelf() }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            useSampleData()
            return
        }
        preferences = await preferencesStore.load()
        let access = await photoLibrary.authorizationStatus()
        guard access == .authorized || access == .limited else {
            withdrawTopShelf()
            phase = access == .notDetermined ? .welcome : .denied
            return
        }
        if photoLibrary is PhotoKitLibrary, !TravelScanPreferences.hasSavedChoice {
            phase = .welcome
            if UserDefaults.standard.bool(forKey: Self.deferredScanScopeKey) { withdrawTopShelf() }
            else { presentInitialScanScope() }
            return
        }
        if let store = indexStore as? SQLiteTravelIndexStore { hidesTransitPhotos = await store.transitFilteringIsEnabled() }
        var canRestore = true
        if let live = photoLibrary as? PhotoKitLibrary, let store = indexStore as? SQLiteTravelIndexStore {
            let catalog = try? JourneyPlaceCatalog.shared
            let stored = try? await store.loadSyncState().authorization
            if let catalog, let key = try? await live.publicationKey(access: access, catalogVersion: catalog.version, locale: AppLocalization.locale.identifier) {
                canRestore = key.transition(from: stored) == .reuse
                if let stored, key.changesOnlyLocale(from: stored) {
                    withdrawTopShelf()
                    if (try? await store.refreshLocale(from: stored, to: key, catalog: catalog)) == true {
                        let freshAccess = await live.authorizationStatus()
                        if freshAccess == .authorized || freshAccess == .limited {
                            canRestore = (try? await live.publicationKey(access: freshAccess, catalogVersion: catalog.version,
                                locale: AppLocalization.locale.identifier)) == key
                        }
                    }
                }
            } else { canRestore = false }
            if !canRestore { withdrawTopShelf() }
        }
        if canRestore, let cached = try? await indexStore.load() {
            apply(cached, usingSampleData: false)
            if maintainsLibrary {
                installPreparation()
                if let store = indexStore as? SQLiteTravelIndexStore { lastLibraryCheck = try? await store.loadSyncState().lastCheck }
                await preparation?.restoreAndStart()
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--diagnose-place-labels") {
                let unresolved = cached.places.filter { !PlaceDisplayLabel(place: $0).isComplete }
                PlaceLabelDiagnostics.record("diagnostic places=\(cached.places.count) unresolved=\(unresolved.count) sampleLimit=3")
                await resolvePlaceLabels(for: Array(unresolved.prefix(3).map(\.id)))
                PlaceLabelDiagnostics.record("diagnosticFinished")
            }
#endif
            return
        }

        let status = await photoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            if maintainsLibrary, photoLibrary is any PhotoLibraryUpdating {
                installPreparation()
                phase = .scanning
                isPreparationPresented = true
                await preparation?.restoreAndStart()
                return
            }
            await scan()
        case .notDetermined:
            phase = .welcome
        case .denied, .restricted:
            phase = .denied
        }
    }

    func requestAccessAndScan() async {
        guard privateLibraryAllowed, !isRequestingPhotoAccess, scanScope == nil else { return }
        isRequestingPhotoAccess = true
        defer { isRequestingPhotoAccess = false }
        ProductAnalytics.shared.capture(.accessRequested, context: .init(library: isUsingSampleData ? .sample : nil))
        let status = await photoLibrary.requestAuthorization()
        guard privateLibraryAllowed else { return }
        switch status {
        case .authorized, .limited: ProductAnalytics.shared.capture(.photoAccessResult, value: "granted")
        case .denied, .restricted: ProductAnalytics.shared.capture(.photoAccessResult, value: "denied")
        case .notDetermined: ProductAnalytics.shared.capture(.photoAccessResult, value: "undetermined")
        }
        guard status == .authorized || status == .limited else {
            if isUsingSampleData { sampleConnectionDenied = true }
            else { phase = status == .notDetermined ? .welcome : .denied }
            return
        }
        sampleConnectionDenied = false
        if photoLibrary is PhotoKitLibrary {
            presentInitialScanScope()
        } else {
            startConnectingLibrary()
            await scan()
        }
    }

    private func presentInitialScanScope() {
        withdrawTopShelf()
        scanScope = ScanScopePresentation(startsFirstScan: true)
        ProductAnalytics.shared.capture(.scopePresented, value: "initial")
    }

    func showScanScope() {
        guard usesLivePhotoLibrary, scanScope == nil else { return }
        scanScope = ScanScopePresentation(startsFirstScan: false)
        ProductAnalytics.shared.capture(.scopePresented, value: "settings")
    }

    func cancelScanScope() {
        guard let scanScope else { return }
        if scanScope.startsFirstScan {
            ProductAnalytics.shared.capture(.scopeDismissed, value: "dismissed")
            UserDefaults.standard.set(true, forKey: Self.deferredScanScopeKey)
        }
        self.scanScope = nil
    }

    func acceptScanScope(_ draft: TravelScanPreferences, presentation: ScanScopePresentation) async throws {
        guard scanScope?.id == presentation.id else { throw CancellationError() }
        let verification = Task.detached { try TravelScanScope.fetch(draft, saveVerification: false) }
        let preferences = try await withTaskCancellationHandler {
            try await verification.value.preferences
        } onCancel: {
            verification.cancel()
        }
        try Task.checkCancellation()
        guard scanScope?.id == presentation.id, !isExploringPublicGlobe else { throw CancellationError() }
        guard PhotoKitLibrary.hasReadAccess else { throw LibraryPreparationError.unavailable }
        let changed = preferences != TravelScanPreferences.load()
        try preferences.save()
        scanScope = nil
        if presentation.startsFirstScan {
            ProductAnalytics.shared.capture(.scopeDismissed, value: "saved")
            ProductAnalytics.shared.capture(.firstScanRequested)
            UserDefaults.standard.removeObject(forKey: Self.deferredScanScopeKey)
            startConnectingLibrary()
            installPreparation()
        } else if changed || (index == nil && preparationProgress.phase == .failed) {
            if changed { ProductAnalytics.shared.capture(.settingsChanged, value: "scan_scope") }
            invalidatePublishedScope()
            if !isPreparationPresented { startConnectingLibrary() }
        } else {
            return
        }
        let session = librarySession
        Task {
            if changed && !presentation.startsFirstScan { await preparation?.pause(userInitiated: false) }
            guard session == librarySession else { return }
            await scan(presentsProgress: isPreparationPresented)
        }
    }

    private func startConnectingLibrary() {
        if isUsingSampleData {
            isUsingSampleData = false
            index = nil
            samplePhotos = []
            sampleLatestByPlace = [:]
            samplePhotoIndex = nil
            scanScopeRevision += 1
        }
        phase = .scanning
        isPreparationPresented = true
    }

    private func invalidatePublishedScope() {
        withdrawTopShelf()
        guard index != nil else { return }
        index = nil
        resetPlaceLabelWork()
        SharedPhotoImageScheduler.shared.invalidate(nil)
        scenicCovers?.invalidate()
        scanPoints.removeAll()
        scanDiscovery = ScanDiscovery(revision: scanDiscovery.revision + 1, places: [])
        scanScopeRevision += 1
        phase = .scanning
        isPreparationPresented = true
        isInitialLibraryReady = false
        keepsPreparationVisible = false
    }

    func scanCounts() async -> [TravelScanDecision: Int] {
        guard let live = photoLibrary as? PhotoKitLibrary else { return [:] }
        return (try? await live.scanLedger.counts()) ?? [:]
    }

    func rescan() async {
        guard privateLibraryAllowed else { return }
        guard !isUsingSampleData else {
            resetPlaceLabelWork()
            phase = .welcome
            index = nil
            selectedPlaceID = nil
            samplePhotos = []
            samplePhotoIndex = nil
            return
        }
        let status = await photoLibrary.authorizationStatus()
        guard status == .authorized || status == .limited else {
            phase = status == .notDetermined ? .welcome : .denied
            return
        }
        await updateLibrary(.rebuild)
    }

    func useSampleData() {
        ProductAnalytics.shared.capture(.sampleOpened)
        withdrawTopShelf()
        cancelScanScope()
        sampleConnectionDenied = false
        librarySession = UUID()
        if let preparation { Task { await preparation.stop() } }
        preparation = nil
        isPreparationPresented = false
        let snapshot: TravelIndexSnapshot
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-transition-fixture") {
            snapshot = SampleTravelIndex.makeCollageFixture(transitions: true)
        } else if ProcessInfo.processInfo.arguments.contains("--slideshow-collage-fixture") {
            snapshot = SampleTravelIndex.makeCollageFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--slideshow-journeys-fixture") {
            snapshot = SampleTravelIndex.makeSlideshowJourneyFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--slideshow-filmstrip-fixture") {
            snapshot = SampleTravelIndex.makeFilmstripFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--map-review-fixture") {
            snapshot = SampleTravelIndex.makeMapReviewFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--recent-focus-fixture") {
            snapshot = SampleTravelIndex.makeRecentFocusFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--photo-ratio-fixture") {
            snapshot = SampleTravelIndex.makeRatioFixture()
        }
        else {
            snapshot = ProcessInfo.processInfo.arguments.contains("--home-scroll-fixture")
                ? SampleTravelIndex.makeOverviewStress() : SampleTravelIndex.make()
        }
#else
        snapshot = SampleTravelIndex.make()
#endif
        samplePhotos = snapshot.photos
        var latest: [String: PhotoAssetRecord] = [:]
        for photo in snapshot.photos {
            guard let id = photo.placeID else { continue }
            if let old = latest[id], old.creationDate > photo.creationDate
                || (old.creationDate == photo.creationDate && old.id < photo.id) { continue }
            latest[id] = photo
        }
        sampleLatestByPlace = latest.mapValues(PhotoPreviewMetadata.init)
        samplePhotoIndex = PhotoSpatialIndex(records: snapshot.photos)
        apply(snapshot.index, usingSampleData: true)
    }

    func photos(in viewport: EarthViewport, limit: Int) async -> [PhotoAssetRecord] {
        if let samplePhotoIndex {
            return samplePhotoIndex.photos(in: viewport, limit: limit)
        }
        return ((try? await indexStore.photos(in: viewport, limit: limit)) ?? []).filter { !excludedAssetIDs.contains($0.id) }
    }

    /// Preview failures stay distinct from a successful empty sample.
    func previewPhotos(in viewport: EarthViewport, limit: Int, placeIDs: Set<String>?) async throws -> [PhotoAssetRecord] {
        let records: [PhotoAssetRecord]
        if let samplePhotoIndex {
            records = samplePhotoIndex.photos(in: viewport, limit: limit, placeIDs: placeIDs)
        } else if let store = indexStore as? SQLiteTravelIndexStore {
            records = try await store.photos(in: viewport, limit: limit, placeIDs: placeIDs.map { Array($0) })
        } else {
            records = try await indexStore.photos(in: viewport, limit: limit)
        }
        return records.filter { !excludedAssetIDs.contains($0.id)
            && (placeIDs == nil || placeIDs!.contains($0.placeID ?? "")) }
    }

    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int,
        reader: SQLiteTravelIndexStore? = nil
    ) async throws -> PhotoQueryPage {
        if isUsingSampleData {
            let matching = samplePhotos
                .filter { viewport.contains($0.coordinate) }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate > $1.creationDate
                }
            let start = min(max(0, offset), matching.count)
            let end = min(start + max(0, limit), matching.count)
            return PhotoQueryPage(
                records: Array(matching[start..<end]),
                nextOffset: end < matching.count ? end : nil
            )
        }
        if let reader { return try await reader.photoPage(in: viewport, offset: offset, limit: limit) }
        return try await indexStore.photoPage(in: viewport, offset: offset, limit: limit)
    }

    /// The wall's source is the captured screen, never a cached filmstrip batch
    /// or an estimated camera radius. Both SQLite and demo use the same filter.
    func photoPage(in snapshot: PhotoViewportSnapshot, offset: Int, limit: Int,
                   reader: SQLiteTravelIndexStore? = nil) async throws -> PhotoQueryPage {
        guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        let candidates = try await photoWallCandidates(in: snapshot.viewport, offset: offset, reader: reader)
        return try await PhotoWallPageSelection.page(from: candidates, offset: offset, limit: limit, snapshot: snapshot)
    }

    /// Determine the exact total for the captured screen in bounded batches.
    /// The first displayed page can seed the count so its projection work is not
    /// repeated, while photo records beyond that page are never retained by UI.
    func photoCount(
        in snapshot: PhotoViewportSnapshot,
        startingAt offset: Int,
        initialCount: Int,
        reader: SQLiteTravelIndexStore? = nil,
        scheduling: PhotoWallCountScheduling? = nil
    ) async throws -> Int {
        let excluded = excludedAssetIDs
        do {
            let total = try await PhotoWallTotalSelection.count(
                startingAt: offset, initialCount: initialCount, snapshot: snapshot,
                excluding: excluded, scheduling: scheduling
            ) { candidateOffset in
                if let reader {
                    return try await reader.photoWallCountingCandidates(in: snapshot.viewport, offset: candidateOffset)
                }
                return try await self.photoWallCandidates(in: snapshot.viewport, offset: candidateOffset, reader: reader)
            }
            await reader?.finishPhotoWallCounting()
            return total
        } catch {
            await reader?.finishPhotoWallCounting()
            throw error
        }
    }

    private func photoWallCandidates(
        in viewport: EarthViewport,
        offset: Int,
        reader: SQLiteTravelIndexStore?
    ) async throws -> PhotoQueryPage {
        let candidates: PhotoQueryPage
        if isUsingSampleData {
            let bounds = PhotoSpatialBounds(viewport: viewport)
            let matching = samplePhotos.filter { photo in
                photo.coordinate.latitude >= bounds.minimumLatitude && photo.coordinate.latitude <= bounds.maximumLatitude
                    && bounds.longitudeRanges.contains { $0.contains(photo.coordinate.longitude) }
            }.sorted {
                $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate
            }
            let start = min(max(0, offset), matching.count)
            let end = min(start + PhotoWallPageSelection.candidateLimit, matching.count)
            candidates = PhotoQueryPage(records: Array(matching[start..<end]), nextOffset: end < matching.count ? end : nil)
        } else if let store = reader ?? indexStore as? SQLiteTravelIndexStore {
            candidates = try await store.photoWallCandidates(in: viewport, offset: offset)
        } else {
            throw PhotoWallSelectionError.unavailableViewport
        }
        return candidates
    }

    func latestAssetID(for place: TravelPlace) async -> String? {
        guard place.photoCount > 0 else { return place.coverAssetID }
        if isUsingSampleData {
            return samplePhotos
                .filter { $0.placeID == place.id }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate > $1.creationDate
                }
                .first?.id ?? place.coverAssetID
        }
        return (try? await indexStore.latestAssetID(for: place.id)) ?? place.coverAssetID
    }

    func savedVisitCovers(for visits: [TravelPlace], keeping displayed: [String: String] = [:]) async -> [String: PhotoPreviewMetadata] {
        guard !visits.isEmpty, !isUsingSampleData, isSceneActive, let indexRevision = index?.contentRevision,
              let store = indexStore as? SQLiteTravelIndexStore else { return [:] }
        let session = librarySession
        let revision = coverRevision
        _ = scenicCovers // Install change observation before the first cache read.
        await coverInvalidation?.value
        let saved = try? await store.savedVisitCovers(for: visits.map(\.id), keeping: displayed, excluding: excludedAssetIDs)
        guard !Task.isCancelled, session == librarySession, revision == coverRevision,
              indexRevision == index?.contentRevision, isSceneActive else { return [:] }
        return (saved ?? [:]).filter { !excludedAssetIDs.contains($0.value.assetID) }
    }

    func isVisibleCover(_ assetID: String, in collection: PlaceCollection) async -> Bool {
        guard isSceneActive, !excludedAssetIDs.contains(assetID), let revision = index?.contentRevision else { return false }
        let places = Set(collection.placeIDs)
        if isUsingSampleData {
            return samplePhotos.contains { $0.id == assetID && $0.placeID.map(places.contains) == true }
        }
        guard let store = indexStore as? SQLiteTravelIndexStore else { return false }
        let session = librarySession
        let coverVersion = coverRevision
        await coverInvalidation?.value
        let member = try? await store.visibleJourneyCover(assetID, in: places)
        return member != nil && !Task.isCancelled && session == librarySession && isSceneActive
            && revision == index?.contentRevision && coverVersion == coverRevision && !excludedAssetIDs.contains(assetID)
    }

    func preferredVisitCover(for visit: TravelPlace, fallback: PhotoPreviewMetadata?) async -> PhotoPreviewMetadata? {
        await preferredCover(for: [visit], cityPoster: true, fallback: fallback)
    }

    func preferredCover(for collection: PlaceCollection, fallback: PhotoPreviewMetadata?) async -> PhotoPreviewMetadata? {
        if collection.representsSingleCity, let visit = collection.latestPlace {
            return await preferredVisitCover(for: visit, fallback: fallback)
        }
        return await preferredCover(for: collection.places, cityPoster: false, fallback: fallback)
    }

    private func preferredCover(for places: [TravelPlace], cityPoster: Bool,
                                fallback: PhotoPreviewMetadata?) async -> PhotoPreviewMetadata? {
        if isUsingSampleData { return fallback }
        guard isSceneActive, let index, let scenicCovers else { return nil }
        let generatedAt = index.generatedAt
        let filter = hidesTransitPhotos
        let minimum = minimumJourneyItems
        let revision = coverRevision
        await coverInvalidation?.value
        guard !Task.isCancelled, self.index?.generatedAt == generatedAt,
              minimum == minimumJourneyItems, filter == hidesTransitPhotos, revision == coverRevision else { return nil }
        do {
            let value = try await scenicCovers.select(for: places,
                revision: String(generatedAt.timeIntervalSince1970), fallback: fallback,
                priorityVisitID: cityPoster ? places.first?.id : nil,
                usesCityPoster: cityPoster, excluding: excludedAssetIDs)
            guard !Task.isCancelled, self.index?.generatedAt == generatedAt,
                  minimum == minimumJourneyItems, filter == hidesTransitPhotos, revision == coverRevision, isSceneActive,
                  value.map({ !excludedAssetIDs.contains($0.assetID) }) ?? true else { return nil }
            return value
        } catch { return nil }
    }

    func latestAssetIDs(for places: [TravelPlace]) async throws -> [String: String] {
        try await latestPhotoPreviews(for: places).mapValues(\.assetID)
    }

    func latestPhotoPreviews(for places: [TravelPlace]) async throws -> [String: PhotoPreviewMetadata] {
        let bounded = Array(places.prefix(15))
        if isUsingSampleData {
            return Dictionary(uniqueKeysWithValues: bounded.compactMap { place in
                sampleLatestByPlace[place.id].map { (place.id, $0) }
            })
        }
        return try await indexStore.latestPhotoPreviews(for: bounded.map(\.id))
    }

    func photoPage(for placeIDs: [String], offset: Int, limit: Int, reader: SQLiteTravelIndexStore? = nil) async throws -> PhotoQueryPage {
        try Task.checkCancellation()
        if isUsingSampleData {
            let ids = Set(placeIDs)
            let matching = samplePhotos.filter { $0.placeID.map(ids.contains) == true }.sorted {
                $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate
            }
            let start = min(max(0, offset), matching.count)
            let end = start + min(max(0, limit), 48, matching.count - start)
            return PhotoQueryPage(records: Array(matching[start..<end]),
                                  nextOffset: end < matching.count ? end : nil)
        }
        if let reader { return try await reader.photoPage(for: placeIDs, offset: offset, limit: limit) }
        return try await indexStore.photoPage(for: placeIDs, offset: offset, limit: limit)
    }

    func removedPhotoCount(for placeIDs: Set<String>, assetIDs: Set<String>, reader: SQLiteTravelIndexStore?) async throws -> Int {
        if isUsingSampleData {
            return samplePhotos.count { assetIDs.contains($0.id) && $0.placeID.map(placeIDs.contains) == true }
        }
        guard let store = reader ?? indexStore as? SQLiteTravelIndexStore else {
            throw PhotoWallSelectionError.changedCollection
        }
        return try await store.removedPhotoCount(for: placeIDs, assetIDs: assetIDs)
    }

    func makeEarthSlideshow(scope: EarthSlideshowScope, places: [TravelPlace],
                            viewport: PhotoViewportSnapshot? = nil, reader: SQLiteTravelIndexStore? = nil,
                            wallRecords: [PhotoAssetRecord] = [], collectionExclusions: Set<String> = [], reduceMotion: Bool,
                            cameraAction: @escaping EarthSlideshowCoordinator.CameraAction) -> EarthSlideshowCoordinator {
        let members = Set(places.map(\.id))
        let visibleWallRecords = Array(wallRecords.prefix(48))
        return EarthSlideshowCoordinator(scope: scope, places: places, excluded: excludedAssetIDs.union(collectionExclusions), analyticsLibrary: analyticsLibrary, reduceMotion: reduceMotion,
                                        makeSnapshot: {
            let frozen: SQLiteTravelIndexStore?
            if let reader { frozen = reader } else { frozen = try await self.makePhotoReadSnapshot() }
            let excluded = self.excludedAssetIDs.union(collectionExclusions)
            let source: any SlideshowPageReading
            if self.isUsingSampleData {
                let session = try SlideshowSnapshot(places: places, journeys: self.index?.journeys ?? [])
                try await session.appendBatch(self.samplePhotos.filter {
                    $0.placeID.map(members.contains) == true && !excluded.contains($0.id)
                })
                source = session
            } else {
                guard let frozen else { throw EarthSlideshowPlanError.unavailable }
                source = try await frozen.slideshowSnapshot(for: scope.kind == .library ? nil : places,
                                                            excluding: excluded)
            }
            if let viewport {
                return try await self.viewportSlideshowSnapshot(viewport, reader: frozen, source: source,
                    wallRecords: visibleWallRecords, excluding: excluded)
            }
            return source
        }, cameraAction: cameraAction)
    }

    private func viewportSlideshowSnapshot(_ viewport: PhotoViewportSnapshot, reader: SQLiteTravelIndexStore?,
                                           source: any SlideshowPageReading, wallRecords: [PhotoAssetRecord],
                                           excluding: Set<String>) async throws -> ViewportSlideshowSnapshot {
        guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        let candidates = source.visitIDs()
        var visibleVisits = Set<String>()

        func include(_ record: PhotoAssetRecord) {
            guard let visit = record.placeID, candidates.contains(visit), !visibleVisits.contains(visit),
                  !excluding.contains(record.id), viewport.containsForPhotoWall(record.coordinate) else { return }
            visibleVisits.insert(visit)
        }
        // Loaded wall records can establish visit membership, even when their
        // dates are too late for them to be this journey's opening photos.
        for photo in wallRecords { include(photo) }
        let operation = UUID()
        var offset = 0
        var slice = ContinuousClock.now
        do {
            while visibleVisits.count < candidates.count {
                try Task.checkCancellation()
                guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
                let page = try await mapReviewViewportCandidates(in: viewport, offset: offset, reader: reader,
                                                                  operationID: operation, placeIDs: nil)
                for photo in page.records {
                    if slice.duration(to: .now) >= .milliseconds(3) {
                        await Task.yield()
                        slice = .now
                        try Task.checkCancellation()
                        guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
                    }
                    include(photo)
                    if visibleVisits.count == candidates.count { break }
                }
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw EarthSlideshowPlanError.unavailable }
                offset = next
            }
        } catch {
            await reader?.finishPhotoWallCounting(operationID: operation)
            throw error
        }
        await reader?.finishPhotoWallCounting(operationID: operation)
        try Task.checkCancellation()
        guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        return .init(source: source, viewport: viewport, members: visibleVisits)
    }

    func assetIDs(for placeID: String, offset: Int, limit: Int) async -> [String] {
        if isUsingSampleData {
            return samplePhotos
                .filter { $0.placeID == placeID }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate < $1.creationDate
                }
                .dropFirst(max(0, offset))
                .prefix(max(0, limit))
                .map(\.id)
        }
        return (try? await indexStore.assetIDs(
            for: placeID,
            offset: offset,
            limit: limit
        )) ?? []
    }

    /// Only the requested, bounded set of place summaries is resolved. Individual
    /// photos never trigger independent geocoding of their raw coordinates.
    func resolvePlaceLabels(for placeIDs: [String]) async {
        guard !isUsingSampleData else { return }
        let generation = labelGeneration
        var seen = Set<String>()
        var lookupCount = 0
        for id in placeIDs where seen.insert(id).inserted {
            guard !Task.isCancelled, generation == labelGeneration else { return }
            guard let place = indexedPlaces[id],
                  !PlaceDisplayLabel(place: place).isComplete else { continue }
            if maintainsLibrary, let store = indexStore as? SQLiteTravelIndexStore {
                if (try? await store.isLabelTerminal(for: place)) == true {
                    placeLabelStates[id] = .unavailable
                    continue
                }
                if let retry = try? await store.labelRetryDate(for: place), retry > Date() {
                    placeLabelStates[id] = .unavailable
                    continue
                }
            }
            // A growing shelf includes its previously resolved places. Those
            // cache hits must not consume the budget for newly revealed places.
            guard lookupCount < 15 else { break }
            lookupCount += 1
            placeLabelStates[id] = .loading
            let resolution = await placeLabelResolver.resolution(for: place)
            let label = resolution.label
            guard generation == labelGeneration, !isUsingSampleData else { return }
            guard !Task.isCancelled else {
                if !placeLabelResolver.isResolving(place) { placeLabelStates[id] = nil }
                return
            }
            if let label { await applyResolvedPlaceLabels([id: label]) }
            if maintainsLibrary, !resolution.shouldRetry, label?.isComplete != true,
               let store = indexStore as? SQLiteTravelIndexStore {
                _ = try? await store.recordLabelAttempt(
                    place,
                    label: label,
                    attempts: 1,
                    nextRetryAt: nil,
                    terminal: true
                )
            }
            placeLabelStates[id] = indexedPlaces[id].map { PlaceDisplayLabel(place: $0).isComplete } == true ? nil : .unavailable
        }
        await persistPendingPlaceNames()
    }

    func applyResolvedPlaceLabels(_ labels: [String: PlaceDisplayLabel]) async {
        guard !isUsingSampleData, !labels.isEmpty, var updatedIndex = index else { return }
        var changedPlaces: [TravelPlace] = []

        for position in updatedIndex.places.indices {
            let placeID = updatedIndex.places[position].id
            guard let label = labels[placeID], label.hasCity || label.hasCountry else { continue }
            let existing = updatedIndex.places[position]
            let city = label.hasCity ? label.city : existing.name
            let country = label.hasCountry ? label.country : existing.country
            let regionCode = label.regionCode ?? existing.regionCode
            guard existing.name != city || existing.country != country || existing.regionCode != regionCode else { continue }
            updatedIndex.places[position].name = city
            updatedIndex.places[position].country = country
            updatedIndex.places[position].regionCode = regionCode
            updatedIndex.places[position].offlinePlaceID = label.offlinePlaceID
            changedPlaces.append(updatedIndex.places[position])
        }

        guard !changedPlaces.isEmpty else { return }
        index = updatedIndex
        for place in changedPlaces {
            pendingPlaceNameWrites[place.id] = place
            overview.updateLabel(place)
        }
        await persistPendingPlaceNames()
    }

    /// A wall can retain an older SQLite read version. Resolve that version's
    /// coordinate rather than accidentally attaching a newly moved place's city.
    func resolveSnapshotLabels(for ids: [String], places: PhotoWallPlaces) async -> [String: PlaceDisplayLabel] {
        let session = librarySession
        var output: [String: PlaceDisplayLabel] = [:]
        var seen = Set<String>()
        for id in ids.prefix(15) where seen.insert(id).inserted {
            guard !Task.isCancelled, librarySession == session else { break }
            guard let place = places[id] else { continue }
            if let current = indexedPlaces[id], current.coordinate == place.coordinate {
                await resolvePlaceLabels(for: [id])
                if let current = indexedPlaces[id], current.coordinate == place.coordinate {
                    output[id] = PlaceDisplayLabel(place: current)
                }
                continue
            }
            let stored = PlaceDisplayLabel(place: place)
            if stored.isComplete { output[id] = stored; continue }
            guard !isUsingSampleData else { continue }
            if let db = indexStore as? SQLiteTravelIndexStore {
                if (try? await db.isLabelTerminal(for: place)) == true { continue }
                if let retry = try? await db.labelRetryDate(for: place), retry > Date() { continue }
            }
            let resolution = await placeLabelResolver.resolution(for: place)
            guard let label = resolution.label, librarySession == session, !Task.isCancelled else {
                if !resolution.shouldRetry, let db = indexStore as? SQLiteTravelIndexStore {
                    _ = try? await db.recordLabelAttempt(
                        place,
                        label: nil,
                        attempts: 1,
                        nextRetryAt: nil,
                        terminal: true
                    )
                }
                continue
            }
            let merged = PlaceDisplayLabel(
                city: label.hasCity ? label.city : stored.city,
                country: label.hasCountry ? label.country : stored.country,
                regionCode: label.regionCode ?? stored.regionCode,
                source: label.source ?? stored.source,
                sourceVersion: label.sourceVersion ?? stored.sourceVersion,
                offlinePlaceID: label.offlinePlaceID ?? stored.offlinePlaceID
            )
            if let db = indexStore as? SQLiteTravelIndexStore {
                _ = try? await db.recordLabelAttempt(place, label: merged, attempts: 1,
                                                     nextRetryAt: merged.isComplete || !resolution.shouldRetry ? nil : Date().addingTimeInterval(3600),
                                                     terminal: !merged.isComplete && !resolution.shouldRetry)
            }
            output[id] = merged
        }
        return output
    }

    private func persistPendingPlaceNames() async {
        guard !pendingPlaceNameWrites.isEmpty, !isUsingSampleData else { return }
        let pending = pendingPlaceNameWrites
        let generation = labelGeneration
        do {
            try await indexStore.updatePlaceNames(Array(pending.values))
            guard generation == labelGeneration else { return }
            for (id, place) in pending where pendingPlaceNameWrites[id] == place {
                pendingPlaceNameWrites[id] = nil
            }
            PlaceLabelDiagnostics.record("persisted count=\(pending.count)")
        } catch {
            // Keep successful results for the next small write; never log SQL or data.
            PlaceLabelDiagnostics.record("persistenceFailed count=\(pending.count)")
        }
    }

    private func resetPlaceLabelWork() {
        labelGeneration = UUID()
        placeLabelResolver.reset()
        placeLabelStates = [:]
        pendingPlaceNameWrites = [:]
    }

    func select(placeID: String) {
        selectedPlaceID = placeID
        preferences.lastSelectedPlaceID = placeID
        let value = preferences
        Task { await preferencesStore.save(value) }
    }

    func moveSelection(by offset: Int) {
        guard let places = index?.places, !places.isEmpty else { return }
        let current = places.firstIndex { $0.id == selectedPlaceID } ?? 0
        let destination = (current + offset + places.count) % places.count
        select(placeID: places[destination].id)
    }

    private func scan(presentsProgress: Bool = true) async {
        guard privateLibraryAllowed else { return }
        if photoLibrary is any PhotoLibraryUpdating, let store = indexStore as? SQLiteTravelIndexStore {
            installPreparation()
            if presentsProgress {
                phase = .scanning
                isPreparationPresented = true
            }
            keepsPreparationVisible = false
            isInitialLibraryReady = false
            let session = librarySession
            // A first authorization bypassed start()'s already-authorized restore.
            // Match the store's read policy before it publishes its first index.
            let hidesTransit = await store.transitFilteringIsEnabled()
            guard session == librarySession else { return }
            hidesTransitPhotos = hidesTransit
            await preparation?.request(index == nil ? .initial : .rebuild)
            return
        }
        resetPlaceLabelWork()
        phase = .scanning
        do {
            let scan = try await photoLibrary.scanLocatedPhotos()
            let snapshot = clusterer.makeIndex(
                records: scan.locatedPhotos,
                sourcePhotoCount: scan.sourcePhotoCount
            )
            guard !snapshot.index.places.isEmpty else {
                try await indexStore.save(snapshot)
                index = snapshot.index
                phase = .empty
                return
            }
            try await indexStore.save(snapshot)
            samplePhotos = []
            samplePhotoIndex = nil
            apply(try await indexStore.load() ?? snapshot.index, usingSampleData: false)
        } catch is CancellationError {
            phase = .welcome
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ newIndex: TravelIndex, usingSampleData: Bool) {
        resetPlaceLabelWork()
        scenicCovers?.invalidate()
        coverRevision += 1
        index = newIndex
        isUsingSampleData = usingSampleData
        selectedPlaceID = newIndex.place(id: preferences.lastSelectedPlaceID)?.id
            ?? newIndex.places.first?.id
        phase = newIndex.locatedPhotoCount == 0 ? .empty : .globe
        refreshTopShelf()
    }

    func showPreparation() {
        isInitialLibraryReady = false
        retainPreparationFocus()
        isPreparationPresented = true
        if index == nil { phase = .scanning }
    }

    func closePreparation() {
        preparationHandoffTask?.cancel()
        preparationHandoffTask = nil
        isPreparationPresented = false
        phase = index.map { $0.locatedPhotoCount == 0 ? .empty : .globe } ?? .welcome
    }

    /// A user inspecting controls owns the scan page; never time away its Focus.
    func retainPreparationFocus() {
        keepsPreparationVisible = true
        preparationHandoffTask?.cancel()
        preparationHandoffTask = nil
    }

    func updateLibrary(_ mode: LibraryPreparationMode = .update) async {
        if isUsingSampleData { await requestAccessAndScan(); return }
        ProductAnalytics.shared.capture(.preparationAction, value: mode.rawValue)
        installPreparation()
        showPreparation()
        if let preparation { await preparation.request(mode) }
        else { await scan() }
    }

    func pausePreparation() async {
        ProductAnalytics.shared.capture(.preparationAction, value: "pause")
        retainPreparationFocus()
        await preparation?.pause(userInitiated: true)
    }
    func resumePreparation() async {
        ProductAnalytics.shared.capture(.preparationAction, value: "resume")
        await preparation?.request(preparationProgress.needsMetadata ? .update : .labels)
    }

    func setSceneActive(_ active: Bool) async {
        guard privateLibraryAllowed else { return }
        isSceneActive = active
#if DEBUG
        if active { shelfQA.observe(self, store: indexStore as? SQLiteTravelIndexStore) }
        else { shelfQA.pause() }
#endif
        if !active {
            overview.setActive(false)
            topShelf.suspendSelection()
            scenicCovers?.invalidate()
            preparationHandoffTask?.cancel()
            preparationHandoffTask = nil
        }
        if active, !isUsingSampleData, !isRequestingPhotoAccess {
            let access = await photoLibrary.authorizationStatus()
            guard access == .authorized || access == .limited else { await loseLibraryAccess(access); return }
            refreshTopShelf()
            if phase == .denied {
                hasStarted = false
                await start()
            }
        }
        await preparation?.setActive(active)
        if active { scheduleInitialPreparationHandoff() }
    }

    private func scheduleInitialPreparationHandoff() {
        guard isSceneActive, isInitialLibraryReady, !keepsPreparationVisible,
              isPreparationPresented, phase == .scanning,
              let index, index.locatedPhotoCount > 0 else { return }
        preparationHandoffTask?.cancel()
        let session = librarySession
        preparationHandoffTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            guard let self, self.librarySession == session, self.isSceneActive,
                  self.isInitialLibraryReady, !self.keepsPreparationVisible,
                  self.isPreparationPresented, self.phase == .scanning else { return }
            self.closePreparation()
        }
    }

    func makePhotoReadSnapshot() async throws -> SQLiteTravelIndexStore? {
        guard !isUsingSampleData, let store = indexStore as? SQLiteTravelIndexStore else { return nil }
        return try await store.photoReadSnapshot()
    }

    func mapReviewViewportCandidates(in snapshot: PhotoViewportSnapshot, offset: Int,
                                     reader: SQLiteTravelIndexStore?, operationID: UUID,
                                     placeIDs: Set<String>?) async throws -> PhotoQueryPage {
        if let reader {
            return try await reader.photoWallCountingCandidates(in: snapshot.viewport, offset: offset,
                                                              operationID: operationID, placeIDs: placeIDs)
        }
        let page = try await photoWallCandidates(in: snapshot.viewport, offset: offset, reader: nil)
        guard let placeIDs else { return page }
        return .init(records: page.records.filter { $0.placeID.map(placeIDs.contains) == true }, nextOffset: page.nextOffset)
    }

    func cityLanding(for city: PlaceCollection, reference: GeoCoordinate) async throws -> GlobeCameraState? {
        let ids = city.placeIDs
        if isUsingSampleData {
            let members = Set(ids)
            let coordinates = samplePhotos.lazy.filter {
                $0.placeID.map(members.contains) == true && !self.excludedAssetIDs.contains($0.id)
            }.map(\.coordinate)
            return CityLandingFrame.demo(coordinates: Set(coordinates), reference: reference.longitude)?.camera
        }
        guard let store = indexStore as? SQLiteTravelIndexStore else { return nil }
        return try await store.cityLandingFrame(placeIDs: ids, reference: reference.longitude, excluding: excludedAssetIDs)?.camera
    }

    func mapReviewClusters(placeID: String, grid: MapReviewGrid, reader: SQLiteTravelIndexStore?) async throws -> [MapReviewCluster] {
        try await mapReviewClusters(placeIDs: [placeID], grid: grid, reader: reader)
    }

    func mapReviewClusters(placeIDs: [String], grid: MapReviewGrid, reader: SQLiteTravelIndexStore?) async throws -> [MapReviewCluster] {
        if isUsingSampleData {
            let membership = Set(placeIDs)
            return MapReviewCluster.demo(records: samplePhotos.filter {
                $0.placeID.map(membership.contains) == true && !excludedAssetIDs.contains($0.id)
            }, grid: grid)
        }
        guard let store = reader ?? (indexStore as? SQLiteTravelIndexStore) else { throw TravelIndexStoreError.invalidSnapshot }
        return try await store.mapReviewClusters(placeIDs: placeIDs, grid: grid, excluding: excludedAssetIDs)
    }

    func mapReviewPage(placeID: String, selection: MapReviewSelection?, offset: Int, reader: SQLiteTravelIndexStore?) async throws -> PhotoQueryPage {
        if isUsingSampleData {
            let matching = samplePhotos.filter {
                $0.placeID == placeID && !excludedAssetIDs.contains($0.id) && (selection?.contains($0.coordinate) ?? true)
            }.sorted { $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate }
            let start = min(max(0, offset), matching.count)
            let end = min(start + 48, matching.count)
            return PhotoQueryPage(records: Array(matching[start..<end]), nextOffset: end < matching.count ? end : nil)
        }
        guard let store = reader ?? (indexStore as? SQLiteTravelIndexStore) else { throw TravelIndexStoreError.invalidSnapshot }
        return try await store.mapReviewPage(placeID: placeID, selection: selection, offset: offset, excluding: excludedAssetIDs)
    }

    private func installPreparation() {
        guard privateLibraryAllowed, preparation == nil, let library = photoLibrary as? any PhotoLibraryUpdating,
              let store = indexStore as? SQLiteTravelIndexStore else { return }
        maintainsLibrary = true
        librarySession = UUID()
        let session = librarySession
        preparation = LibraryPreparationCoordinator(library: library, store: store, resolver: placeLabelResolver,
            configuration: clusterer.configuration,
            currentIndex: { [weak self] in self?.index },
            onIndex: { [weak self] index in
                guard self?.librarySession == session else { return }; self?.applyPreparedIndex(index)
            },
            onUnchanged: { [weak self] tokenChanged in
                guard let self, self.librarySession == session else { return }
                self.lastLibraryCheck = Date()
                if tokenChanged { self.refreshTopShelf() }
            },
            onLabel: { [weak self] place in
                guard self?.librarySession == session else { return }; self?.receivePersistedLabel(place)
            },
            onProgress: { [weak self] progress in
                guard let self, !self.isUsingSampleData, self.librarySession == session else { return }
                if progress.phase == .failed, self.preparationProgress.phase != .failed {
                    ProductAnalytics.shared.capture(.preparationFailed, value: progress.mode.rawValue)
                }
                self.preparationProgress = progress
                // Metadata readiness owns the initial handoff. Place-name
                // retries may continue for hours without retaining onboarding.
            }, onDiscovery: { [weak self] places in
                guard self?.librarySession == session else { return }; self?.receiveScanDiscovery(places)
            },
            onRemoved: { [weak self] ids in
                guard let self, self.librarySession == session else { return }
                self.excludedAssetIDs.formUnion(ids)
                if self.photoLibrary is PhotoKitLibrary { self.topShelf.removeCovers(in: ids) }
                PhotoAssetChangeNotice.post(changed: [], removed: ids)
            }, onAvailable: { [weak self] ids, invalidateImages in
                guard let self, self.librarySession == session else { return }
                if !self.excludedAssetIDs.isDisjoint(with: ids) { self.excludedAssetIDs.subtract(ids) }
                if invalidateImages { PhotoAssetChangeNotice.post(changed: ids, removed: []) }
            },
            onScopeChanged: { [weak self] in
                guard self?.librarySession == session else { return }
                self?.invalidatePublishedScope()
            },
            onUnavailable: { [weak self] in
                guard let self, self.librarySession == session else { return }
                let status = await self.photoLibrary.authorizationStatus()
                if status != .authorized && status != .limited { await self.loseLibraryAccess(status) }
                else if self.usesLivePhotoLibrary { self.invalidatePublishedScope() }
            })
    }

    private func applyPreparedIndex(_ value: TravelIndex) {
        // A metadata job may finish while Settings switches the read policy.
        // Never let an earlier policy's summary overwrite the current globe.
        if value.transitFilteringApplied != hidesTransitPhotos, let store = indexStore as? SQLiteTravelIndexStore {
            let session = librarySession
            Task { [weak self] in
                guard let latest = try? await store.load(), let self,
                      self.librarySession == session,
                      latest.transitFilteringApplied == self.hidesTransitPhotos else { return }
                self.applyPreparedIndex(latest)
            }
            return
        }
        let firstCommit = index == nil && phase == .scanning
        if firstCommit {
            ProductAnalytics.shared.capture(.firstIndexReady, value: value.locatedPhotoCount == 0 ? "empty" : "ready")
        }
        if index?.contentRevision != value.contentRevision {
            scenicCovers?.invalidate()
            coverRevision += 1
        }
        resetPlaceLabelWork()
        index = value
        samplePhotos = []; samplePhotoIndex = nil; isUsingSampleData = false
        if value.place(id: selectedPlaceID) == nil { selectedPlaceID = value.places.last?.id }
        lastLibraryCheck = Date()
        if value.locatedPhotoCount == 0 {
            preparationHandoffTask?.cancel()
            isPreparationPresented = false
            phase = .empty
        } else if firstCommit {
            isInitialLibraryReady = true
            scheduleInitialPreparationHandoff()
        } else if phase != .scanning { phase = .globe }
        refreshTopShelf()
    }

    private func receivePersistedLabel(_ place: TravelPlace) {
        guard var index, let position = index.places.firstIndex(where: { $0.id == place.id && $0.coordinate == place.coordinate }) else { return }
        index.places[position].name = place.name
        index.places[position].country = place.country
        index.places[position].regionCode = place.regionCode
        index.places[position].offlinePlaceID = place.offlinePlaceID
        self.index = index
        overview.updateLabel(place)
        placeLabelStates[place.id] = PlaceDisplayLabel(place: place).isComplete ? nil : .unavailable
        recentlyPreparedPlace = place
        refreshTopShelf()
    }

    private func receiveScanDiscovery(_ places: [TravelPlace]) {
        for place in places { scanPoints[place.id] = place }
        if scanPoints.count > 360 {
            scanPoints = Dictionary(uniqueKeysWithValues: MapPlaceLOD.representatives(from: Array(scanPoints.values), limit: 180).map { ($0.id, $0) })
        }
        guard Date().timeIntervalSince(lastDiscoveryPublish) >= 0.5 || places.count == 1 else { return }
        lastDiscoveryPublish = Date()
        let representatives = MapPlaceLOD.representatives(from: Array(scanPoints.values), limit: 180)
        scanDiscovery = ScanDiscovery(revision: scanDiscovery.revision + 1, places: representatives)
    }

    func closeLibrarySession() {
        privateLibraryAllowed = false
        scanScope = nil
        librarySession = UUID()
        isSceneActive = false
        overview.setActive(false)
        preparationHandoffTask?.cancel()
        coverInvalidation?.cancel()
        scenicCovers?.invalidate()
        resetPlaceLabelWork()
        if photoLibrary is PhotoKitLibrary && !isUsingSampleData { topShelf.clear() }
        let old = preparation
        preparation = nil
        Task { await old?.stop() }
    }

    private func loseLibraryAccess(_ access: PhotoLibraryAccess) async {
        withdrawTopShelf()
        scanScope = nil
        if case .journey = pendingTopShelfRoute { pendingTopShelfRoute = nil }
        preparationHandoffTask?.cancel()
        preparationHandoffTask = nil
        isInitialLibraryReady = false
        keepsPreparationVisible = false
        SharedPhotoImageScheduler.shared.invalidate(nil)
        librarySession = UUID()
        let oldPreparation = preparation
        preparation = nil
        resetPlaceLabelWork()
        index = nil
        scanPoints = [:]
        scanDiscovery = ScanDiscovery(revision: scanDiscovery.revision + 1, places: [])
        isPreparationPresented = false
        // Foreground checks also run before the first permission request. That
        // state belongs to onboarding, while revoked/restricted access still
        // removes private content and shows the permission recovery page.
        phase = access == .notDetermined ? .welcome : .denied
        // This callback can originate inside the worker itself. Never await
        // that same worker here; hide private UI immediately, then drain it.
        let store = indexStore as? SQLiteTravelIndexStore
        Task {
            await oldPreparation?.stop()
            try? await store?.invalidateLibraryBaseline()
        }
    }
}

extension AppModel {
    func anniversaryDays(on today: Date, calendar: Calendar) async throws -> [AnniversaryDay] {
        guard let earliest = index?.places.map(\.startDate).min() else { return [] }
        let ranges = AnniversaryDay.pastDays(on: today, since: earliest, calendar: calendar)
        if isUsingSampleData {
            return ranges.compactMap { range in
                let photos = anniversarySamplePhotos(in: range)
                return photos.first.map { AnniversaryDay(range: range, cover: $0, count: photos.count) }
            }
        }
        guard let store = indexStore as? SQLiteTravelIndexStore else { throw TravelIndexStoreError.invalidSnapshot }
        return try await store.anniversaryDays(in: ranges, excluding: excludedAssetIDs)
    }

    func anniversaryPage(in range: Range<Date>, reader: SQLiteTravelIndexStore?, offset: Int,
                         excluding: Set<String>) async throws -> PhotoQueryPage {
        if let reader { return try await reader.anniversaryPage(in: range, excluding: excluding, offset: offset) }
        guard isUsingSampleData else { throw TravelIndexStoreError.invalidSnapshot }
        let photos = anniversarySamplePhotos(in: range).filter { !excluding.contains($0.id) }
        let size = PhotoWallPageSelection.pageSize
        return .init(records: Array(photos.dropFirst(offset).prefix(size)), nextOffset: offset + size < photos.count ? offset + size : nil)
    }

    private func anniversarySamplePhotos(in range: Range<Date>) -> [PhotoAssetRecord] {
        samplePhotos.filter { range.contains($0.creationDate) && !excludedAssetIDs.contains($0.id) }
            .sorted { $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate }
    }
}
