import SwiftUI
import Combine
import MapKit

private struct MapReviewQueryKey: Hashable {
    let revision: Int
    let active: Bool
    let excluded: Set<String>
}

@MainActor final class MapReviewSession: ObservableObject {
    @Published private(set) var pinAnchors: [MapReviewPinAnchor] = []
    @Published var records: [PhotoAssetRecord] = []
    @Published var total: Int?
    @Published var nextOffset: Int?
    @Published var isLoading = false
    @Published var ready = false
    @Published private(set) var pageError: String?
    @Published private(set) var countFailed = false
    private(set) var snapshot: PhotoViewportSnapshot?
    private var pageTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var generation = UUID()
    private var excludedAssetIDs: Set<String>?

    func invalidate(keepingPins: Bool = true) {
        suspend()
        records = []; total = nil; nextOffset = nil
        if !keepingPins { pinAnchors = [] }
        snapshot = nil; ready = false; pageError = nil; countFailed = false
    }

    func preparePins(excluding assetIDs: Set<String>) {
        if excludedAssetIDs != assetIDs { pinAnchors = [] }
        excludedAssetIDs = assetIDs
    }

    func acceptClusters(_ clusters: [MapReviewCluster], camera: MapReviewCamera) {
        pinAnchors = camera.pinAnchors(clusters)
        total = clusters.reduce(0) { $0 + $1.count }
        ready = true
    }

    func refresh(app: AppModel, snapshot: PhotoViewportSnapshot, grid: MapReviewGrid,
                 reader: SQLiteTravelIndexStore?, camera: MapReviewCamera) async {
        guard !Task.isCancelled else { return }
        invalidate()
        self.snapshot = snapshot
        page(app: app, reader: reader, at: 0)
        let task = count(app: app, snapshot: snapshot, grid: grid, reader: reader, camera: camera)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func retryCount(app: AppModel, grid: MapReviewGrid, reader: SQLiteTravelIndexStore?,
                    camera: MapReviewCamera) -> Task<Void, Never>? {
        guard countFailed, let snapshot, snapshot.isCurrent() else { return nil }
        return count(app: app, snapshot: snapshot, grid: grid, reader: reader, camera: camera)
    }

    private func count(app: AppModel, snapshot: PhotoViewportSnapshot, grid: MapReviewGrid,
                       reader: SQLiteTravelIndexStore?, camera: MapReviewCamera) -> Task<Void, Never> {
        let token = generation
        let excluded = app.excludedAssetIDs
        countFailed = false
        let task = Task { @MainActor in
            defer { if generation == token { countTask = nil } }
            do {
                let batch = try await app.viewportPhotoBatch(in: snapshot, grid: grid, reader: reader) {
                    self.generation == token && app.excludedAssetIDs == excluded
                }
                guard !Task.isCancelled, generation == token, app.excludedAssetIDs == excluded,
                      snapshot.isCurrent() else { return }
                acceptClusters(batch.clusters, camera: camera)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, generation == token, app.excludedAssetIDs == excluded,
                      snapshot.isCurrent() else { return }
                countFailed = true
            }
        }
        countTask = task
        return task
    }

    func page(app: AppModel, reader: SQLiteTravelIndexStore?, at offset: Int, append: Bool = false) {
        pageTask?.cancel()
        guard let snapshot else { return }
        let token = generation
        isLoading = true; pageError = nil
        if !append { records = []; nextOffset = nil }
        pageTask = Task { @MainActor in
            do {
                var cursor = offset
                while true {
                    let page = try await app.photoPage(in: snapshot, offset: cursor, limit: 48, reader: reader)
                    guard !Task.isCancelled, generation == token, snapshot.isCurrent() else { return }
                    let photos = page.records.filter { !app.excludedAssetIDs.contains($0.id) }
                    if !photos.isEmpty || page.nextOffset == nil {
                        if append { records.append(contentsOf: photos) } else { records = photos }
                        nextOffset = page.nextOffset; isLoading = false
                        return
                    }
                    guard let next = page.nextOffset, next > cursor else { throw PhotoWallSelectionError.unavailableViewport }
                    cursor = next
                    await Task.yield()
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                pageError = message; isLoading = false
            }
        }
    }

    func suspend() {
        generation = UUID()
        pageTask?.cancel(); pageTask = nil
        countTask?.cancel(); countTask = nil
        isLoading = false
    }
    private var message: String { AppLocalization.string("error.wall.index", defaultValue: "The photo index is temporarily unavailable. Try again.") }
}

/// The same direct manipulation / Select-to-wall / Play-Pause-to-Dock contract
/// as the main globe. Pins and the memory horizon never enter the Focus graph.
struct MapReviewView: View {
    @ObservedObject var app: AppModel
    let origin: MapReviewOrigin
    let reader: SQLiteTravelIndexStore?
    var allowsPhotoLocation = true
    let controlGlobe: EarthSlideshowCoordinator.CameraAction
    let restoreGlobe: () -> Void
    let close: () -> Void

    @StateObject private var camera = MapReviewCamera()
    @StateObject private var session = MapReviewSession()
    @State private var showsControls = false
    @State private var showsWall = false
    @State private var slideshow: EarthSlideshowCoordinator?
    @State private var selectedPhoto: PhotoAssetRecord?
    @State private var selectedPreview: UIImage?
    @State private var wallFocusID: String?
    @State private var frozenPlaces = PhotoWallPlaces()
    private var placeSnapshot: [TravelPlace] { frozenPlaces.places }
    @State private var resolvedLabels: [String: PlaceDisplayLabel] = [:]
    @FocusState private var isMapFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    private var mapPositionDescription: String {
        let center = camera.map.centerCoordinate
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...4)).locale(AppLocalization.locale)
        let distance = AppLocalization.format("globe.camera_distance", defaultValue: "Camera distance %@",
                                              AppLocalization.distance(meters: camera.map.camera.centerCoordinateDistance))
        return AppLocalization.format("review.map_position", defaultValue: "Latitude %1$@, longitude %2$@. %3$@",
                                      center.latitude.formatted(format), center.longitude.formatted(format), distance)
    }

    private func text(_ key: StaticString, _ fallback: String) -> String { AppLocalization.string(key, defaultValue: fallback) }
    private func placeLabel(_ id: String) -> PlaceDisplayLabel? {
        resolvedLabels[id] ?? frozenPlaces[id].map { PlaceDisplayLabel(place: $0) }
    }
    private var exploring: Bool { !showsWall && scenePhase == .active }
    private var hasCurrentWallSnapshot: Bool { session.snapshot?.isCurrent() == true }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                MapReviewMap(camera: camera, anchors: session.pinAnchors, isActive: exploring)
                    .ignoresSafeArea().opacity(slideshow == nil ? 1 : 0)
                LinearGradient(stops: [
                    .init(color: .black.opacity(reduceTransparency ? 0.95 : 0.6), location: 0),
                    .init(color: .clear, location: 0.24), .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)

                if !showsWall {
                    if !showsControls {
                        Color.clear.contentShape(Rectangle()).focusable().focusEffectDisabled()
                            .focused($isMapFocused)
                            .onMoveCommand { camera.fallbackNudge($0) }
                            .onPlayPauseCommand(perform: openControls)
                            .onExitCommand(perform: close)
                            .accessibilityLabel(text("review.title", "Photo Map"))
                            .accessibilityHint(AppLocalization.globeInputHint(supportsTouchPan: camera.supportsTouchPan))
                            .accessibilityIdentifier("map-review-direct-manipulation")
                            .accessibilityValue(mapPositionDescription)
                    }
                    RemoteSelectPressCapture(isEnabled: exploring && !showsControls,
                        acceptsPresses: { exploring && !showsControls },
                        onPressChanged: { camera.receiveSelectPress($0, source: .uiKit) },
                        onCancelled: camera.cancelSelectPresses)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    RemoteTouchPanCapture(isEnabled: exploring, acceptsTouches: { exploring },
                        onContactChanged: camera.touchContact,
                        onPan: { camera.pan(dx: $0, dy: $1) },
                        onPressClaimed: camera.claimTouchForPhysicalPress,
                        onAvailabilityChanged: camera.setTouchPanAvailable)
                        .allowsHitTesting(false).accessibilityHidden(true)

                    if !showsControls {
                        VStack {
                            HStack(alignment: .top) {
                                Text(text("review.title", "Photo Map")).font(.system(size: 30, weight: .medium))
                                Spacer()
                                Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 12) {
                                    GridRow {
                                        if camera.supportsTouchPan {
                                            Label(text("globe.controls.swipe", "Drag"), systemImage: camera.remoteSymbolNames.touchSurface)
                                        } else {
                                            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                                        }
                                        Label(text("globe.controls.arrows", "Turn"), systemImage: camera.remoteSymbolNames.directionalPad)
                                    }
                                    GridRow {
                                        Label(text("globe.controls.select", "Photos"), systemImage: camera.remoteSymbolNames.centerButton)
                                        Label(text("globe.controls.zoom", "Zoom"), systemImage: camera.remoteSymbolNames.playPauseButton)
                                    }
                                }.font(.system(size: 23)).padding(18).floatingSurface(in: RoundedRectangle(cornerRadius: 18))
                            }.padding(.horizontal, 80).padding(.top, 60).allowsHitTesting(false)
                            Spacer()
                            horizon
                        }.foregroundStyle(.white).allowsHitTesting(false)
                    } else {
                        MapZoomControlPanel(zoomIn: { camera.zoom(inward: true, animated: !reduceMotion) },
                            zoomOut: { camera.zoom(inward: false, animated: !reduceMotion) }, close: closeControls,
                            supportsTouchPan: camera.supportsTouchPan,
                            identifierPrefix: "map-review", mapStyle: camera.style, toggleStyle: camera.toggleStyle)
                            .zIndex(3)
                    }
                } else {
                    photoWall
                    if let slideshow {
                        EarthSlideshowView(coordinator: slideshow) {
                            self.slideshow = nil
                            restoreGlobe()
                        }.zIndex(5)
                    }
                    if let photo = selectedPhoto {
                        PhotoDetailView(record: photo, placeLabel: photo.placeID.flatMap(placeLabel), initialImage: selectedPreview,
                            resolvePlaceLabel: { await resolveLabels([photo.placeID].compactMap { $0 }) },
                            records: session.records, hasMorePhotos: session.nextOffset != nil, isLoadingMorePhotos: session.isLoading,
                            pagingError: session.pageError, loadMorePhotos: loadMore,
                            selectRecord: { selectedPhoto = $0; selectedPreview = nil; wallFocusID = $0.id },
                            locationLibrary: allowsPhotoLocation ? app : nil) {
                                selectedPhoto = nil; selectedPreview = nil; wallFocusID = photo.id
                            }.zIndex(4)
                    }
                }
            }
        }
        .ignoresSafeArea().background(slideshow == nil ? Color.black : Color.clear)
        .accessibilityElement(children: .contain).accessibilityIdentifier("map-review")
        .onAppear { ProductAnalytics.shared.capture(.mapReviewOpened, context: .init(library: app.analyticsLibrary)) }
        .task {
            frozenPlaces = PhotoWallPlaces((try? await reader?.placeSummariesForReading()) ?? app.index?.places ?? [])
            let grid = MapReviewGrid.world(around: origin.reference.longitude)
            let extent = try? await app.mapReviewClusters(placeIDs: origin.placeIDs, grid: grid, reader: reader).first
            guard !Task.isCancelled else { return }
            if let extent { camera.fit(extent, animated: false) }
            else { camera.show(center: origin.reference, distance: GlobeCameraState.regionalDistance) }
            camera.onSelect = openWall
            resumeMap()
        }
        .task(id: MapReviewQueryKey(revision: camera.revision, active: scenePhase == .active, excluded: app.excludedAssetIDs)) {
            session.preparePins(excluding: app.excludedAssetIDs)
            guard scenePhase == .active, let snapshot = camera.snapshot, let grid = camera.grid else {
                session.invalidate(keepingPins: scenePhase == .active); return
            }
            await session.refresh(app: app, snapshot: snapshot, grid: grid, reader: reader, camera: camera)
            if !Task.isCancelled, !snapshot.isCurrent() { camera.invalidateViewport(); camera.publishGrid() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { selectedPreview = nil; camera.stop(); session.suspend() }
            else if !showsWall { resumeMap(); camera.publishGrid() }
        }
        .onChange(of: app.excludedAssetIDs) { previous, removed in
            slideshow?.removeAssets(removed.subtracting(previous))
            if let photo = selectedPhoto, removed.contains(photo.id) {
                selectedPhoto = nil
                selectedPreview = nil
            }
        }
        .onDisappear {
            if slideshow != nil { slideshow?.cancel(); restoreGlobe() }
            camera.onSelect = nil; camera.stop(); session.suspend() }
    }

    private var photoWall: some View {
        let active = selectedPhoto == nil && slideshow == nil
        let countError = session.countFailed ? text("error.wall.count", "Couldn’t count all items.") : nil
        let countRetry: (() -> Void)? = hasCurrentWallSnapshot ? { retryCount() } : nil
        return ViewportPhotoWall(
            records: session.records, isLoading: session.isLoading, hasMore: session.nextOffset != nil,
            placeLabel: placeLabel,
            selectPhoto: { photo, image in selectedPhoto = photo; selectedPreview = image },
            loadMore: loadMore, close: closeWall, isActive: active, selectedPhotoID: $wallFocusID,
            errorMessage: session.pageError, canRetry: hasCurrentWallSnapshot, totalPhotoCount: session.total,
            countErrorMessage: countError, retryPhotoCount: countRetry, startSlideshow: startSlideshow,
            labelStates: app.placeLabelStates, resolvePlaceLabels: resolveLabels, analyticsLibrary: app.analyticsLibrary
        )
        .opacity(slideshow == nil ? 1 : 0)
        .disabled(!active)
        .accessibilityHidden(!active)
    }

    private var horizon: some View {
        MemoryPhotoStrip(records: session.records, isReady: (session.ready || !session.records.isEmpty) && !session.isLoading,
            isManipulating: camera.grid == nil, isRefreshing: !session.ready || session.isLoading,
            queryFailed: session.pageError != nil || session.countFailed,
            totalPhotoCount: session.total, countIdentifier: "map-review-count",
            advanceBatch: (session.nextOffset != nil || (session.total ?? 0) > session.records.count) ? {
                session.page(app: app, reader: reader, at: session.nextOffset ?? 0)
            } : nil)
    }

    private func resumeMap() {
        camera.start(); camera.beginMovingInput(); camera.setControlsPresented(showsControls)
        Task { @MainActor in await Task.yield(); if exploring && !showsControls { isMapFocused = true } }
    }
    private func openControls() {
        guard exploring, !showsControls else { return }
        camera.setControlsPresented(true); isMapFocused = false; showsControls = true
    }
    private func closeControls() {
        guard showsControls else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), completionCriteria: .removed) { showsControls = false } completion: {
            guard exploring, !showsControls else { return }
            camera.setControlsPresented(false); isMapFocused = true
        }
    }
    private func openWall() {
        guard exploring, !showsControls, let snapshot = MapViewportSampler.photoSnapshot(in: camera.map) else { return }
        camera.endMovingInput(); isMapFocused = false
        // The native map is frozen, so an in-flight exact count can finish.
        if session.snapshot?.isCurrent() != true { camera.publishGrid() }
        showsWall = true; wallFocusID = nil
        ProductAnalytics.shared.capture(.wallOpened, value: "currentView", context: .init(library: app.analyticsLibrary, entry: .mapReview))
        if session.snapshot?.isCurrent() == true { session.page(app: app, reader: reader, at: 0) }
        else { _ = snapshot } // The settled snapshot task will load this frozen view.
    }
    private func startSlideshow() {
        guard showsWall, selectedPhoto == nil, slideshow == nil, let snapshot = session.snapshot else { return }
        let scope = EarthSlideshowScope(id: "review-viewport",
            title: text("memory_strip.title", "Photos in this view"), kind: .currentView)
        // This map owns the frozen viewport of the underlying wall. Chapter
        // motion must leave that projection and return camera intact.
        let show = app.makeEarthSlideshow(scope: scope, places: placeSnapshot, viewport: snapshot,
                                          reader: reader, wallRecords: session.records, reduceMotion: reduceMotion, cameraAction: controlGlobe)
        slideshow = show
        show.start(waitingForConfirmation: true)
    }

    private func closeWall() {
        showsWall = false; selectedPhoto = nil; selectedPreview = nil
        session.page(app: app, reader: reader, at: 0)
        resumeMap()
    }
    private func loadMore() {
        guard !session.isLoading, hasCurrentWallSnapshot else { return }
        if let offset = session.nextOffset {
            session.page(app: app, reader: reader, at: offset, append: true)
        } else if session.pageError != nil {
            session.page(app: app, reader: reader, at: 0)
        }
    }
    private func retryCount() {
        guard scenePhase == .active, let grid = camera.grid else { return }
        session.retryCount(app: app, grid: grid, reader: reader, camera: camera)
    }
    private func resolveLabels(_ ids: [String]) async {
        let result = await app.resolveSnapshotLabels(for: ids, places: frozenPlaces)
        guard !Task.isCancelled else { return }
        resolvedLabels.merge(result) { _, latest in latest }
    }
}
