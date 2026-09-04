import SwiftUI

struct GlobeView: View {
    private enum Layer: Equatable {
        case overview
        case explore
        case photoWall
    }

    @ObservedObject var model: AppModel
    @StateObject private var experience = GlobeExperienceModel()
    @StateObject private var labelResolver = MapKitPlaceLabelResolver()
    @FocusState private var isGlobeFocused: Bool

    @State private var layer: Layer = .overview
    @State private var showsControlHint = true
    @State private var userLocation: GeoCoordinate?
    @State private var isAwaitingUserLocation = true
    @State private var hasAnchoredUserLocation = false
    @State private var latestAssetIDs: [String: String] = [:]
    @State private var resolvedLabels: [String: PlaceDisplayLabel] = [:]
    @State private var overviewPlaceLimit = 15
    @State private var renderedMapPlaces: [TravelPlace] = []
    @State private var mapContentRevision = 0
    @State private var wallViewport: EarthViewport?
    @State private var wallRecords: [PhotoAssetRecord] = []
    @State private var wallNextOffset: Int?
    @State private var isLoadingWall = false
    @State private var wallGeneration = UUID()
    @State private var selectedPhoto: PhotoAssetRecord?

    private var places: [TravelPlace] { model.index?.places ?? [] }
    private var sortedPlaces: [TravelPlace] {
        places.sorted {
            if $0.endDate == $1.endDate { return $0.id < $1.id }
            return $0.endDate > $1.endDate
        }
    }
    private var recentPlaces: [TravelPlace] {
        Array(sortedPlaces.prefix(5))
    }
    private var overviewPlaces: [TravelPlace] {
        Array(sortedPlaces.prefix(overviewPlaceLimit))
    }
    private var fallbackCenter: GeoCoordinate {
        recentPlaces.first?.coordinate
            ?? places.first?.coordinate
            ?? GeoCoordinate(latitude: 24, longitude: 18)
    }
    private var allLabels: [String: PlaceDisplayLabel] {
        Dictionary(uniqueKeysWithValues: places.map { place in
            (place.id, resolvedLabels[place.id] ?? PlaceDisplayLabel(place: place))
        })
    }
    private var overviewContentSignature: String {
        overviewPlaces.map { "\($0.id):\($0.photoCount)" }.joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black

                MapKitEarthView(
                    places: renderedMapPlaces,
                    contentRevision: mapContentRevision,
                    camera: experience.camera,
                    cameraTransitionRevision: experience.cameraTransitionRevision,
                    isManipulating: layer == .explore && experience.isManipulating,
                    showsUserLocation: layer == .overview && !model.isUsingSampleData,
                    settleRevision: experience.settleRevision,
                    onViewportSettled: experience.receiveViewport,
                    onUserLocationUpdate: receiveUserLocation
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .ignoresSafeArea()

                cinematicMask

                if layer == .overview {
                    GlobeOverviewView(
                        places: overviewPlaces,
                        labels: allLabels,
                        latestAssetIDs: latestAssetIDs,
                        hasMorePlaces: overviewPlaces.count < places.count,
                        hasUserLocation: userLocation != nil,
                        isAwaitingUserLocation: isAwaitingUserLocation,
                        isUsingSampleData: model.isUsingSampleData,
                        photoCount: model.index?.locatedPhotoCount ?? 0,
                        enterGlobe: { enterExplore(at: userLocation ?? fallbackCenter) },
                        openPlace: { place in
                            model.select(placeID: place.id)
                            enterExplore(at: place.coordinate)
                        },
                        loadMorePlaces: loadMoreOverviewPlaces
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }

                if layer == .explore {
                    directManipulationSurface
                        .zIndex(1)

                    exploreChrome
                        .transition(.opacity)
                        .zIndex(2)
                }

                if layer == .photoWall {
                    ViewportPhotoWall(
                        records: wallRecords,
                        isLoading: isLoadingWall,
                        hasMore: wallNextOffset != nil,
                        labels: allLabels,
                        selectPhoto: openPhoto,
                        loadMore: loadNextWallPage,
                        close: closePhotoWall
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
                }

                if let selectedPhoto {
                    PhotoDetailView(
                        record: selectedPhoto,
                        placeLabel: label(for: selectedPhoto),
                        close: closePhotoDetail
                    )
                    .transition(.opacity)
                    .zIndex(4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.38), value: layer)
        .animation(.easeInOut(duration: 0.28), value: selectedPhoto?.id)
        .onAppear(perform: prepareOverview)
        .onDisappear {
            wallGeneration = UUID()
            labelResolver.cancel()
            experience.deactivate()
        }
        .onChange(of: model.index?.generatedAt) { _, _ in
            latestAssetIDs = [:]
            resolvedLabels = [:]
            overviewPlaceLimit = 15
            refreshMapContent()
            experience.transitionCamera(to: fallbackCenter, distance: 36_000_000, animated: false)
        }
        .task(id: overviewContentSignature) {
            await loadOverviewContent()
        }
        .task(id: model.isUsingSampleData) {
            guard !model.isUsingSampleData else {
                isAwaitingUserLocation = false
                return
            }
            try? await Task.sleep(for: .seconds(5))
            if userLocation == nil { isAwaitingUserLocation = false }
        }
    }

    private var directManipulationSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .focused($isGlobeFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: experience.nudge)
            .onTapGesture(perform: openPhotoWall)
            .onExitCommand(perform: leaveExplore)
            .accessibilityLabel("滚动地球；按下遥控器中键打开当前地表照片墙")
            .accessibilityIdentifier("globe-direct-manipulation")
    }

    private var exploreChrome: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 62)
                .padding(.top, 34)

            Spacer()

            MemoryPhotoStrip(
                records: experience.visiblePhotos,
                isManipulating: experience.isManipulating,
                isRefreshing: experience.isRefreshingPhotos
            )
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                Circle()
                    .fill(.cyan)
                    .frame(width: 8, height: 8)
                    .shadow(color: .cyan, radius: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PHOTO EARTH")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(4)
                    Text("LIVE MEMORY GLOBE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(.cyan.opacity(0.72))
                }
            }

            Spacer()

            controlHint
                .opacity(showsControlHint || experience.isManipulating ? 1 : 0.36)
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private var controlHint: some View {
        HStack(spacing: 18) {
            Label("方向键转动", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            divider
            Label("外圈旋转缩放", systemImage: "circle.dotted.circle")
            divider
            Label("按下查看照片", systemImage: "circle.inset.filled")
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.66))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.34), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.1), lineWidth: 1) }
        .animation(.easeOut(duration: 0.28), value: experience.isManipulating)
        .accessibilityIdentifier("globe-control-hint")
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 1, height: 22)
    }

    private var cinematicMask: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.68), .clear, .clear, .black.opacity(0.46)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.42), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(maxWidth: 230)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.24)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(maxWidth: 160)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func prepareOverview() {
        refreshMapContent()
        experience.transitionCamera(to: fallbackCenter, distance: 36_000_000, animated: false)
        isAwaitingUserLocation = !model.isUsingSampleData
    }

    private func refreshMapContent() {
        renderedMapPlaces = MapPlaceLOD.representatives(from: places, limit: 180)
        mapContentRevision += 1
    }

    private func receiveUserLocation(_ coordinate: GeoCoordinate) {
        userLocation = coordinate
        isAwaitingUserLocation = false
        guard layer == .overview, !hasAnchoredUserLocation else { return }
        hasAnchoredUserLocation = true
        experience.transitionCamera(to: coordinate, distance: 36_000_000)
    }

    private func enterExplore(at center: GeoCoordinate) {
        wallGeneration = UUID()
        selectedPhoto = nil
        showsControlHint = true
        withAnimation(.easeInOut(duration: 0.5)) {
            layer = .explore
        }
        experience.transitionCamera(
            to: center,
            distance: GlobeCameraState.defaultDistance
        )
        let appModel = model
        experience.activate(initialCenter: center) { [weak appModel] viewport, limit in
            await appModel?.photos(in: viewport, limit: limit) ?? []
        }
        focusGlobe()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            guard layer == .explore else { return }
            withAnimation(.easeOut(duration: 1)) { showsControlHint = false }
        }
    }

    private func leaveExplore() {
        experience.pauseDirectManipulation()
        experience.transitionCamera(
            to: userLocation ?? fallbackCenter,
            distance: 36_000_000
        )
        withAnimation(.easeInOut(duration: 0.42)) {
            layer = .overview
        }
    }

    private func openPhotoWall() {
        guard layer == .explore else { return }
        wallViewport = experience.currentViewport
        wallRecords = []
        wallNextOffset = 0
        wallGeneration = UUID()
        experience.pauseDirectManipulation()
        withAnimation(.easeInOut(duration: 0.44)) {
            layer = .photoWall
        }
        loadNextWallPage()
    }

    private func loadNextWallPage() {
        guard layer == .photoWall,
              !isLoadingWall,
              let viewport = wallViewport,
              let offset = wallNextOffset else { return }
        let generation = wallGeneration
        isLoadingWall = true

        Task { @MainActor in
            let page = await model.photoPage(in: viewport, offset: offset, limit: 48)
            guard layer == .photoWall, wallGeneration == generation else { return }
            let existingIDs = Set(wallRecords.map(\.id))
            wallRecords.append(contentsOf: page.records.filter { !existingIDs.contains($0.id) })
            wallNextOffset = page.nextOffset
            isLoadingWall = false
        }
    }

    private func closePhotoWall() {
        wallGeneration = UUID()
        isLoadingWall = false
        selectedPhoto = nil
        withAnimation(.easeInOut(duration: 0.4)) {
            layer = .explore
        }
        experience.resumeDirectManipulation()
        focusGlobe()
    }

    private func openPhoto(_ record: PhotoAssetRecord) {
        withAnimation(.easeInOut(duration: 0.28)) {
            selectedPhoto = record
        }
    }

    private func closePhotoDetail() {
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedPhoto = nil
        }
    }

    private func label(for record: PhotoAssetRecord) -> PlaceDisplayLabel? {
        guard let placeID = record.placeID else { return nil }
        return allLabels[placeID]
    }

    private func focusGlobe() {
        Task { @MainActor in
            await Task.yield()
            isGlobeFocused = true
        }
    }

    private func loadOverviewContent() async {
        let visiblePlaces = overviewPlaces
        for place in visiblePlaces where latestAssetIDs[place.id] == nil {
            if Task.isCancelled { return }
            if let assetID = await model.latestAssetID(for: place) {
                latestAssetIDs[place.id] = assetID
            }
        }
        guard !Task.isCancelled else { return }

        let unresolvedPlaces = visiblePlaces.filter { resolvedLabels[$0.id] == nil }
        let recentIDs = Set(recentPlaces.map(\.id))
        let priorityPlaces = unresolvedPlaces.filter { recentIDs.contains($0.id) }
        let labels = await labelResolver.labels(for: priorityPlaces)
        guard !Task.isCancelled else { return }
        resolvedLabels.merge(labels) { _, resolved in resolved }
        await model.applyResolvedPlaceLabels(labels)

        let remainingPlaces = unresolvedPlaces.filter { !recentIDs.contains($0.id) }
        let remainingLabels = await labelResolver.labels(for: remainingPlaces)
        guard !Task.isCancelled else { return }
        resolvedLabels.merge(remainingLabels) { _, resolved in resolved }
        await model.applyResolvedPlaceLabels(remainingLabels)
    }

    private func loadMoreOverviewPlaces() {
        guard overviewPlaceLimit < places.count else { return }
        overviewPlaceLimit = min(overviewPlaceLimit + 10, places.count)
    }
}
