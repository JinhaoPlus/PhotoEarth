import SwiftUI
import UIKit

struct PhotoDetailView: View {
    private struct AddressRequest: Equatable {
        let id: String
        let coordinate: GeoCoordinate
        let revision: UInt
    }
    @State private var addressRevision: UInt = 0
    @State private var cachedAddress: (request: AddressRequest, text: String)?
    let record: PhotoAssetRecord
    let placeLabel: PlaceDisplayLabel?
    var initialImage: UIImage?
    var resolvePlaceLabel: () async -> Void = {}
    var records: [PhotoAssetRecord] = []
    var hasMorePhotos = false
    var isLoadingMorePhotos = false
    var pagingError: String?
    var loadMorePhotos: () -> Void = {}
    var selectRecord: (PhotoAssetRecord) -> Void = { _ in }
    var locationLibrary: AppModel?
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var requestedMediaKinds = Set<PhotoMediaKind>()
    @State private var retryIsVisible = false
    @State private var browsing = PhotoBrowsingSession()
    @State private var prefetcher = PhotoNeighborPrefetcher()
    @State private var photoSwitchDirection = PhotoSwitchDirection.forward
    @State private var locationDestination: PhotoGlobeDestination?
    @StateObject private var playback = PhotoDetailPlaybackModel()
    private enum FocusTarget: Hashable {
        case photo, globe, playback, imageRetry, pageRetry
    }
    @FocusState private var focus: FocusTarget?

    var body: some View {
        ZStack {
            detail
                .opacity(locationDestination == nil ? 1 : 0)
                .disabled(locationDestination != nil)
                .accessibilityHidden(locationDestination != nil)
            if let locationDestination, let locationLibrary {
                // Erase the nested view type: the same globe also presents
                // photo detail from its own wall.
                AnyView(GlobeView(model: locationLibrary, locationDestination: locationDestination) {
                    self.locationDestination = nil
                    focusPhoto()
                })
            }
        }
    }

    private var detailCanvas: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            ZStack {
                mediaSurface
                    .id(record.id)
                    .transition(photoSwitchTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(photoSwitchAnimation, value: record.id)
            .accessibilityHidden(!retryIsVisible)
            .onMoveCommand(perform: moveFocusOrPhoto)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(!retryIsVisible)
                    .focusable(!retryIsVisible)
                    .focusEffectDisabled()
                    .focused($focus, equals: .photo)
                    .onTapGesture {
                        if focus == .photo, playback.isPlayable { togglePlayback() }
                    }
                    .onMoveCommand(perform: moveFocusOrPhoto)
                    .accessibilityAddTraits(playback.isPlayable ? .isButton : [])
                    .accessibilityHint(playback.isPlayable ? playbackActionTitle : "")
                    .accessibilityLabel(mediaAccessibilityLabel)
                    .accessibilityValue(positionText)
                    .accessibilityIdentifier("photo-detail-image")
                if locationDestination == nil {
                    photoCaption
                }
            }

            playbackStatus

            if browsing.waitsForNextPage {
                VStack(spacing: 20) {
                    if let pagingError {
                        Text(pagingError).font(.system(size: 23))
                        Button(AppLocalization.string("common.reload", defaultValue: "Reload"), systemImage: "arrow.clockwise", action: loadMorePhotos)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .focused($focus, equals: .pageRetry)
                            .onAppear { focus = .pageRetry }
                            .onMoveCommand(perform: moveFocusOrPhoto)
                            .accessibilityIdentifier("photo-detail-page-retry")
                    } else {
                        ProgressView(AppLocalization.string("wall.loading", defaultValue: "Loading…"))
                            .tint(.white)
                    }
                }
                .padding(24)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .ignoresSafeArea()
    }

    private var detail: some View {
        detailCanvas
        .onAppear {
            playback.prepare(record)
            synchronizeBrowsing()
            focusPhoto()
        }
        .onChange(of: retryIsVisible) { _, visible in
            if visible { focus = .imageRetry }
            else if focus == .imageRetry || focus == nil { focusPhoto() }
        }
        .onChange(of: records) { _, _ in synchronizeBrowsing() }
        .onChange(of: record.id) { _, _ in
            retryIsVisible = false
            playback.prepare(record)
            browsing.select(record.id)
            updatePrefetch()
            requestNeighborPageIfNeeded()
            focusPhoto()
        }
        .onChange(of: isLoadingMorePhotos) { _, loading in
            // A strict viewport page can contain no matches. Continue from the
            // same frozen reader while a single right press is pending.
            if !loading, browsing.waitsForNextPage, pagingError == nil {
                if hasMorePhotos { loadMorePhotos() }
                else { browsing.cancelPendingAdvance() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, locationDestination == nil {
                playback.prepare(record)
                updatePrefetch()
            } else {
                playback.suspend()
                prefetcher.cancel()
            }
        }
        .task(id: record.placeID) { await resolvePlaceLabel() }
        .onPlayPauseCommand {
            guard locationDestination == nil, playback.isPlayable else { return }
            togglePlayback()
        }
        .onDisappear {
            prefetcher.cancel()
            playback.releaseContent()
        }
        .onExitCommand {
            if locationDestination == nil { close() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-detail")
    }

    private var mediaSurface: some View {
        ZStack {
            PhotoAssetImage(
                assetID: record.id,
                contentMode: .fit,
                targetSize: CGSize(width: 3_840, height: 2_160),
                allowsRetry: !playback.isPlayable,
                isActive: locationDestination == nil,
                priority: .detail,
                initialImage: initialImage,
                onRetryVisibilityChange: { visible in
                    if browsing.currentID == record.id { retryIsVisible = visible }
                }
            )
            .focused($focus, equals: .imageRetry)

            if let livePhoto = playback.livePhoto {
                LivePhotoPlaybackView(
                    livePhoto: livePhoto,
                    command: playback.liveCommand,
                    playbackModel: playback
                )
                .transition(.opacity)
            } else if let player = playback.player {
                PhotoVideoPlaybackView(player: player)
                    .transition(.opacity)
            }
        }
        .background(.black)
        .clipped()
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if playback.isLoading {
            VStack(spacing: 14) {
                if let progress = playback.progress {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 300)
                } else {
                    ProgressView()
                }
                Text(playbackLoadingText)
                    .font(.system(size: 23, weight: .medium))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .floatingSurface(in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 64)
            .padding(.bottom, 148)
            .allowsHitTesting(false)
        } else if playback.hasFailed {
            Label(
                AppLocalization.string("detail.playback_unavailable", defaultValue: "Playback unavailable · Press Play/Pause to retry"),
                systemImage: "exclamationmark.triangle"
            )
            .accessibilityIdentifier("photo-detail-motion-error")
            .font(.system(size: 22, weight: .medium))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .floatingSurface(in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 64)
            .padding(.bottom, 148)
            .allowsHitTesting(false)
        }
    }

    private var photoSwitchTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let distance: CGFloat = 140
        let incoming = photoSwitchDirection == .forward ? distance : -distance
        return .asymmetric(
            insertion: .offset(x: incoming).combined(with: .opacity),
            removal: .offset(x: -incoming).combined(with: .opacity)
        )
    }

    private var photoSwitchAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.26)
    }

    private var positionText: String {
        let position = Int64((browsing.currentPosition ?? 0) + 1)
        switch playback.kind {
        case .photo:
            return AppLocalization.format("detail.position", defaultValue: "Photo %lld", position)
        case .livePhoto:
            return AppLocalization.format("detail.position_live", defaultValue: "Live Photo %lld", position)
        case .video:
            return AppLocalization.format("detail.position_video", defaultValue: "Video %lld", position)
        }
    }

    private var playbackActionTitle: String {
        playback.isPlaying
            ? AppLocalization.string("detail.pause", defaultValue: "Pause")
            : AppLocalization.string("detail.play", defaultValue: "Play")
    }

    private var playbackLoadingText: String {
        switch playback.kind {
        case .livePhoto:
            return AppLocalization.string("detail.loading_live_photo", defaultValue: "Preparing Live Photo…")
        case .video:
            return AppLocalization.string("detail.loading_video", defaultValue: "Preparing video…")
        case .photo:
            return AppLocalization.string("detail.loading_photo", defaultValue: "Loading photo…")
        }
    }

    private var mediaKindText: String {
        switch playback.kind {
        case .photo: AppLocalization.string("detail.media_photo", defaultValue: "Photo")
        case .livePhoto: AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo")
        case .video: AppLocalization.string("detail.media_video", defaultValue: "Video")
        }
    }

    private var mediaAccessibilityLabel: String {
        AppLocalization.format(
            "wall.photo_accessibility",
            defaultValue: "%1$@, %2$@",
            mediaKindText,
            AppLocalization.shortDate(record.creationDate)
        )
    }

    private func togglePlayback() {
        if !playback.isPlaying, requestedMediaKinds.insert(playback.kind).inserted {
            ProductAnalytics.shared.capture(.detailPlaybackRequested, value: playback.kind == .video ? "video" : "livePhoto",
                                            context: .init(library: locationLibrary?.analyticsLibrary))
        }
        playback.toggle(record)
    }

    private func moveFocusOrPhoto(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: movePhoto(forward: false)
        case .right: movePhoto(forward: true)
        case .up where browsing.waitsForNextPage && pagingError != nil:
            focus = .pageRetry
        case .down where hasLocationButton:
            focus = .globe
        case .down where playback.isPlayable:
            focus = .playback
        default: break
        }
    }

    private func openLocation(_ destination: PhotoGlobeDestination) {
        browsing.cancelPendingAdvance()
        playback.suspend()
        prefetcher.cancel()
        locationDestination = destination
    }

    private func focusPhoto() {
        Task { @MainActor in
            await Task.yield()
            guard locationDestination == nil, !retryIsVisible else { return }
            focus = .photo
        }
    }

    private func synchronizeBrowsing() {
        let source = records.isEmpty ? [record] : records
        if let nextID = browsing.update(records: source, id: \.id, currentID: record.id),
           let position = browsing.positions[nextID], source.indices.contains(position) {
            photoSwitchDirection = .forward
            selectRecord(source[position])
        }
        updatePrefetch()
        requestNeighborPageIfNeeded()
    }

    private func movePhoto(forward: Bool) {
        switch browsing.move(forward: forward, hasMore: hasMorePhotos) {
        case .photo(let id):
            if let position = browsing.positions[id], records.indices.contains(position) {
                photoSwitchDirection = forward ? .forward : .backward
                playback.pause()
                selectRecord(records[position])
            }
        case .loadMore: loadMorePhotos()
        case .boundary: break
        }
    }

    private func requestNeighborPageIfNeeded() {
        guard hasMorePhotos, !isLoadingMorePhotos, pagingError == nil,
              let position = browsing.currentPosition,
              position >= browsing.orderedIDs.count - 3 else { return }
        loadMorePhotos()
    }

    private func updatePrefetch() {
        guard scenePhase == .active else { prefetcher.cancel(); return }
        let neighbors = browsing.neighborIDs.compactMap { id -> PhotoAssetRecord? in
            guard let position = browsing.positions[id], records.indices.contains(position) else { return nil }
            return records[position]
        }
        prefetcher.update(records: neighbors)
    }

    private var addressRequest: AddressRequest? {
        guard scenePhase == .active, !SamplePhotoResource.isSample(record.id) else { return nil }
        return AddressRequest(id: record.id, coordinate: record.coordinate, revision: addressRevision)
    }

    private var locationName: AttributedString? {
        if let cachedAddress, cachedAddress.request == addressRequest { return AttributedString(cachedAddress.text) }
        return placeLabel?.photoCaptionName
    }

    private var hasLocationButton: Bool {
        locationLibrary != nil && PhotoGlobeDestination(record: record) != nil
    }

    private var photoCaption: some View {
        HStack(alignment: .bottom, spacing: 22) {
            if locationLibrary != nil, let destination = PhotoGlobeDestination(record: record) {
                PhotoLocationGlobe(destination: destination, placeTitle: locationName.map { String($0.characters) }, isFocused: focus == .globe) {
                    openLocation(destination)
                }
                .focused($focus, equals: .globe)
            }
            PhotoCaptureCaption(
                date: record.creationDate,
                locationName: locationName,
                isFavorite: record.isFavorite,
                identifierPrefix: "photo-detail"
            )

            Spacer(minLength: 0)
            if playback.isPlayable {
                Button {
                    togglePlayback()
                } label: {
                    PlaybackButtonFace(symbol: playback.isPlaying ? "pause.fill" : "play.fill", isFocused: focus == .playback)
                }
                .buttonStyle(QuietPhotoButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .playback)
                .accessibilityLabel(playbackActionTitle)
                .accessibilityIdentifier("photo-detail-playback")
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                if retryIsVisible { focus = .imageRetry }
                else { focusPhoto() }
            case .right where playback.isPlayable: focus = .playback
            case .left where hasLocationButton: focus = .globe
            default: break
            }
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 48)
        .background(alignment: .bottomLeading) {
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.65), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)) { notice in
            if let changed = notice.userInfo?["changed"] as? Set<String>, changed.contains(record.id) {
                addressRevision &+= 1
            }
        }
        .task(id: addressRequest) {
            cachedAddress = nil
            guard let request = addressRequest else { return }
            let address = await Task.detached(priority: .utility) {
                PECachedPhotoAddress.read(identifier: request.id, latitude: request.coordinate.latitude, longitude: request.coordinate.longitude)
            }.value
            if !Task.isCancelled, request == addressRequest, let address { cachedAddress = (request, address) }
        }
    }
}

extension PlaceDisplayLabel {
    var photoCaptionName: AttributedString? {
        if hasCity { return styledName(citySize: 28) }
        return displayCountry.map { AttributedString($0) }
    }
}

struct PhotoCaptureCaption: View {
    let date: Date
    let locationName: AttributedString?
    var isFavorite = false
    var showsTime = true
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(showsTime ? date.formatted(.dateTime.year().month().day().hour().minute().locale(AppLocalization.locale))
                                   : AppLocalization.shortDate(date))
                    .font(.system(size: 23, weight: .medium))
                    .accessibilityIdentifier("\(identifierPrefix)-capture-time")
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.pink)
                        .accessibilityLabel(AppLocalization.string("detail.favorited", defaultValue: "Favorited"))
                        .accessibilityIdentifier("\(identifierPrefix)-favorite")
                }
            }
            if let locationName {
                Text(locationName)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                    .accessibilityIdentifier("\(identifierPrefix)-location-name")
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }
}

private enum PhotoSwitchDirection {
    case forward
    case backward
}
