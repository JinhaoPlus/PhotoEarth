import SwiftUI
import UIKit

struct GlobeView: View {
    private enum Destination: String, Hashable {
        case home, recent, countries, anniversary, settings
    }
    private enum Layer: Equatable {
        case overview
        case explore
        case photoWall
    }

    @ObservedObject var model: AppModel
    var locationDestination: PhotoGlobeDestination?
    var closeLocationExploration: (() -> Void)?
    @State private var experience = GlobeExperienceModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isGlobeFocused: Bool

    @State private var layer: Layer = .overview
    @State private var isOverviewInteractive = true
    @State private var pendingCityEntry: TravelPlace?
    @State private var focusedSatelliteCity: GeoCoordinate?
    @State private var wallFocusID: String?
    @State private var showsControls = false
    @State private var wallTask: Task<Void, Never>?
    @State private var wallCountTask: Task<Void, Never>?
    @State private var showsControlHint = true
    @State private var userLocation: GeoCoordinate?
    @State private var isAwaitingUserLocation = true
    @State private var hasAnchoredUserLocation = false
    @State private var mapContentRevision = 0
    @State private var wallSnapshot: PhotoViewportSnapshot?
    @State private var wallRecords: [PhotoAssetRecord] = []
    @State private var wallRecordIDs = Set<String>()
    @State private var wallCountScheduling = PhotoWallCountScheduling()
    @State private var wallNextOffset: Int?
    @State private var isLoadingWall = false
    @State private var wallError: String?
    @State private var wallGeneration = UUID()
    @State private var selectedPhoto: PhotoAssetRecord?
    @State private var selectedPhotoPreview: UIImage?
    @State private var destination: Destination = .home
    @State private var presentsDirectHome = false
    @State private var anniversaryDay: AnniversaryDay?
    private var showsSidebarContent: Bool {
        layer == .overview && navigationVisible && collection == nil && anniversaryDay == nil && slideshow == nil
    }

    @State private var collection: PlaceCollection?
    @State private var wallReader: SQLiteTravelIndexStore?
    @State private var wallHasReadSession = false
    @State private var frozenWallPlaces = PhotoWallPlaces()
    @State private var collectionWallSession: CollectionPhotoWallSession?
    private var wallPlaces: PhotoWallPlaces { collectionWallSession?.membership?.places ?? frozenWallPlaces }
    private var wallPlaceSnapshot: [TravelPlace] { wallPlaces.places }
    private var activeWallRecords: [PhotoAssetRecord] { collectionWallSession?.records ?? wallRecords }
    private var activeWallNextOffset: Int? { collectionWallSession == nil ? wallNextOffset : collectionWallSession?.nextOffset }
    private var activeWallIsLoading: Bool { collectionWallSession?.isLoading ?? isLoadingWall }
    private var activeWallError: String? { collectionWallSession == nil ? wallError : collectionWallSession?.pagingError }
    @State private var wallResolvedLabels: [String: PlaceDisplayLabel] = [:]
    @State private var exploreCity: PlaceCollection?
    @State private var wallCollection: PlaceCollection?
    @State private var wallTotalPhotoCount: Int?
    @State private var mapReviewOrigin: MapReviewOrigin?
    @State private var slideshow: EarthSlideshowCoordinator?
    @State private var slideshowReturnCamera: GlobeCameraState?
    @State private var scanDirector = ScanCameraDirector()
    @State private var followsScan = true
    @State private var cameraBeforeScan: GlobeCameraState?
    @State private var scanTarget: TravelPlace?
    @State private var scanSessionStart = Date()
    @State private var hasPresentedLibrary = false
    @State private var isInitialGlobeReady = false
    @State private var didPrepareOverview = false
    @State private var overviewReturnCamera: GlobeCameraState?
    @AppStorage("photoEarth.showsGlobeHints") private var showsGlobeHints = true
    @AppStorage("photoEarth.waitsForInitialGlobeRender") private var waitsForInitialGlobeRenderExperiment = false

    private var places: [TravelPlace] { model.index?.places ?? [] }
    private var navigationVisible: Bool {
        locationDestination == nil && model.phase == .globe && !model.isPreparationPresented
    }
    private var showsHome: Bool {
        layer == .overview && destination == .home && navigationVisible && collection == nil && slideshow == nil
    }
    private var scanCameraActive: Bool {
        locationDestination == nil && !model.isExploringPublicGlobe
            && model.isPreparationPresented && model.preparationProgress.phase.isWorking
            && followsScan && !reduceMotion && scenePhase == .active
    }
    private var waitsForInitialGlobeRender: Bool {
        waitsForInitialGlobeRenderExperiment && !isInitialGlobeReady
            && navigationVisible && !model.isPreparationPresented && !isAwaitingUserLocation
    }
    private var showsInitialGlobeCover: Bool {
        waitsForInitialGlobeRenderExperiment && !isInitialGlobeReady
            && navigationVisible && !model.isPreparationPresented
            && (destination == .home || layer != .overview)
    }
    private var homeFrameContext: HomeGlobeFrame.Context {
        guard scenePhase == .active, navigationVisible, !model.isExploringPublicGlobe,
              let revision = model.index?.contentRevision else { return .inactive }
        let isHome = destination == .home && layer == .overview && collection == nil && slideshow == nil
        return isHome ? .home(revision) : .away(revision)
    }

    private var renderedPlaces: [TravelPlace] {
        if model.isExploringPublicGlobe { return [] }
        if let locationDestination { return places + [locationDestination.marker] }
        guard model.isPreparationPresented else { return places }
        return MapPlaceLOD.representatives(from: places + model.scanDiscovery.places + [scanTarget].compactMap { $0 },
                                          limit: 180, preferredPlaceID: scanTarget?.id)
    }
    private var fallbackCenter: GeoCoordinate {
        model.overview.nearestRecentCoordinate
            ?? places.first?.coordinate
            ?? GeoCoordinate(latitude: 24, longitude: 18)
    }
    private func wallLabel(_ id: String) -> PlaceDisplayLabel? {
        guard let place = wallPlaces[id] else { return nil }
        let current = model.indexedPlaces[id]
        let matching = current?.coordinate == place.coordinate ? current : nil
        if let matching {
            let label = PlaceDisplayLabel(place: matching)
            if label.isComplete { return label }
        }
        return wallResolvedLabels[id] ?? PlaceDisplayLabel(place: matching ?? place)
    }

    private var scene: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                SpaceBackdrop(quality: .minimal)

                GlobeMapLayer(
                    experience: experience,
                    places: renderedPlaces,
                    contentRevision: mapContentRevision,
                    exploresByScale: layer != .overview,
                    homeFrameContext: homeFrameContext,
                    allowsHomeDrift: !reduceMotion && !showsInitialGlobeCover && isOverviewInteractive,
                    focusedSatelliteCity: layer == .overview && scenePhase == .active && destination == .home
                        && navigationVisible && collection == nil && slideshow == nil ? focusedSatelliteCity : nil,
                    preferredPlaceID: locationDestination == nil ? nil : PhotoGlobeDestination.markerID,
                    size: proxy.size,
                    showsUserLocation: layer == .overview && destination == .home && model.usesLivePhotoLibrary && navigationVisible,
                    waitsForInitialRender: waitsForInitialGlobeRender,
                    onUserLocationUpdate: receiveUserLocation,
                    onInitialRenderReady: revealInitialGlobe
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .transaction { $0.animation = nil }
                .ignoresSafeArea()

                cinematicMask

                if showsInitialGlobeCover {
                    InitialGlobeLoadingCover()
                        .transition(.opacity)
                }

                if locationDestination == nil && (model.phase == .globe || (hasPresentedLibrary && model.isPreparationPresented)) {
                    libraryNavigation
                        .opacity(showsSidebarContent ? 1 : 0)
                        .disabled(!isOverviewInteractive || !showsSidebarContent)
                        .allowsHitTesting(isOverviewInteractive && showsSidebarContent)
                        .accessibilityHidden(!showsSidebarContent)
                        .zIndex(1)
                }

                if locationDestination == nil && model.isPreparationPresented && !model.isExploringPublicGlobe {
                    LibraryPreparationView(model: model, followsDiscoveries: $followsScan)
                        .transition(.opacity).zIndex(6)
                }

                if layer == .explore {
                    if !showsControls {
                        directManipulationSurface
                            .zIndex(1)
                    }

                    // The window-level press bridge is not part of the
                    // accessible, focusable globe surface.
                    RemoteSelectPressCapture(
                        isEnabled: !showsControls,
                        acceptsPresses: { experience.acceptsUIKitSelectPresses },
                        onPressChanged: { experience.receiveSelectPress($0, source: .uiKit) },
                        onCancelled: { experience.cancelSelectPresses(source: .uiKit) }
                    )
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                    // Touch has one owner across globe and zoom controls. It
                    // stays independent of the focused buttons and of optional
                    // Game Controller touch capabilities.
                    RemoteTouchPanCapture(
                        isEnabled: scenePhase == .active,
                        acceptsTouches: { experience.acceptsTouchPan },
                        onContactChanged: { experience.receiveTouchContact($0) },
                        onPan: { experience.applyTouchPan(horizontalDelta: $0, verticalDelta: $1) },
                        onPressClaimed: experience.claimTouchForPhysicalPress,
                        onAvailabilityChanged: experience.setTouchPanAvailable
                    )
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                    GlobeExploreChrome(experience: experience, showsControlHint: showsControlHint && showsGlobeHints && !model.isExploringPublicGlobe, cityTitle: exploreCity?.title)
                        .transition(.opacity)
                        .opacity(showsControls ? 0 : 1)
                        .accessibilityHidden(showsControls)
                        .zIndex(2)
                }

                if layer == .photoWall {
                    ViewportPhotoWall(
                        records: activeWallRecords,
                        isLoading: activeWallIsLoading,
                        hasMore: activeWallNextOffset != nil,
                        placeLabel: wallLabel,
                        selectPhoto: openPhoto,
                        loadMore: loadNextWallPage,
                        close: closePhotoWall,
                        isActive: selectedPhoto == nil && slideshow == nil && mapReviewOrigin == nil,
                        selectedPhotoID: $wallFocusID,
                        errorMessage: activeWallError,
                        title: wallCollection?.title
                            ?? AppLocalization.string("memory_strip.title", defaultValue: "Photos in this view"),
                        canRetry: activeWallNextOffset != nil,
                        emptyHint: wallCollection == nil
                            ? AppLocalization.string("wall.viewport.empty_message", defaultValue: "Return to the globe, turn toward a glowing place, or widen the view.")
                            : nil,
                        totalPhotoCount: collectionWallSession == nil ? wallTotalPhotoCount : collectionWallSession?.totalPhotoCount,
                        countErrorMessage: collectionWallSession?.countErrorMessage,
                        retryPhotoCount: { collectionWallSession?.refreshCount(app: model) },
                        showsPhotoPlaceNames: !(wallCollection?.representsSingleCity ?? false),
                        startSlideshow: startWallSlideshow,
                        openMapReview: wallMapReviewAction,
                        canOpenMapReview: collectionWallSession?.membership?.reviewOrigin != nil && wallSnapshot != nil,
                        labelStates: model.placeLabelStates,
                        resolvePlaceLabels: resolveWallLabels,
                        onInteraction: wallCountScheduling.deferForInteraction, analyticsLibrary: model.analyticsLibrary
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .opacity(slideshow == nil && mapReviewOrigin == nil ? 1 : 0)
                    .disabled(selectedPhoto != nil || slideshow != nil || mapReviewOrigin != nil)
                    .accessibilityHidden(selectedPhoto != nil || slideshow != nil || mapReviewOrigin != nil)
                    .zIndex(3)
                }

                if let mapReviewOrigin {
                    MapReviewView(app: model, origin: mapReviewOrigin, reader: collectionWallSession?.membership?.reader,
                                  allowsPhotoLocation: locationDestination == nil, controlGlobe: controlSlideshowGlobe,
                                  restoreGlobe: restoreGlobeAfterSlideshow, close: closeWallMapReview)
                        .zIndex(6)
                }

                if showsControls {
                    GlobeControlPanel(experience: experience, zoomIn: experience.zoomIn,
                                      zoomOut: experience.zoomOut, close: closeControls,
                                      cityTitle: exploreCity?.title, useCurrentView: useCurrentView)
                        .transition(reduceMotion ? .opacity : .offset(y: 24).combined(with: .opacity))
                        .zIndex(5)
                }

                if let selectedPhoto, slideshow == nil {
                    PhotoDetailView(
                        record: selectedPhoto,
                        placeLabel: selectedPhoto.placeID.flatMap(wallLabel),
                        initialImage: selectedPhotoPreview,
                        resolvePlaceLabel: { await resolveWallLabels([selectedPhoto.placeID].compactMap { $0 }) },
                        records: activeWallRecords,
                        hasMorePhotos: activeWallNextOffset != nil,
                        isLoadingMorePhotos: activeWallIsLoading,
                        pagingError: activeWallError,
                        loadMorePhotos: loadNextWallPage,
                        selectRecord: selectDetailRecord,
                        locationLibrary: locationDestination == nil ? model : nil,
                        close: closePhotoDetail
                    )
                    .transition(.opacity)
                    .zIndex(4)
                }

                if let slideshow {
                    EarthSlideshowView(coordinator: slideshow) {
                        finishWallSlideshow()
                    }
                    .zIndex(7)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    var body: some View {
        scene
        .fullScreenCover(item: $anniversaryDay) { day in
            AnniversaryWall(model: model, day: day, controlGlobe: controlSlideshowGlobe, restoreGlobe: restoreGlobeAfterSlideshow) {
                anniversaryDay = nil
            }
            .presentationBackground(.clear)
        }
        .fullScreenCover(item: $collection, onDismiss: finishCollectionDismissal) { selected in
            CollectionPhotoWall(model: model, collection: selected, controlGlobe: { target, reducedMotion in
                controlSlideshowGlobe(target, reducedMotion)
            }, restoreGlobe: restoreGlobeAfterSlideshow) {
                if destination == .home, layer == .overview { restoreHomeCamera() }
                collection = nil
            }
                .id(selected.id)
                .presentationBackground(.clear)
        }
        .onChange(of: model.pendingTopShelfRoute, initial: true) { _, _ in openPendingShelfAction() }
        .onChange(of: showsHome && scenePhase == .active && !showsInitialGlobeCover && model.scanScope == nil
                  ? model.analyticsLibrary : nil, initial: true) { _, mode in
            if let mode { ProductAnalytics.shared.capture(.homePresented, context: .init(library: mode)) }
        }
        .onChange(of: navigationVisible) { _, visible in
            if visible { openPendingShelfAction() } else { anniversaryDay = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.38), value: layer)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedPhoto?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsControls)
        .onAppear(perform: prepareOverview)
        .onDisappear {
            wallGeneration = UUID()
            wallTask?.cancel()
            wallCountTask?.cancel()
            collectionWallSession?.cancel()
            slideshow?.cancel()
            experience.deactivate()
        }
        .onChange(of: scenePhase) { _, phase in
            experience.setSceneActive(phase == .active)
            if phase != .active {
                selectedPhotoPreview = nil
                slideshow?.suspend()
                model.overview.suspendForBackground()
            }
        }
        .onChange(of: model.index?.contentRevision) { _, _ in
            refreshMapContent()
            experience.refreshPhotos() // Drop candidates captured under the previous filter policy.
            // Metadata updates never relocate the user's browsing camera.
        }
        .onChange(of: model.isInitialLibraryReady) { _, ready in
            if ready && !hasPresentedLibrary && destination == .home {
                presentsDirectHome = true
            }
        }
        .onChange(of: model.isPreparationPresented) { _, presented in
            guard locationDestination == nil, !model.isExploringPublicGlobe else { return }
            if presented {
                cameraBeforeScan = model.index == nil ? nil : experience.displayedCamera
                experience.pauseDirectManipulation()
                scanSessionStart = Date()
                scanDirector.begin(at: scanSessionStart.timeIntervalSinceReferenceDate, baseline: model.scanDiscovery.places)
                followsScan = !reduceMotion
                scanTarget = nil
                refreshMapContent()
            } else {
                experience.pauseDirectManipulation()
                let camera = cameraBeforeScan ?? GlobeCameraState(center: userLocation ?? fallbackCenter, distance: GlobeCameraState.orbitalDistance)
                experience.transitionCamera(to: camera.center, distance: camera.distance,
                                            animated: cameraBeforeScan == nil && !reduceMotion, overviewFraming: 1, duration: 4)
                if model.index != nil { hasPresentedLibrary = true }
                cameraBeforeScan = nil
                scanTarget = nil
                refreshMapContent()
            }
        }
        .onChange(of: followsScan) { _, follows in
            if !follows { experience.pauseDirectManipulation() }
            else {
                scanSessionStart = Date()
                scanDirector.begin(at: scanSessionStart.timeIntervalSinceReferenceDate, baseline: model.scanDiscovery.places)
            }
        }
        .onChange(of: model.isPreparationPresented ? model.scanDiscovery.revision : 0) { _, _ in
            if model.isPreparationPresented { refreshMapContent() }
        }
        .onChange(of: model.excludedAssetIDs) { previous, removed in
            if !removed.isSubset(of: previous) { anniversaryDay = nil }
            experience.refreshPhotos()
            slideshow?.removeAssets(removed.subtracting(previous))
            collectionWallSession?.exclude(removed, app: model)
            wallRecords.removeAll { removed.contains($0.id) }
            wallRecordIDs.subtract(removed)
            if let photo = selectedPhoto, removed.contains(photo.id) { closePhotoDetail() }
            if layer == .photoWall, collectionWallSession == nil, !removed.subtracting(previous).isEmpty {
                wallTotalPhotoCount = nil
                restartWallCountAfterRemoval()
            }
        }
        .onChange(of: model.phase) { _, phase in
            defer { openPendingShelfAction() }
            guard !model.isExploringPublicGlobe else { return }
            if phase == .globe, !hasPresentedLibrary, !model.isPreparationPresented {
                hasPresentedLibrary = true
                experience.transitionCamera(to: userLocation ?? fallbackCenter, distance: GlobeCameraState.orbitalDistance,
                                            animated: false, overviewFraming: 1)
            }
            if phase == .denied {
                wallTask?.cancel(); wallCountTask?.cancel(); wallReader = nil
                collectionWallSession?.cancel(); collectionWallSession = nil
                wallRecords = []; wallRecordIDs = []; selectedPhoto = nil; selectedPhotoPreview = nil; collection = nil
                slideshow?.cancel(); slideshow = nil; slideshowReturnCamera = nil
                exploreCity = nil; wallCollection = nil; wallTotalPhotoCount = nil
                layer = .overview
                overviewReturnCamera = nil
                experience.deactivate()
            }
        }
        .task(id: scanCameraActive) {
            guard scanCameraActive else {
                if model.isPreparationPresented && !model.isExploringPublicGlobe { experience.pauseDirectManipulation() }
                return
            }
            while !Task.isCancelled && scanCameraActive {
                let now = Date().timeIntervalSinceReferenceDate
                scanDirector.ingest(model.scanDiscovery.places, at: now)
                if let flight = scanDirector.next(at: now, center: experience.displayedCamera.center,
                                                   viewport: experience.currentViewport, reduceMotion: reduceMotion, enabled: true) {
                    scanTarget = flight.place
                    refreshMapContent()
                    await Task.yield()
                    guard !Task.isCancelled, scanCameraActive else { return }
                    experience.transitionCamera(to: flight.place.coordinate, distance: GlobeCameraState.orbitalDistance,
                                                overviewFraming: 1, duration: flight.duration, usesGreatCircle: true)
                }
                if now - scanSessionStart.timeIntervalSinceReferenceDate >= 300 { followsScan = false; return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: layer) {
            guard layer == .explore else { return }
            showsControlHint = true
            do { try await Task.sleep(for: .seconds(7)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { showsControlHint = false }
        }
        .task(id: model.isUsingSampleData) {
            guard !model.isUsingSampleData else {
                isAwaitingUserLocation = false
                return
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if userLocation == nil { isAwaitingUserLocation = false }
        }
        .task(id: waitsForInitialGlobeRender) {
            guard waitsForInitialGlobeRender else { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled, waitsForInitialGlobeRender else { return }
            // MapKit can finish with missing imagery or never produce a fully
            // rendered callback on a poor connection. The experiment must not
            // leave the app permanently covered in that case.
            revealInitialGlobe()
        }
    }

    @ViewBuilder private var libraryNavigation: some View {
        if presentsDirectHome {
            // Mounting the native tab view opens its sidebar on tvOS. After a first
            // scan, let Home own focus until the user asks for navigation.
            overviewTab
                .padding(.top, 60)
                .overlay(alignment: .topLeading) {
                    Button(action: showSidebar) {
                        Label(AppLocalization.string("sidebar.home", defaultValue: "Home"), systemImage: "sidebar.left")
                    }
                    .buttonStyle(.glass)
                    .padding(.leading, 48)
                    .padding(.top, 32)
                    .accessibilityIdentifier("home-open-sidebar")
                }
                .onExitCommand(perform: showsHome ? { showSidebar() } : nil)
        } else {
            sidebar
        }
    }

    private func showSidebar() { presentsDirectHome = false }

    private var overviewTab: some View {
        GlobeOverviewView(
                        content: model.overview,
                        isUsingSampleData: model.isUsingSampleData,
                        enterGlobe: { enterExplore(at: userLocation ?? fallbackCenter) },
                        startSlideshow: places.isEmpty ? nil : { startHomeSlideshow() },
                        openPlace: { place in
                            model.select(placeID: place.id)
                            pendingCityEntry = place
                        },
                        prepareSatelliteCity: { focusedSatelliteCity = $0 },
                        isActive: slideshow == nil && isOverviewInteractive && destination == .home && navigationVisible && collection == nil && scenePhase == .active
                    )
                    .task(id: pendingCityEntry) {
                        guard let place = pendingCityEntry else { return }
                        await enterSelectedCity(place)
                    }
                    .onDisappear { pendingCityEntry = nil }
                    .onChange(of: showsHome && scenePhase == .active) { _, active in
                        if !active { pendingCityEntry = nil }
                    }
                    .padding(.bottom, 88)
                    .modifier(LibraryPreparationChrome(model: model, aboveHomeActions: true))
    }

    private var sidebar: some View {
        TabView(selection: Binding(get: { destination }, set: { next in
            guard destination != next else { return }
            if destination == .home { overviewReturnCamera = experience.camera }
            destination = next
            ProductAnalytics.shared.capture(.sidebarSelected, value: next.rawValue, context: .init(library: model.analyticsLibrary))
            if next == .home, layer == .overview { restoreHomeCamera() }
        })) {
            Tab(value: Destination.home) {
                overviewTab
            } label: {
                Label(AppLocalization.string("sidebar.home", defaultValue: "Home"), systemImage: "globe.asia.australia")
            }
            .accessibilityIdentifier("tab-home")
            Tab(value: Destination.recent) {
                PlaceLibraryView(model: model, mode: .recent,
                                 isActive: destination == .recent && navigationVisible && collection == nil && scenePhase == .active, openPhotos: openCollection)
                    .modifier(LibraryPreparationChrome(model: model))
            } label: {
                Label(AppLocalization.string("sidebar.recent", defaultValue: "Recently Visited"), systemImage: "clock")
            }
            .accessibilityIdentifier("tab-recent")
            Tab(value: Destination.countries) {
                PlaceLibraryView(model: model, mode: .countries,
                                 isActive: destination == .countries && navigationVisible && collection == nil && scenePhase == .active, openPhotos: openCollection)
                    .modifier(LibraryPreparationChrome(model: model))
            } label: {
                Label(AppLocalization.string("sidebar.countries", defaultValue: "Countries & Cities"), systemImage: "map")
            }
            .accessibilityIdentifier("tab-countries")
            Tab(value: Destination.anniversary) {
                OnThisDayView(model: model, isActive: destination == .anniversary && navigationVisible && scenePhase == .active,
                              selectedDay: $anniversaryDay)
                    .modifier(LibraryPreparationChrome(model: model))
            } label: {
                Label(AppLocalization.string("sidebar.anniversary", defaultValue: "On This Day"), systemImage: "calendar")
            }
            .accessibilityIdentifier("tab-anniversary")
            Tab(value: Destination.settings) {
                SettingsView(model: model)
                    .modifier(LibraryPreparationChrome(model: model))
            } label: {
                Label(AppLocalization.string("sidebar.settings", defaultValue: "Settings"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("tab-settings")
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private func openPendingShelfAction() {
        guard locationDestination == nil, model.pendingTopShelfRoute != nil else { return }
        // Preparation dismissal may reset the camera and Focus in this update.
        Task { @MainActor in
            await Task.yield()
            await applyPendingShelfAction()
        }
    }

    private func applyPendingShelfAction() async {
        guard let action = await model.takeTopShelfAction() else { return }
        anniversaryDay = nil
        mapReviewOrigin = nil
        slideshow?.cancel()
        slideshow = nil
        slideshowReturnCamera = nil
        if layer == .photoWall { closePhotoWall() }
        showsControls = false
        experience.setZoomControlsPresented(false)
        experience.photoWallViewportCapture.release()
        destination = .home
        switch action {
        case .journey(let selected):
            if layer == .explore { leaveExplore() }
            ProductAnalytics.shared.capture(.topShelfOpened, value: "city")
            openCollection(selected, entry: .topShelf)
        case .globe:
            ProductAnalytics.shared.capture(.topShelfOpened, value: "globe")
            collection = nil
            enterExplore(at: model.isExploringPublicGlobe ? GeoCoordinate(latitude: 24, longitude: 18) : (userLocation ?? fallbackCenter), entry: .topShelf)
        }
    }

    private func openCollection(_ selected: PlaceCollection) {
        openCollection(selected, entry: destination == .recent ? .recent : .countries)
    }

    private func openCollection(_ selected: PlaceCollection, entry: JourneyEventContext.Entry) {
        if destination == .home, layer == .overview, overviewReturnCamera == nil {
            overviewReturnCamera = experience.camera
        }
        experience.pauseDirectManipulation()
        if let place = selected.latestPlace {
            experience.transitionCamera(
                to: place.coordinate,
                distance: GlobeCameraState.orbitalDistance,
                animated: !reduceMotion,
                overviewFraming: 1,
                duration: 1.1,
                usesGreatCircle: true
            )
        }
        collection = selected
        ProductAnalytics.shared.capture(.wallOpened, value: "collection", context: .init(library: model.analyticsLibrary, entry: entry))
    }

    private var directManipulationSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable(!showsControls)
            .focused($isGlobeFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard !showsControls else { return }
                experience.nudge(direction)
            }
            .onExitCommand {
                if showsControls { closeControls() } else { leaveExplore() }
            }
            .onPlayPauseCommand(perform: openControls)
            .modifier(GlobeInputAccessibility(experience: experience))
            .accessibilityIdentifier("globe-direct-manipulation")
            .modifier(GlobeCameraAccessibility(experience: experience))
            .accessibilityHidden(showsControls)
    }

    private var cinematicMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(showsHome ? 0.28 : 0.12), location: 0),
                .init(color: .clear, location: showsHome ? 0.23 : 0.2),
                .init(color: .clear, location: showsHome ? 0.72 : 0.86),
                .init(color: .black.opacity(showsHome ? 0.26 : 0.12), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func prepareOverview() {
        if let locationDestination, layer == .overview {
            let start = reduceMotion ? locationDestination.camera : locationDestination.explorationOpeningCamera
            experience.transitionCamera(to: start.center, distance: start.distance, animated: false, overviewFraming: 0)
            enterExplore(at: locationDestination.camera.center, distance: locationDestination.camera.distance,
                         duration: 2.2, city: photoCityCollection(for: locationDestination), entry: .photoGlobe)
            return
        }
        if model.isExploringPublicGlobe && layer == .overview {
            enterExplore(at: GeoCoordinate(latitude: 24, longitude: 18), entry: .topShelf)
            return
        }
        guard !didPrepareOverview, layer == .overview else { return }
        didPrepareOverview = true
        refreshMapContent()
        experience.transitionCamera(to: fallbackCenter, distance: GlobeCameraState.orbitalDistance, animated: false, overviewFraming: 1)
        isAwaitingUserLocation = !model.isUsingSampleData
    }

    private func refreshMapContent() {
        mapContentRevision += 1
    }

    private func receiveUserLocation(_ coordinate: GeoCoordinate) {
        userLocation = coordinate
        let canAnchor = isAwaitingUserLocation && layer == .overview && !hasAnchoredUserLocation && navigationVisible
        isAwaitingUserLocation = false
        guard canAnchor else { return }
        hasAnchoredUserLocation = true
        experience.transitionCamera(to: coordinate, distance: GlobeCameraState.orbitalDistance, overviewFraming: 1)
    }

    private func revealInitialGlobe() {
        guard waitsForInitialGlobeRenderExperiment, !isInitialGlobeReady else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) {
            isInitialGlobeReady = true
        }
    }

    private func enterSelectedCity(_ place: TravelPlace) async {
        while !Task.isCancelled, pendingCityEntry == place, showsHome, scenePhase == .active {
            guard places.contains(where: { $0.id == place.id && $0.coordinate == place.coordinate }) else {
                pendingCityEntry = nil
                return
            }
            let city = PlaceCollection.city(containing: place, in: places)
            let exclusions = model.excludedAssetIDs
            let revision = model.index?.contentRevision
            let landing = try? await model.cityLanding(for: city, reference: place.coordinate)
            guard !Task.isCancelled, pendingCityEntry == place, showsHome, scenePhase == .active else { return }
            guard revision == model.index?.contentRevision, exclusions == model.excludedAssetIDs else { continue }
            pendingCityEntry = nil
            enterExplore(at: landing?.center ?? place.coordinate,
                         distance: landing?.distance ?? GlobeCameraState.cityFallbackDistance,
                         city: city, entry: .homeCity)
            return
        }
    }

    private func enterExplore(at center: GeoCoordinate, distance: Double = GlobeCameraState.orbitalDistance,
                              duration: Double = 0.9, city: PlaceCollection? = nil, entry: JourneyEventContext.Entry = .home) {
        if layer != .explore {
            ProductAnalytics.shared.capture(.globeExplored, context: .init(library: model.analyticsLibrary, entry: entry))
        }
        if layer == .overview, destination == .home, locationDestination == nil, overviewReturnCamera == nil {
            overviewReturnCamera = experience.camera
        }
        isOverviewInteractive = false
        exploreCity = city
        wallGeneration = UUID()
        selectedPhoto = nil
        selectedPhotoPreview = nil
        showsControlHint = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            layer = .explore
        }
        if city != nil, locationDestination == nil {
            experience.approachCity(at: center, distance: distance, animated: !reduceMotion)
        } else {
            experience.transitionCamera(to: center, distance: distance, animated: !reduceMotion,
                                        overviewFraming: 0, duration: duration)
        }
        let appModel = model
        experience.activate(initialCenter: center, startsAtCity: city != nil, onSelectAction: { action in
            guard layer == .explore, !showsControls else { return }
            switch action {
            case .singlePress:
                if !model.isExploringPublicGlobe { openPhotoWall() }
            }
        }, nearPhotoQuery: { [weak appModel] snapshot, onPreview in
            guard let appModel else { throw CancellationError() }
            if appModel.isExploringPublicGlobe { return ViewportPhotoBatch(clusters: [], preview: []) }
            let grid = try experience.photoWallViewportCapture.grid(for: snapshot.viewport)
            let scope = exploreCity.map { Set($0.placeIDs) }
            let reader = try await appModel.makePhotoReadSnapshot()
            return try await appModel.viewportPhotoBatch(in: snapshot, grid: grid, reader: reader, placeIDs: scope,
                                                        onPreview: onPreview, isCurrent: snapshot.isCurrent)
        }) { [weak appModel] viewport, limit in
            guard let appModel, !appModel.isExploringPublicGlobe else { return [] }
            return try await appModel.previewPhotos(in: viewport, limit: limit,
                                              placeIDs: exploreCity.map { Set($0.placeIDs) })
        }
        focusGlobe()


    }

    private func useCurrentView() {
        exploreCity = nil
        experience.refreshPhotos()
        closeControls()
    }

    private func leaveExplore() {
        if let closeLocationExploration {
            experience.deactivate()
            closeLocationExploration()
            return
        }
        model.closePublicGlobe()
        exploreCity = nil
        experience.pauseDirectManipulation()
        restoreHomeCamera()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42), completionCriteria: .removed) {
            layer = .overview
        } completion: {
            guard layer == .overview else { return }
            isOverviewInteractive = true
        }
    }

    private func restoreHomeCamera() {
        let camera = overviewReturnCamera ?? GlobeCameraState(center: userLocation ?? fallbackCenter,
                                                             distance: GlobeCameraState.orbitalDistance)
        overviewReturnCamera = nil
        experience.transitionCamera(to: camera.center, distance: camera.distance, animated: false, overviewFraming: 1)
    }

    private func openPhotoWall() {
        guard layer == .explore else { return }
        mapReviewOrigin = nil
        wallSnapshot = experience.capturePhotoWallViewport()
        wallCollection = exploreCity
        collectionWallSession?.cancel()
        collectionWallSession = wallSnapshot == nil || wallCollection == nil ? nil : CollectionPhotoWallSession()
        wallTotalPhotoCount = nil
        wallRecords = []
        wallRecordIDs = []
        wallCountScheduling = PhotoWallCountScheduling()
        wallReader = nil
        wallHasReadSession = false
        frozenWallPlaces = PhotoWallPlaces(); wallResolvedLabels = [:]
        wallError = wallSnapshot == nil ? PhotoWallSelectionError.unavailableViewport.localizedDescription : nil
        wallFocusID = nil
        isLoadingWall = false
        wallTask?.cancel()
        wallCountTask?.cancel()
        wallCountTask = nil
        wallNextOffset = wallSnapshot == nil ? nil : 0
        wallGeneration = UUID()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.44)) {
            layer = .photoWall
        }
        ProductAnalytics.shared.capture(.wallOpened, value: wallCollection == nil ? "currentView" : "collection",
                                        context: .init(library: model.analyticsLibrary, entry: .globe))
        loadNextWallPage()
    }

    private func loadNextWallPage() {
        guard layer == .photoWall else { return }
        if let collectionWallSession, let wallCollection {
            collectionWallSession.loadMore(app: model, collection: wallCollection)
            return
        }
        guard !isLoadingWall,
              let snapshot = wallSnapshot,
              let offset = wallNextOffset else { return }
        let generation = wallGeneration
        isLoadingWall = true
        wallError = nil
        let scheduling = wallCountScheduling

        wallTask = Task { @MainActor in
            scheduling.setPaused(true, for: .page)
            defer { scheduling.setPaused(false, for: .page) }
            do {
                if !wallHasReadSession {
                    let reader = try await model.makePhotoReadSnapshot()
                    let summaries = try await reader?.placeSummariesForReading() ?? places
                    guard !Task.isCancelled, layer == .photoWall, wallGeneration == generation else { return }
                    wallReader = reader
                    frozenWallPlaces = PhotoWallPlaces(summaries)
                    wallHasReadSession = true
                }
                let page = try await model.photoPage(in: snapshot, offset: offset, limit: 48, reader: wallReader)
                guard !Task.isCancelled, layer == .photoWall, wallGeneration == generation else { return }
                wallRecords.append(contentsOf: page.records.filter {
                    !model.excludedAssetIDs.contains($0.id) && wallRecordIDs.insert($0.id).inserted
                })
                wallNextOffset = page.nextOffset
                if wallTotalPhotoCount == nil {
                    if let nextOffset = page.nextOffset {
                        countRemainingWallPhotos(
                            in: snapshot,
                            startingAt: nextOffset,
                            initialCount: wallRecords.count,
                            reader: wallReader,
                            generation: generation
                        )
                    } else {
                        wallTotalPhotoCount = wallRecords.count
                    }
                }
                isLoadingWall = false
                if wallRecords.isEmpty, page.nextOffset != nil {
                    // Keep advancing bounded cancellable batches until the first
                    // actual match, with room for focus/input between batches.
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard !Task.isCancelled, wallGeneration == generation else { return }
                    loadNextWallPage()
                }
            } catch {
                guard !Task.isCancelled, wallGeneration == generation else { return }
                if let selectionError = error as? PhotoWallSelectionError {
                    wallRecords = []
                    wallRecordIDs = []
                    wallNextOffset = nil
                    wallError = selectionError.localizedDescription
                } else {
                    wallError = AppLocalization.string("error.wall.index", defaultValue: "The photo index is temporarily unavailable. Try again.")
                }
                isLoadingWall = false
            }
        }
    }

    private func closePhotoWall() {
        mapReviewOrigin = nil
        slideshow?.cancel()
        slideshow = nil
        slideshowReturnCamera = nil
        wallTask?.cancel()
        wallTask = nil
        wallCountTask?.cancel()
        wallCountTask = nil
        collectionWallSession?.cancel()
        collectionWallSession = nil
        wallReader = nil
        wallGeneration = UUID()
        isLoadingWall = false
        selectedPhoto = nil
        selectedPhotoPreview = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            layer = .explore
        }
        wallSnapshot = nil
        wallHasReadSession = false
        wallRecords = []
        wallRecordIDs = []
        frozenWallPlaces = PhotoWallPlaces()
        wallResolvedLabels = [:]
        wallCollection = nil
        wallTotalPhotoCount = nil
        wallFocusID = nil
        wallNextOffset = nil
        experience.resumeDirectManipulation()
        focusGlobe()
    }

    private func openWallMapReview() {
        guard layer == .photoWall, let origin = collectionWallSession?.membership?.reviewOrigin, wallSnapshot?.isCurrent() == true,
              selectedPhoto == nil, slideshow == nil, mapReviewOrigin == nil else { return }
        mapReviewOrigin = origin
        wallCountScheduling.setPaused(mapReviewOrigin != nil, for: .mapReview)
    }

    private var wallMapReviewAction: (() -> Void)? {
        wallCollection == nil ? nil : { openWallMapReview() }
    }

    private func closeWallMapReview() {
        mapReviewOrigin = nil
        wallCountScheduling.setPaused(false, for: .mapReview)
    }

    private func openPhoto(_ record: PhotoAssetRecord, preview: UIImage?) {
        wallCountScheduling.setPaused(true, for: .detail)
        selectedPhotoPreview = preview
        wallFocusID = record.id
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            selectedPhoto = record
        }
    }

    private func startHomeSlideshow() {
        guard layer == .overview, destination == .home, slideshow == nil, !places.isEmpty else { return }
        let scope = EarthSlideshowScope(id: "library",
            title: AppLocalization.string("slideshow.start", defaultValue: "Slideshow"), kind: .library)
        let show = model.makeEarthSlideshow(scope: scope, places: places, reduceMotion: reduceMotion,
                                             cameraAction: controlSlideshowGlobe)
        slideshow = show
        show.start(waitingForConfirmation: true)
    }

    private func startWallSlideshow() {
        guard slideshow == nil, selectedPhoto == nil, mapReviewOrigin == nil, layer == .photoWall else { return }
        let collection = wallCollection
        let membership = collectionWallSession?.membership
        guard membership != nil || (wallHasReadSession && wallSnapshot != nil) else { return }
        let scope = EarthSlideshowScope(id: collection?.id ?? "viewport-\(wallGeneration)",
            title: collection?.title ?? AppLocalization.string("memory_strip.title", defaultValue: "Photos in this view"),
            kind: collection == nil ? .currentView : .collection)
        let source = frozenWallPlaces.places.isEmpty ? places : frozenWallPlaces.places
        let show = model.makeEarthSlideshow(scope: scope,
            places: membership?.matchingVisits ?? source,
            viewport: collection == nil ? wallSnapshot : nil, reader: membership?.reader ?? wallReader,
            wallRecords: activeWallRecords, collectionExclusions: collectionWallSession?.excludedAssetIDs ?? [],
            reduceMotion: reduceMotion, cameraAction: controlSlideshowGlobe)
        wallCountScheduling.setPaused(true, for: .detail)
        slideshow = show
        show.start(waitingForConfirmation: true)
    }

    private func finishWallSlideshow() {
        slideshow = nil
        wallCountScheduling.setPaused(false, for: .detail)
        restoreGlobeAfterSlideshow()
    }

    private func controlSlideshowGlobe(_ target: EarthSlideshowCameraTarget, _ reducedMotion: Bool) {
        if slideshowReturnCamera == nil { slideshowReturnCamera = experience.displayedCamera }
        experience.pauseDirectManipulation()
        switch target {
        case .chapter(let visit, let isOpening):
            experience.transitionCamera(
                to: visit.coordinate,
                distance: GlobeCameraState.regionalDistance,
                animated: !reducedMotion,
                overviewFraming: 0,
                duration: isOpening ? EarthSlideshowConfiguration.standard.earthIntroDuration : 2.8,
                usesGreatCircle: true
            )
        case .ending(let visit):
            experience.transitionCamera(
                to: visit.coordinate,
                distance: GlobeCameraState.orbitalDistance,
                animated: !reducedMotion,
                overviewFraming: 0,
                duration: 3.2,
                usesGreatCircle: false
            )
        }
    }

    private func restoreGlobeAfterSlideshow() {
        guard let camera = slideshowReturnCamera else { return }
        slideshowReturnCamera = nil
        experience.transitionCamera(
            to: camera.center,
            distance: camera.distance,
            animated: !reduceMotion,
            overviewFraming: layer == .overview ? 1 : 0,
            duration: 0.8
        )
    }

    private func selectDetailRecord(_ record: PhotoAssetRecord) {
        guard selectedPhoto?.id != record.id else { return }
        wallFocusID = record.id
        selectedPhotoPreview = nil
        selectedPhoto = record
    }

    private func closePhotoDetail() {
        wallCountScheduling.setPaused(false, for: .detail)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            selectedPhoto = nil
            selectedPhotoPreview = nil
        }
    }

    private func finishCollectionDismissal() {
        // A Home Screen globe link can dismiss the native collection cover.
        if layer == .explore && !showsControls { focusGlobe() }
    }

    private func photoCityCollection(for target: PhotoGlobeDestination) -> PlaceCollection? {
        guard let placeID = target.placeID else { return nil }
        // A globe-wall detail already owns a stable SQLite place snapshot.
        // Sidebar collection details are dismissed first and use the current
        // index, which is the collection's source under normal operation.
        let source = layer == .photoWall && !wallPlaceSnapshot.isEmpty ? wallPlaceSnapshot : places
        guard let selected = source.first(where: { $0.id == placeID }) else { return nil }
        return PlaceCollection.city(containing: selected, in: source)
    }

    private func countRemainingWallPhotos(
        in snapshot: PhotoViewportSnapshot,
        startingAt offset: Int,
        initialCount: Int,
        reader: SQLiteTravelIndexStore?,
        generation: UUID
    ) {
        guard wallCountTask == nil else { return }
        wallCountTask = Task { @MainActor in
            do {
                let total = try await model.photoCount(
                    in: snapshot,
                    startingAt: offset,
                    initialCount: initialCount,
                    reader: reader,
                    scheduling: wallCountScheduling
                )
                guard !Task.isCancelled, layer == .photoWall, wallGeneration == generation,
                      wallCollection == nil else { return }
                wallTotalPhotoCount = total
                wallCountTask = nil
            } catch is CancellationError {
                // Closing or replacing the wall invalidates this count.
            } catch {
                guard !Task.isCancelled, wallGeneration == generation else { return }
                // Pagination remains usable. Once it reaches the end, the
                // loaded record count becomes the exact fallback total.
                wallCountTask = nil
            }
        }
    }

    private func restartWallCountAfterRemoval() {
        let previousCount = wallCountTask
        previousCount?.cancel()
        guard wallHasReadSession, let snapshot = wallSnapshot else {
            // The first read will start a fresh count with its filtered seed.
            wallCountTask = nil
            return
        }
        let generation = wallGeneration
        let reader = wallReader
        let scheduling = wallCountScheduling
        wallCountTask = Task { @MainActor in
            // photoCount closes its retained SQL cursor on cancellation. Wait
            // for that cleanup before a new count uses the same WAL reader.
            await previousCount?.value
            guard !Task.isCancelled, wallGeneration == generation,
                  layer == .photoWall, wallCollection == nil else { return }
            do {
                let total = try await model.photoCount(in: snapshot, startingAt: 0,
                                                      initialCount: 0, reader: reader,
                                                      scheduling: scheduling)
                guard !Task.isCancelled, wallGeneration == generation,
                      layer == .photoWall, wallCollection == nil else { return }
                wallTotalPhotoCount = total
                wallCountTask = nil
            } catch {
                guard !Task.isCancelled, wallGeneration == generation else { return }
                wallCountTask = nil
            }
        }
    }

    private func resolveWallLabels(_ ids: [String]) async {
        let generation = wallGeneration
        let result = await model.resolveSnapshotLabels(for: ids, places: wallPlaces)
        guard !Task.isCancelled, wallGeneration == generation else { return }
        wallResolvedLabels.merge(result) { _, latest in latest }
    }

    private func focusGlobe() {
        Task { @MainActor in
            await Task.yield()
            guard layer == .explore, !showsControls, selectedPhoto == nil else { return }
            isGlobeFocused = true
        }
    }

    private func openControls() {
        guard layer == .explore, !showsControls else { return }
        experience.setZoomControlsPresented(true)
        isGlobeFocused = false
        showsControls = true
    }

    private func closeControls() {
        guard showsControls else { return }
        // Touch dragging stays active. Keep physical direction and Select
        // navigation with the dock until its native focus owner is gone.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), completionCriteria: .removed) {
            showsControls = false
        } completion: {
            guard layer == .explore, !showsControls, selectedPhoto == nil else { return }
            experience.setZoomControlsPresented(false)
            focusGlobe()
        }
    }


}


private struct GlobeMapLayer: View {
    @ObservedObject var experience: GlobeExperienceModel
    let places: [TravelPlace]
    let contentRevision: Int
    let exploresByScale: Bool
    let homeFrameContext: HomeGlobeFrame.Context
    let allowsHomeDrift: Bool
    let focusedSatelliteCity: GeoCoordinate?
    let preferredPlaceID: String?
    let size: CGSize
    let showsUserLocation: Bool
    let waitsForInitialRender: Bool
    let onUserLocationUpdate: (GeoCoordinate) -> Void
    let onInitialRenderReady: () -> Void

    private var renderedPresentation: GlobeScalePresentation {
        exploresByScale ? experience.presentation : GlobeScalePresentation()
    }

    private var receiveScale: ((GlobeScale) -> Void)? {
        guard exploresByScale else { return nil }
        return { scale in experience.updateScale(scale) }
    }

    private var homeDriftStep: ((GlobeCameraState, Double) -> GlobeCameraState?)? {
        guard allowsHomeDrift else { return nil }
        return { camera, elapsed in experience.advanceHomeDrift(from: camera, elapsed: elapsed) }
    }

    var body: some View {
        MapKitEarthView(
            places: places,
            contentRevision: contentRevision,
            camera: experience.camera,
            cameraTransitionRevision: experience.cameraTransitionRevision,
            isManipulating: experience.isManipulating,
            showsUserLocation: showsUserLocation,
            settleRevision: experience.settleRevision,
            nativeCameraFeedback: experience.nativeCameraFeedback,
            photoWallViewportCapture: experience.photoWallViewportCapture,
            preferredPlaceID: preferredPlaceID,
            waitsForInitialRender: waitsForInitialRender,
            homeFrameContext: homeFrameContext,
            advanceHomeDrift: homeDriftStep,
            mapStyle: renderedPresentation.style,
            focusedSatelliteCity: focusedSatelliteCity,
            isCityFlight: exploresByScale && experience.isApproachingCity,
            regionalBasemapTarget: exploresByScale ? experience.regionalBasemapTarget : nil,
            scalePresentation: renderedPresentation,
            onScaleChanged: receiveScale,
            onViewportSettled: experience.receiveViewport,
            onUserLocationUpdate: onUserLocationUpdate,
            onViewportInvalidated: experience.invalidateNativeProjection,
            onInitialRenderReady: onInitialRenderReady
        )
        .frame(width: size.width, height: size.height)
    }
}

private struct InitialGlobeLoadingCover: View {
    var body: some View {
        ZStack {
            SpaceBackdrop(quality: .standard)

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color(red: 0.78, green: 0.88, blue: 0.97))
                Text(AppLocalization.string(
                    "globe.initial_render.message",
                    defaultValue: "Preparing the satellite view"
                ))
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .shadow(color: .black.opacity(0.72), radius: 12, y: 3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("globe-initial-render-cover")
    }
}
