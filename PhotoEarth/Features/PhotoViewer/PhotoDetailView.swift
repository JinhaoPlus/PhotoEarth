import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @State private var cachedAddress: (record: PhotoAssetRecord, text: String)?
    let record: PhotoAssetRecord
    let placeLabel: PlaceDisplayLabel?
    var initialImage: UIImage?
    var labelState: PlaceLabelLoadState?
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsInformation = false
    @State private var showsControls = false
    @State private var showsViewingHint = true
    @State private var retryIsVisible = false
    @State private var browsing = PhotoBrowsingSession()
    @State private var prefetcher = PhotoNeighborPrefetcher()
    @State private var photoSwitchDirection = PhotoSwitchDirection.forward
    @State private var locationDestination: PhotoGlobeDestination?
    @StateObject private var playback = PhotoDetailPlaybackModel()
    @FocusState private var isInfoButtonFocused: Bool
    @FocusState private var isPhotoFocused: Bool
    @FocusState private var isPlaybackButtonFocused: Bool
    @FocusState private var isShowControlsButtonFocused: Bool

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
                    focusPrimaryMediaAction()
                })
            }
        }
    }

    private var detailCanvas: some View {
        ZStack(alignment: .top) {
            Color.black
            ZStack(alignment: .trailing) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        mediaSurface
                            .id(record.id)
                            .transition(photoSwitchTransition)
                            .accessibilityHidden(!retryIsVisible)

                        // Keep the remote target in place while PhotoKit swaps
                        // the poster, progress, failure and playback views.
                        Color.clear
                            .contentShape(Rectangle())
                            .allowsHitTesting(!showsControls && !retryIsVisible)
                            .focusable(!showsControls && !retryIsVisible)
                            .focusEffectDisabled()
                            .focused($isPhotoFocused)
                            .onTapGesture {
                                guard isPhotoFocused, !showsControls, !retryIsVisible else { return }
                                if playback.isPlayable {
                                    showsViewingHint = false
                                    playback.toggle(record)
                                } else {
                                    revealControls()
                                }
                            }
                            .onMoveCommand { direction in
                                guard !showsControls, !retryIsVisible, isPhotoFocused else { return }
                                if direction == .left { movePhoto(forward: false) }
                                if direction == .right { movePhoto(forward: true) }
                                if direction == .up { revealControls() }
                                if direction == .down {
                                    if playback.isPlayable { focusPlaybackButton() }
                                    else { revealControls() }
                                }
                            }
                            .accessibilityLabel(mediaAccessibilityLabel)
                            .accessibilityHint(viewingAccessibilityHint)
                            .accessibilityValue(positionText)
                            .accessibilityIdentifier("photo-detail-image")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(photoSwitchAnimation, value: record.id)

                    if playback.isPlayable {
                        playbackButton
                            .padding(.trailing, showsInformation ? 540 : 80)
                            .padding(.bottom, 54)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsInformation {
                    informationPanel
                        .frame(width: 500)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }

            if showsControls {
                controls
                    .transition(.opacity)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        showControlsButton
                    }
                    Spacer()
                }
                    .padding(.horizontal, 80)
                    .padding(.top, 60)
                    .transition(.opacity)

                if showsViewingHint {
                    Text(viewingHintText)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .floatingSurface(in: Capsule())
                        .padding(.bottom, 48)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }

            if browsing.waitsForNextPage {
                VStack(spacing: 20) {
                    if let pagingError {
                        Text(pagingError).font(.system(size: 23))
                        Button(AppLocalization.string("common.reload", defaultValue: "Reload"), action: loadMorePhotos)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("photo-detail-page-retry")
                    } else {
                        ProgressView(AppLocalization.string("wall.loading", defaultValue: "Unfolding memories…"))
                            .tint(.white)
                    }
                }
                .padding(24)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 120)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var detail: some View {
        detailCanvas
        .onAppear {
            playback.prepare(record)
            synchronizeBrowsing()
            if voiceOverEnabled { revealControls() }
            else { focusPrimaryMediaAction() }
        }
        .onChange(of: records) { _, _ in synchronizeBrowsing() }
        .onChange(of: record.id) { _, _ in
            retryIsVisible = false
            playback.prepare(record)
            browsing.select(record.id)
            updatePrefetch()
            requestNeighborPageIfNeeded()
            if !voiceOverEnabled { focusPrimaryMediaAction() }
        }
        .onChange(of: playback.isPlayable) { _, _ in
            if !voiceOverEnabled { focusPrimaryMediaAction() }
        }
        .onChange(of: isLoadingMorePhotos) { _, loading in
            // A strict viewport page can contain no matches. Continue from the
            // same frozen reader while a single right press is pending.
            if !loading, browsing.waitsForNextPage, pagingError == nil {
                if hasMorePhotos { loadMorePhotos() }
                else { browsing.cancelPendingAdvance() }
            }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in if enabled { revealControls() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, locationDestination == nil {
                playback.prepare(record)
                updatePrefetch()
            } else {
                playback.suspend()
                prefetcher.cancel()
            }
        }
        .task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            // Only passive text expires. Focused controls, retry buttons and
            // information stay present until the user explicitly dismisses them.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { showsViewingHint = false }
        }
        .task(id: record.placeID) { await resolvePlaceLabel() }
        .onPlayPauseCommand {
            guard locationDestination == nil, playback.isPlayable else { return }
            playback.toggle(record)
        }
        .onDisappear {
            prefetcher.cancel()
            playback.releaseContent()
        }
        .onExitCommand {
            if locationDestination == nil { handleBack() }
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
                onRetryVisibilityChange: handleRetryVisibility
            )

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

            playbackStatus

            if playback.isPlayable, !playback.isPlaying, !playback.isLoading, !showsControls {
                mediaBadge
                    .padding(.leading, 80)
                    .padding(.bottom, 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(.black)
        .clipped()
    }

    @ViewBuilder
    private var mediaBadge: some View {
        if playback.kind == .livePhoto {
            Image(systemName: "livephoto")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 48, height: 48)
                .floatingSurface(in: Circle())
        } else {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                Text(mediaBadgeText)
            }
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .floatingSurface(in: Capsule())
        }
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
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 60)
            .allowsHitTesting(false)
        } else if playback.hasFailed {
            Label(
                AppLocalization.string("detail.playback_unavailable", defaultValue: "Motion unavailable · Press Play/Pause or open More Actions to retry"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 22, weight: .medium))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .floatingSurface(in: Capsule())
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 60)
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
                .allowsHitTesting(false)
            HStack {
                Spacer()
                Button { movePhoto(forward: false) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled((browsing.currentPosition ?? 0) == 0)
                .accessibilityLabel(AppLocalization.string("detail.previous", defaultValue: "Previous"))
                .accessibilityIdentifier("photo-detail-previous")
                Text(positionText)
                    .font(.system(size: 23, weight: .medium))
                    .padding(.horizontal, 12)
                Button { movePhoto(forward: true) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!hasMorePhotos && browsing.currentPosition == browsing.orderedIDs.count - 1)
                .accessibilityLabel(AppLocalization.string("detail.next", defaultValue: "Next"))
                .accessibilityIdentifier("photo-detail-next")
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { showsInformation.toggle() }
                } label: {
                    Label(showsInformation
                        ? AppLocalization.string("detail.hide_info", defaultValue: "Hide Info")
                        : AppLocalization.string("detail.photo_info", defaultValue: "Media Info"), systemImage: "info.circle")
                }
                .focused($isInfoButtonFocused)
                .accessibilityIdentifier("photo-information-toggle")
                .accessibilityValue(showsInformation
                    ? AppLocalization.string("state.expanded", defaultValue: "Expanded")
                    : AppLocalization.string("state.collapsed", defaultValue: "Collapsed"))
            }
            .font(.system(size: 23, weight: .medium))
            .buttonStyle(.glass)
            .padding(.horizontal, 80)
            .padding(.top, 60)

            if playback.kind == .video, playback.duration > 0, playback.player != nil {
                VStack(spacing: 8) {
                    ProgressView(value: min(playback.currentTime, playback.duration), total: playback.duration)
                        .progressViewStyle(.linear)
                        .frame(width: 560)
                    Text(verbatim: "\(AppLocalization.mediaDuration(playback.currentTime)) / \(AppLocalization.mediaDuration(playback.duration))")
                        .font(.system(size: 19, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.74))
                }
                .padding(.bottom, 58)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if locationLibrary != nil, locationDestination == nil,
                       let destination = PhotoGlobeDestination(record: record) {
                        PhotoLocationGlobe(destination: destination, placeTitle: globePlaceTitle, showsPlaceTitle: !showsInformation) {
                            openLocation(destination)
                        }
                    }
                    Spacer()
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
    }

    private var playbackButton: some View {
        Button {
            showsViewingHint = false
            playback.toggle(record)
        } label: {
            Label(playbackControlTitle, systemImage: playbackControlIcon)
        }
        .font(.system(size: 23, weight: .medium))
        .buttonStyle(.glass)
        // The playback model coalesces Select while loading. Keep the
        // button focusable so left/right can leave a pending or failed asset.
        .focused($isPlaybackButtonFocused)
        .onMoveCommand { direction in
            guard !showsControls else { return }
            if direction == .left { movePhoto(forward: false) }
            if direction == .right { movePhoto(forward: true) }
            if direction == .up { revealControls() }
        }
        .accessibilityIdentifier("photo-detail-playback")
    }

    private var showControlsButton: some View {
        Button(action: revealControls) {
            Label(
                AppLocalization.string("detail.show_controls", defaultValue: "More Actions"),
                systemImage: "ellipsis.circle"
            )
        }
        .font(.system(size: 23, weight: .medium))
        .buttonStyle(.glass)
        .focused($isShowControlsButtonFocused)
        .onMoveCommand { direction in
            guard !showsControls, !retryIsVisible, isShowControlsButtonFocused else { return }
            if direction == .left { movePhoto(forward: false) }
            if direction == .right { movePhoto(forward: true) }
            if direction == .down { focusPrimaryMediaAction() }
        }
        .accessibilityIdentifier("photo-detail-show-controls")
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

    private var playbackControlTitle: String {
        if playback.hasFailed {
            return AppLocalization.string("detail.retry_playback", defaultValue: "Try Motion Again")
        }
        return playback.isPlaying
            ? AppLocalization.string("detail.pause", defaultValue: "Pause")
            : AppLocalization.string("detail.play", defaultValue: "Play")
    }

    private var playbackControlIcon: String {
        if playback.hasFailed { return "arrow.clockwise" }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playbackLoadingText: String {
        switch playback.kind {
        case .livePhoto:
            return AppLocalization.string("detail.loading_live_photo", defaultValue: "Preparing Live Photo…")
        case .video:
            return AppLocalization.string("detail.loading_video", defaultValue: "Preparing video…")
        case .photo:
            return AppLocalization.string("wall.loading", defaultValue: "Unfolding memories…")
        }
    }

    private var mediaKindText: String {
        switch playback.kind {
        case .photo: AppLocalization.string("detail.media_photo", defaultValue: "Photo")
        case .livePhoto: AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo")
        case .video: AppLocalization.string("detail.media_video", defaultValue: "Video")
        }
    }

    private var mediaBadgeText: String {
        guard playback.kind == .video, playback.duration > 0 else { return mediaKindText }
        return "\(mediaKindText) · \(AppLocalization.mediaDuration(playback.duration))"
    }

    private var mediaAccessibilityLabel: String {
        AppLocalization.format(
            "wall.photo_accessibility",
            defaultValue: "%1$@, %2$@",
            mediaKindText,
            AppLocalization.shortDate(record.creationDate)
        )
    }

    private var viewingAccessibilityHint: String {
        viewingHintText
    }

    private var viewingHintText: String {
        playback.isPlayable
            ? AppLocalization.string("detail.playable_viewing_hint", defaultValue: "Left/right: Change memory · Center: Play/pause · Up: More actions")
            : AppLocalization.string("detail.viewing_hint", defaultValue: "Left/right: Change photo · Center: More actions")
    }

    private func handleRetryVisibility(_ visible: Bool) {
        retryIsVisible = visible
        guard visible else { return }
        // A retry is a native focus target, never a descendant competing with
        // the full-photo focus surface. Reveal navigation so the user can also
        // skip an unavailable photo; do not programmatically take retry focus.
        showsViewingHint = false
        showsControls = true
    }

    private func revealControls() {
        guard locationDestination == nil else { return }
        browsing.cancelPendingAdvance()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showsViewingHint = false
            showsControls = true
        }
        Task { @MainActor in
            await Task.yield()
            guard showsControls else { return }
            isInfoButtonFocused = true
        }
    }

    private func handleBack() {
        if showsControls && !retryIsVisible { hideControls() }
        else { close() }
    }

    private func openLocation(_ destination: PhotoGlobeDestination) {
        browsing.cancelPendingAdvance()
        playback.suspend()
        prefetcher.cancel()
        showsInformation = false
        showsControls = false
        locationDestination = destination
    }

    private func hideControls() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showsInformation = false
            showsControls = false
        }
        focusPrimaryMediaAction()
    }

    private func focusPhoto() {
        Task { @MainActor in
            await Task.yield()
            guard !showsControls, !retryIsVisible else { return }
            isPhotoFocused = true
        }
    }

    private func focusPrimaryMediaAction() {
        if playback.isPlayable { focusPlaybackButton() }
        else { focusPhoto() }
    }

    private func focusPlaybackButton() {
        Task { @MainActor in
            await Task.yield()
            guard playback.isPlayable, !showsControls, !retryIsVisible else { return }
            isPlaybackButtonFocused = true
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

    private var placeTitle: String {
        if let placeLabel, placeLabel.hasCity { return placeLabel.compactName }
        if labelState == .loading {
            return AppLocalization.string("place.loading", defaultValue: "Finding place…")
        }
        return placeLabel?.compactName ?? AppLocalization.unknownPlace(near: nil)
    }

    private var globePlaceTitle: String? {
        guard let placeLabel, placeLabel.hasCity || placeLabel.displayCountry != nil else { return nil }
        return placeLabel.compactName
    }

    private var informationPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(placeTitle)
                .font(.system(size: 42, weight: .semibold))
                .lineLimit(2)
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(height: 1)
                .padding(.vertical, 28)

            informationRow(icon: "calendar", title: AppLocalization.string("detail.capture_time", defaultValue: "Captured"), value: record.creationDate.formatted(.dateTime.year().month().day().hour().minute().locale(AppLocalization.locale)))
            informationRow(
                icon: playback.kind == .livePhoto ? "livephoto" : playback.kind == .video ? "video.fill" : "photo",
                title: AppLocalization.string("detail.media_type", defaultValue: "Media"),
                value: mediaKindText
            )
            if playback.kind == .video, playback.duration > 0 {
                informationRow(
                    icon: "clock",
                    title: AppLocalization.string("detail.duration", defaultValue: "Duration"),
                    value: AppLocalization.mediaDuration(playback.duration)
                )
            }
            if scenePhase == .active, cachedAddress?.record == record, let address = cachedAddress?.text {
                informationRow(icon: "mappin", title: AppLocalization.string("detail.photos_address", defaultValue: "Address in Photos"), value: address)
            }
            informationRow(
                icon: "mappin.and.ellipse",
                title: AppLocalization.string("detail.location", defaultValue: "Location"),
                value: String(
                    format: "%.4f°,  %.4f°",
                    locale: AppLocalization.locale,
                    arguments: [record.coordinate.latitude, record.coordinate.longitude]
                )
            )
            informationRow(icon: "aspectratio", title: AppLocalization.string("detail.dimensions", defaultValue: "Dimensions"), value: "\(record.pixelWidth) × \(record.pixelHeight)")
            informationRow(icon: record.isFavorite ? "heart.fill" : "heart", title: AppLocalization.string("detail.favorite", defaultValue: "Favorite"), value: record.isFavorite
                ? AppLocalization.string("detail.favorited", defaultValue: "Favorited")
                : AppLocalization.string("detail.not_favorited", defaultValue: "Not Favorited"))
        }
    }

    private var informationPanel: some View {
        ViewThatFits(in: .vertical) {
            informationPanelContent
            ScrollView { informationPanelContent }
        }
        .onDisappear { cachedAddress = nil }
        .task(id: scenePhase == .active ? record : nil) {
            cachedAddress = nil
            guard scenePhase == .active, !SamplePhotoResource.isSample(record.id) else { return }
            let asset = record
            let address = await Task.detached(priority: .utility) {
                PECachedPhotoAddress.read(identifier: asset.id, latitude: asset.coordinate.latitude, longitude: asset.coordinate.longitude)
            }.value
            if !Task.isCancelled, let address { cachedAddress = (asset, address) }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface(in: RoundedRectangle(cornerRadius: 32))
        .padding(.top, 144)
        .padding(.bottom, 48)
        .padding(.trailing, 48)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func informationRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(.cyan.opacity(0.9))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 23))
                    .foregroundStyle(.white.opacity(0.6))
                Text(value)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 28)
    }
}

private enum PhotoSwitchDirection {
    case forward
    case backward
}
