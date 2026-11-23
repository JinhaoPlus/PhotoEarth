import AVFoundation
import SwiftUI
import UIKit

@MainActor final class SlideshowPresentation {
    weak var current: EarthSlideshowCoordinator?
}

extension EnvironmentValues {
    @Entry var slideshowPresentation: SlideshowPresentation?
}

struct EarthSlideshowView: View {
    @Environment(\.slideshowPresentation) private var slideshowPresentation
    private struct MediaAvailabilityKey: Equatable {
        let id: String
        let paused: Bool
        let active: Bool
    }
    private enum WatchingControlFocus: Hashable {
        case slideshowPrevious
        case slideshowPlayPause
        case slideshowNext
        case nextJourney
        case slideshowSound
        case slideshowRestart
        case photo(String)
        case musicChoose
        case musicPrevious
        case musicPlayPause
        case musicNext
    }

    private enum OpeningFocus: Hashable {
        case play
        case soundtrack
        case trips
    }

    private enum OverlayPlayback {
        case holding(resume: Bool)
        case resumeOnForeground
    }

    @ObservedObject var coordinator: EarthSlideshowCoordinator
    var anniversaryPlaces = PhotoWallPlaces()
    var requestPlayback: ((JourneyEventContext.Music) -> Void)?
    let exit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.resetFocus) private var resetFocus
    @StateObject private var playback = PhotoDetailPlaybackModel(isMuted: true)
    @StateObject private var music = SlideshowMusicController.makeDefault()
    @State private var autoplayedAssetID: String?
    @State private var previousIdleTimerSetting: Bool?
    @State private var readyStaticAssetID: String?
    @State private var dwellSynchronizedAssetID: String?
    @State private var preparedFrames: [String: UIImage] = [:]
    @State private var controlAutoHideTask: Task<Void, Never>?
    @State private var controlsEntryFocus: WatchingControlFocus = .slideshowPlayPause
    @State private var pendingStartMusic: JourneyEventContext.Music?
    @State private var openingRevision = 0
    @State private var showsJourneyPicker = false
    @State private var showsMusicPicker = false
    @State private var didCommitMusicChoice = false
    @State private var showsExitConfirmation = false
    @State private var overlayPlayback: OverlayPlayback?
    @Namespace private var openingFocusScope
    @FocusState private var viewingSurfaceFocused: Bool
    @FocusState private var preparationStatusFocused: Bool
    @FocusState private var openingFocus: OpeningFocus?
    @FocusState private var primaryControlFocused: Bool
    @FocusState private var watchingControlFocus: WatchingControlFocus?
    private let controlDiameter: CGFloat = 52

    private var presentation: some View {
        ZStack {
            background

            imagePreloadLayer

            if coordinator.awaitsPlaybackConfirmation {
                openingView.id(openingRevision)
            } else {
                switch coordinator.phase {
                case .idle, .cancelled:
                    Color.clear
                case .preparing:
                    preparationView
                case .earthChapterBridge:
                    earthTransitionView
                case .earthIntro, .chapterTitle:
                    ZStack {
                        earthTransitionView
                        chapterView
                    }
                case .presentingItem, .transitioningItem:
                    mediaView
                        .id(coordinator.mediaRetryRevision)
                        .transition(.identity)
                case .ending:
                    endingView
                case .completed:
                    completedView
                case .failed(let message):
                    failedView(message)
                }
            }

            // Keep the direct-watching focus surface alive for the whole
            // presentation. Recreating it only after chrome faded out left a
            // brief tvOS Focus gap in which the next remote press was lost.
            if isWatching {
                remoteSurface
                    .disabled(showsWatchingControls)
            }

            if showsWatchingControls {
                watchingControls
                    .transition(.opacity)
            }

            if isWatching {
                watchingContext
                    .transition(.opacity)
            }

        }
        .ignoresSafeArea()
    }

    private var playbackPresentation: some View {
        presentation
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: coordinator.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: coordinator.awaitsPlaybackConfirmation)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: coordinator.showsControls)
        .onChange(of: scenePhase == .active && !coordinator.isPaused && coordinator.phase.keepsDisplayAwake,
                  initial: true) { _, keepsAwake in updateIdleTimer(keepsAwake) }
        .onAppear {
            slideshowPresentation?.current = coordinator
            if voiceOverEnabled { coordinator.showControls() }
            focusWatchingSurface()
            synchronizeMusicPlayback()
            music.prepareDefaultMusicIfNeeded()
        }
        .task {
            await music.activate()
            synchronizeMusicPlayback()
        }
        .onChange(of: coordinator.currentItem?.record.id, initial: true) { _, _ in
            prepareCurrentMedia()
        }
        .onChange(of: coordinator.collageTiles.map(\.id), initial: true) { _, ids in
            coordinator.markCollageDisplayed(ids)
        }
        .onChange(of: reduceMotion, initial: true) { _, enabled in coordinator.updateReduceMotion(enabled) }
        .onChange(of: coordinator.preloadsNextSingle) { _, _ in trimPreparedFrames() }
        .onChange(of: coordinator.preparingCollage) { _, _ in trimPreparedFrames() }
        .onChange(of: coordinator.mediaRetryRevision) { _, _ in
            playback.releaseContent()
            prepareCurrentMedia()
        }
        .onChange(of: coordinator.nextItemForPrefetch?.record.id, initial: true) { _, _ in
            playback.prefetch(coordinator.nextItemForPrefetch?.record)
            trimPreparedFrames()
        }
        .onChange(of: waitsForJourneyScope) { _, waiting in
            guard !waiting, let music = pendingStartMusic else { return }
            pendingStartMusic = nil
            if coordinator.awaitsPlaybackConfirmation && !showsMusicPicker && !showsJourneyPicker { requestPlayback?(music) }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if isWatching, !coordinator.showsControls { focusWatchingSurface() }
            if phase == .transitioningItem || phase == .presentingItem {
                if !coordinator.collageTiles.isEmpty {
                    coordinator.markCollageDisplayed(coordinator.collageTiles.map(\.id))
                } else if let id = coordinator.currentItem?.id, readyStaticAssetID == id {
                    coordinator.markCurrentItemReady(id, image: preparedFrames[id])
                }
                startDynamicMediaIfNeeded()
                synchronizeDynamicDwellIfNeeded()
                finishDynamicMediaIfNeeded()
            } else if phase != .transitioningItem {
                playback.pause()
            }
            trimPreparedFrames()
            synchronizeMusicPlayback()
        }
        .onChange(of: coordinator.isPaused) { _, paused in
            if paused {
                playback.pause()
            } else {
                if case .photo = watchingControlFocus { watchingControlFocus = .slideshowPlayPause }
                startDynamicMediaIfNeeded(resuming: true)
                finishDynamicMediaIfNeeded()
            }
            synchronizeMusicPlayback()
            refreshControlAutoHide()
        }
        .onChange(of: coordinator.soundEnabled) { _, _ in
            synchronizeMusicPlayback()
        }
        .onChange(of: coordinator.isBuffering) { _, buffering in
            if buffering { playback.pause() }
            synchronizeMusicPlayback()
        }
        .onChange(of: playback.isOriginalAudioReady) { _, _ in synchronizeMusicPlayback() }
        .onChange(of: playback.isPlaying) { _, playing in
            guard playing else { return }
            guard !coordinator.isPaused else {
                playback.pause()
                return
            }
        }
        .onChange(of: playback.hasStartedPlayback) { _, started in
            if started { synchronizeDynamicDwellIfNeeded() }
        }
        .onChange(of: playback.didFinishPlayback) { _, _ in
            finishDynamicMediaIfNeeded()
        }
        .onChange(of: playback.hasLoadedContent) { _, loaded in
            guard loaded, let record = coordinator.currentItem?.record,
                  playback.preparedAssetID == record.id else { return }
            startDynamicMediaIfNeeded()
        }
    }

    var body: some View {
        playbackPresentation
        .onChange(of: showsWatchingControls) { _, shown in
            if shown {
                let target = controlsEntryFocus
                controlsEntryFocus = .slideshowPlayPause
                Task { @MainActor in
                    await Task.yield()
                    guard showsWatchingControls else { return }
                    watchingControlFocus = target
                }
            } else {
                watchingControlFocus = nil
                focusWatchingSurface()
            }
            refreshControlAutoHide()
        }
        .onChange(of: watchingControlFocus) { previous, focus in
            if focus != nil, showsWatchingControls {
                if case .photo = focus {
                    // tvOS can briefly focus a thumbnail while moving down from the music panel.
                    // That press belongs to the playback bar. Entering the filmstrip takes another Down.
                    switch previous {
                    case .musicChoose, .musicPrevious, .musicPlayPause, .musicNext:
                        watchingControlFocus = .slideshowPlayPause
                    case nil:
                        // Restoring focus after a sheet can briefly land here without a Down press.
                        break
                    default:
                        if overlayPlayback == nil { coordinator.setPaused(true) }
                    }
                }
                refreshControlAutoHide()
            }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { coordinator.showControls() }
            refreshControlAutoHide()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.resumeAfterSuspension()
                resumePlaybackAfterOverlay()
                prepareCurrentMedia(resetPresentation: false)
                Task { @MainActor in
                    await music.refreshAccess()
                    synchronizeMusicPlayback()
                }
                synchronizeMusicPlayback()
                return
            }
            synchronizeMusicPlayback()
            playback.suspend()
            preparedFrames.removeAll()
            // Music authorization can temporarily make the scene inactive
            // while the picker is already holding playback.
            if phase == .background || !showsMusicPicker {
                coordinator.suspend()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)) { notice in
            if let changed = notice.userInfo?["changed"] as? Set<String>, !changed.isEmpty {
                preparedFrames = preparedFrames.filter { !changed.contains($0.key) }
                coordinator.invalidateEditedPhotos(changed)
            }
            if let removed = notice.userInfo?["removed"] as? Set<String> {
                preparedFrames = preparedFrames.filter { !removed.contains($0.key) }
                coordinator.removeAssets(removed)
            }
        }
        .onPlayPauseCommand {
            if !showsMusicPicker, !showsJourneyPicker, overlayPlayback == nil {
                noteControlInteraction()
                toggleViewerPlayback()
            }
        }
        .onExitCommand {
            if showsJourneyPicker {
                showsJourneyPicker = false
            } else if showsMusicPicker {
                cancelMusicPicker()
            } else if overlayPlayback != nil {
                return
            } else if showsWatchingControls {
                hideWatchingControls()
            } else if isWatching && !coordinator.awaitsPlaybackConfirmation {
                holdPlaybackForOverlay()
                showsExitConfirmation = true
            } else {
                leaveSlideshow()
            }
        }
        .onDisappear {
            updateIdleTimer(false)
            guard !showsMusicPicker, !showsJourneyPicker else { return }
            controlAutoHideTask?.cancel()
            music.stopAndReset()
            playback.releaseContent()
            preparedFrames.removeAll()
            coordinator.cancel()
        }
        .alert(AppLocalization.string("slideshow.exit.prompt", defaultValue: "Exit the slideshow?"),
               isPresented: $showsExitConfirmation) {
            Button(AppLocalization.string("slideshow.exit.stay", defaultValue: "Cancel"), role: .cancel) {}
                .accessibilityIdentifier("slideshow-exit-stay")
            Button(AppLocalization.string("slideshow.exit.confirm", defaultValue: "Exit"), role: .destructive) {
                overlayPlayback = nil
                leaveSlideshow()
            }
            .accessibilityIdentifier("slideshow-exit-confirm")
        }
        .onChange(of: showsExitConfirmation) { _, showing in
            if !showing {
                finishOverlayPlayback()
                focusWatchingSurface()
            }
        }
        .sheet(isPresented: $showsJourneyPicker, onDismiss: {
            openingRevision += 1
        }) {
            SlideshowJourneyPicker(coordinator: coordinator) { showsJourneyPicker = false }
        }
        .sheet(isPresented: $showsMusicPicker, onDismiss: finishMusicPicker) {
            SlideshowMusicSourceView(controller: music, dismiss: {
                didCommitMusicChoice = true
                showsMusicPicker = false
            }, cancel: cancelMusicPicker)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("earth-slideshow")
    }

    @ViewBuilder
    private var background: some View {
        switch coordinator.phase {
        case _ where coordinator.awaitsPlaybackConfirmation:
            Color.black.opacity(0.65)
        case .presentingItem, .transitioningItem:
            Color.black
        case .completed, .failed:
            Color.black.opacity(0.48)
        default:
            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// A collage owns its slot-sized frames. Only single-photo pages use full-canvas preloads.
    @ViewBuilder
    private var imagePreloadLayer: some View {
        if scenePhase == .active, !coordinator.preparingCollage, let current = coordinator.currentItem?.record {
            ZStack {
                if coordinator.collageTiles.isEmpty {
                    preloadImage(current, priority: .focus, revision: coordinator.mediaRetryRevision)
                        .id(coordinator.mediaRetryRevision)
                }
                if coordinator.phase != .transitioningItem, coordinator.preloadsNextSingle,
                   let next = coordinator.nextItemForPrefetch?.record,
                   next.id != current.id {
                    preloadImage(next, priority: .visible)
                }
            }
            .frame(width: 2, height: 2)
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func preloadImage(_ record: PhotoAssetRecord, priority: PhotoImagePriority,
                              revision: Int? = nil) -> some View {
        PhotoAssetImage(
            assetID: record.id,
            contentMode: .fit,
            targetSize: CGSize(width: 3_840, height: 2_160),
            allowsRetry: revision != nil,
            isActive: scenePhase == .active,
            priority: priority,
            initialImage: preparedFrames[record.id] ?? (coordinator.singlePreview?.id == record.id ? coordinator.singlePreview?.image : nil),
            onImageChange: { image in
                guard let image, revision == nil || revision == coordinator.mediaRetryRevision else { return }
                retainPreparedFrame(image, for: record.id)
                if coordinator.currentItem?.record.id == record.id {
                    currentMediaBecameReady(record)
                }
            },
            onRetryVisibilityChange: { visible in
                if visible, let revision, !record.mediaKind.isPlayable {
                    coordinator.markCurrentItemUnavailable(record.id, revision: revision)
                }
            }
        )
        .id("slideshow-preload-\(record.id)")
    }

    private var waitsForJourneyScope: Bool {
        requestPlayback != nil && coordinator.availableJourneys.isEmpty && coordinator.phase == .preparing
    }

    private var openingView: some View {
        VStack(spacing: 22) {
            Text(coordinator.scope.title)
                .font(.system(size: 54, weight: .semibold))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slideshow-opening-title")
            if coordinator.scope.kind == .library {
                Text(journeySelectionTitle)
                    .lineLimit(2)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("slideshow-opening-range")
            }
            HStack(spacing: TVControlLayout.actionSpacing) {
                if coordinator.scope.kind == .library {
                    journeyPickerButton
                        .layoutPriority(1)
                        .focused($openingFocus, equals: .trips)
                }
                EarthSlideshowEntryButton(title: AppLocalization.string("slideshow.begin", defaultValue: "Start Slideshow")) {
                    let soundtrack: JourneyEventContext.Music = music.selectedChoice == nil ? .none : (music.isUsingOnlineMusic ? .online : .appleMusic)
                    if waitsForJourneyScope { pendingStartMusic = soundtrack }
                    else if let requestPlayback { requestPlayback(soundtrack) }
                    else { coordinator.beginPlayback(music: soundtrack) }
                }
                .layoutPriority(1)
                .focused($openingFocus, equals: .play)
                .accessibilityIdentifier("slideshow-begin")

                Button {
                    coordinator.openedMusicPicker()
                    showsMusicPicker = true
                } label: {
                    Label(openingSoundtrackTitle, systemImage: "music.note")
                        .labelStyle(PageActionLabelStyle())
                }
                .buttonStyle(.glass)
                .focused($openingFocus, equals: .soundtrack)
                .accessibilityIdentifier("slideshow-opening-music")
            }
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 44)
        .padding(.vertical, 36)
        .floatingSurface(in: RoundedRectangle(cornerRadius: 32))
        .padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($openingFocus, .play, priority: .userInitiated)
        .focusScope(openingFocusScope)
        .task {
            await Task.yield()
            guard coordinator.awaitsPlaybackConfirmation, !showsMusicPicker else { return }
            resetFocus(in: openingFocusScope)
            openingFocus = .play
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-opening")
    }

    private var journeySelectionTitle: String {
        guard let ids = coordinator.selectedJourneyIDs else { return SlideshowJourneyPicker.allTrips }
        if ids.count == 1, let journey = coordinator.journeys.first {
            return "\(journey.routeTitle) · \(journey.dateTitle)"
        }
        return SlideshowJourneyPicker.selectionCount(ids.count)
    }

    private var journeyPickerButton: some View {
        Button { showsJourneyPicker = true } label: {
            Label(SlideshowJourneyPicker.title, systemImage: "checklist")
                .labelStyle(PageActionLabelStyle())
        }
        .buttonStyle(.glass)
        .disabled(coordinator.availableJourneys.isEmpty)
        .accessibilityIdentifier("slideshow-opening-trips")
    }

    private var openingSoundtrackTitle: String {
        if music.selectedChoice == nil && !music.automaticMusicEnabled {
            return AppLocalization.string("slideshow.music.none", defaultValue: "No Background Music")
        }
        return AppLocalization.format("slideshow.music.shortcut.current", defaultValue: "Soundtrack · %@",
                                      music.selectedChoice?.title ?? AppLocalization.string("slideshow.music.recommended", defaultValue: "Recommended"))
    }

    private var preparationView: some View {
        VStack(spacing: 26) {
            Spacer()
            SlideshowSymbol()
                .accessibilityHidden(true)
            Text(coordinator.scope.title)
                .font(.system(size: 42, weight: .semibold))
                .focusable()
                .focusEffectDisabled()
                .focused($preparationStatusFocused)
                .accessibilityIdentifier("slideshow-preparation-status")
            Text(preparationStatus)
                .font(.system(size: 27))
                .foregroundStyle(.white.opacity(0.78))
            ProgressView()
                .tint(.cyan)
                .scaleEffect(1.2)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($preparationStatusFocused, true)
        .onAppear { preparationStatusFocused = true }
    }

    private var earthTransitionView: some View {
        LinearGradient(
            colors: [.clear, .clear, .black.opacity(0.46)],
            startPoint: .top,
            endPoint: .bottom
        )
        .accessibilityLabel(
            coordinator.displayedChapter.map { PlaceDisplayLabel(place: $0.visit).displayCity }
                ?? coordinator.scope.title
        )
        .accessibilityIdentifier("slideshow-earth-transition")
    }

    private var chapterView: some View {
        GeometryReader { proxy in
            let canvasWidth = min(proxy.size.width, presentationScreenSize.width)
            let canvasHeight = min(proxy.size.height, presentationScreenSize.height)
            let canvasTopCorrection = max(0, -proxy.frame(in: .global).minY)

            if let chapter = coordinator.displayedChapter {
                VStack(alignment: .leading, spacing: 14) {
                    Text(PlaceDisplayLabel(place: chapter.visit).styledName(citySize: 82))
                        .font(.system(size: 82, weight: .ultraLight))
                        .lineLimit(2)
                    Text(AppLocalization.dateRange(from: chapter.visit.startDate, to: chapter.visit.endDate))
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .shadow(color: .black.opacity(0.75), radius: 12, y: 3)
                .padding(.horizontal, 96)
                .padding(.bottom, 104)
                .frame(width: canvasWidth, height: canvasHeight, alignment: .bottomLeading)
                .offset(y: canvasTopCorrection)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("slideshow-chapter")
            }
        }
        .allowsHitTesting(false)
        .transition(
            reduceMotion
                ? .opacity
                : .offset(y: 22).combined(with: .opacity)
        )
    }

    private var mediaView: some View {
        GeometryReader { proxy in
            let canvasWidth = min(proxy.size.width, presentationScreenSize.width)
            let canvasHeight = min(proxy.size.height, presentationScreenSize.height)
            let canvasTopCorrection = max(0, -proxy.frame(in: .global).minY)

            mediaCanvas
                .id(coordinator.visibilityRevision)
                .transition(.identity)
                .frame(width: canvasWidth, height: canvasHeight)
                .clipped()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .offset(y: canvasTopCorrection)
        }
    }

    private var mediaCanvas: some View {
        ZStack {
            if scenePhase == .active {
                SlideshowMediaTimeline(coordinator: coordinator, playback: playback, onDisplay: currentDynamicMediaBecameReady)
                if let item = coordinator.currentItem, !coordinator.preparingCollage, coordinator.collageTiles.isEmpty,
                   coordinator.canvasPage?.descriptor.ids != [item.id] {
                    // A movie can become displayable before Photos delivers its still cover.
                    if playback.preparedAssetID == item.id, let player = playback.player {
                        PhotoVideoPlaybackView(player: player, onDisplay: { currentDynamicMediaBecameReady(item.id) })
                            .opacity(0.001)
                    }
                    if coordinator.canvasPage == nil {
                        PhotoAssetImage(assetID: item.id, contentMode: .fit, targetSize: CGSize(width: 3840, height: 2160),
                            allowsRetry: true, priority: .detail, initialImage: preparedFrames[item.id],
                            onImageChange: { image in
                                if let image {
                                    retainPreparedFrame(image, for: item.id)
                                    currentMediaBecameReady(item.record)
                                }
                            })
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .task(id: MediaAvailabilityKey(id: coordinator.currentItem?.id ?? "", paused: coordinator.isPaused, active: scenePhase == .active)) {
            guard scenePhase == .active, !coordinator.isPaused, let id = coordinator.currentItem?.id else { return }
            let revision = coordinator.mediaRetryRevision
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            coordinator.markCurrentItemUnavailable(id, revision: revision)
        }
        .accessibilityLabel(currentMediaAccessibilityLabel)
        .accessibilityValue(currentMediaAccessibilityValue)
        .accessibilityIdentifier("slideshow-media")
    }

    private var endingView: some View {
        Text(coordinator.scope.title)
            .font(.system(size: 62, weight: .light))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
    }

    private var completedView: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(AppLocalization.string("slideshow.complete", defaultValue: "Your Slideshow Is Complete"))
                .font(.system(size: 52, weight: .light))
            Text(coordinator.scope.title)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.68))
            Spacer()
            Button {
                coordinator.restart()
            } label: {
                Label(AppLocalization.string("slideshow.replay", defaultValue: "Replay"), systemImage: "arrow.counterclockwise")
            }
            .focused($primaryControlFocused)
            .accessibilityIdentifier("slideshow-replay")
            .buttonStyle(.glass)
            .padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($primaryControlFocused, true)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.orange)
            Text(AppLocalization.string("slideshow.failed", defaultValue: "Slideshow Unavailable"))
                .font(.system(size: 44, weight: .semibold))
            Text(message)
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
            Spacer()
            if coordinator.selectedJourneyIDs != nil { journeyPickerButton }
            Button(AppLocalization.string("common.retry", defaultValue: "Try Again")) {
                coordinator.retry()
            }
            .accessibilityIdentifier("slideshow-retry")
            .focused($primaryControlFocused)
            .buttonStyle(.glass)
            .padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($primaryControlFocused, true)
    }

    private var watchingControls: some View {
        GeometryReader { proxy in
            let canvasWidth = min(proxy.size.width, presentationScreenSize.width)
            let canvasHeight = min(proxy.size.height, presentationScreenSize.height)
            // A full-screen cover can propose an overscan-expanded tvOS
            // coordinate space whose global origin sits above the physical
            // output. Keep controls on the real 16:9 canvas while media stays
            // full-bleed behind it.
            let canvasTopCorrection = max(0, -proxy.frame(in: .global).minY)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    soundtrackPanel
                }
                Spacer()
                slideshowPlaybackControls
                if showsPhotoSelection {
                    photoSelectionRail
                        .padding(.top, 20)
                }
            }
            .padding(.top, 58)
            .padding(.horizontal, 72)
            .padding(.bottom, 52)
            .frame(width: canvasWidth, height: canvasHeight)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .offset(y: canvasTopCorrection)
        }
        .background {
            Color.black.opacity(0.08)
                .allowsHitTesting(false)
        }
        .onMoveCommand { direction in
            noteControlInteraction()
            if direction == .up, isPhotoSelectionFocused {
                watchingControlFocus = .slideshowPlayPause
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-controls")
    }

    private var slideshowPlaybackControls: some View {
        HStack(spacing: TVControlLayout.toolbarSpacing) {
            iconControlButton(
                AppLocalization.string("slideshow.previous", defaultValue: "Previous"),
                systemImage: "backward.fill",
                focus: .slideshowPrevious,
                identifier: "slideshow-previous"
            ) {
                coordinator.move(forward: false)
            }
            iconControlButton(
                coordinator.isPaused
                    ? AppLocalization.string("slideshow.resume", defaultValue: "Resume")
                    : AppLocalization.string("slideshow.pause", defaultValue: "Pause"),
                systemImage: coordinator.isPaused ? "play.fill" : "pause.fill",
                focus: .slideshowPlayPause,
                identifier: "slideshow-play-pause"
            ) {
                toggleViewerPlayback()
            }
            iconControlButton(
                AppLocalization.string("slideshow.next", defaultValue: "Next"),
                systemImage: "forward.fill",
                focus: .slideshowNext,
                identifier: "slideshow-next"
            ) {
                coordinator.move(forward: true)
            }
            if coordinator.canSkipToNextJourney {
                nextJourneyButton
            }
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: 1, height: 25)
                .accessibilityHidden(true)
            iconControlButton(
                coordinator.soundEnabled
                    ? AppLocalization.string("slideshow.sound_off", defaultValue: "Mute Original Sound")
                    : AppLocalization.string("slideshow.sound_on", defaultValue: "Play Original Sound"),
                systemImage: coordinator.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                focus: .slideshowSound,
                identifier: "slideshow-sound"
            ) {
                coordinator.soundEnabled.toggle()
            }
            iconControlButton(
                AppLocalization.string("slideshow.restart", defaultValue: "Restart"),
                systemImage: "arrow.counterclockwise",
                focus: .slideshowRestart,
                identifier: "slideshow-restart"
            ) {
                coordinator.restart()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .floatingSurface(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-playback-controls")
        .onMoveCommand { direction in
            switch direction {
            case .up:
                watchingControlFocus = .musicChoose
            case .down:
                if showsPhotoSelection, let id = coordinator.currentItem?.id {
                    coordinator.setPaused(true)
                    watchingControlFocus = .photo(id)
                } else {
                    coordinator.hideControls()
                }
            default:
                break
            }
        }
    }

    private var nextJourneyButton: some View {
        let focused = watchingControlFocus == .nextJourney
        return Button {
            noteControlInteraction()
            watchingControlFocus = .slideshowPlayPause
            coordinator.skipToNextJourney()
        } label: {
            Label(coordinator.scope.kind == .anniversary ? String(localized: "anniversary.next_year") : AppLocalization.string("slideshow.next_journey", defaultValue: "Next Trip"),
                  systemImage: "forward.end.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(focused ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: controlDiameter)
                .background(focused ? Color.white : Color.black.opacity(0.28), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($watchingControlFocus, equals: .nextJourney)
        .scaleEffect(focused && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
        .accessibilityIdentifier("slideshow-next-journey")
        .onDisappear {
            if showsWatchingControls, watchingControlFocus == .nextJourney {
                watchingControlFocus = .slideshowPlayPause
            }
        }
    }

    private var showsPhotoSelection: Bool {
        coordinator.currentItem != nil && scenePhase == .active
    }

    private var isPhotoSelectionFocused: Bool {
        if case .photo = watchingControlFocus { return true }
        return false
    }

    private var photoSelectionRail: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(coordinator.filmstrip) { item in
                        photoSelectionButton(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 5)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.center, for: .alignment)
            .onChange(of: filmstripAnchorID, initial: true) { _, id in
                coordinator.prepareFilmstrip(around: id)
                guard let id, !isPhotoSelectionFocused else { return }
                scroll.scrollTo(id, anchor: .center)
            }
            .onDisappear { coordinator.prepareFilmstrip(around: nil) }
        }
        .frame(height: 96)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("slideshow.select_memory", defaultValue: "Choose a Photo or Video"))
        .accessibilityIdentifier("slideshow-photo-selection")
    }

    private var filmstripAnchorID: String? {
        if case let .photo(id) = watchingControlFocus { return id }
        return coordinator.currentItem?.id
    }

    private func photoSelectionButton(_ record: EarthSlideshowCoordinator.FilmstripItem) -> some View {
        let isCurrent = coordinator.currentItem?.id == record.id || coordinator.collageTiles.contains { $0.id == record.id }
        let isFocused = watchingControlFocus == .photo(record.id)
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button {
            coordinator.setPaused(true)
            coordinator.selectPausedItem(record.id)
        } label: {
            PhotoAssetImage(
                assetID: record.id,
                targetSize: CGSize(width: 264, height: 164)
            )
            .frame(width: isCurrent ? 132 : 106, height: isCurrent ? 82 : 66)
            .clipShape(shape)
            .brightness(isCurrent || isFocused ? 0 : -0.16)
            .overlay {
                shape.strokeBorder(.white.opacity(isCurrent || isFocused ? 1 : 0.22),
                                   lineWidth: isCurrent ? 4 : isFocused ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.44), radius: isFocused ? 8 : 3, y: 3)
            .contentShape([.interaction, .accessibility], shape)
            .accessibilityHidden(true)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($watchingControlFocus, equals: .photo(record.id))
        .scaleEffect(isFocused && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        .accessibilityLabel(itemStatus(date: record.date, kind: record.mediaKind))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("slideshow-select-photo-\(record.id)")
    }

    private var soundtrackButton: some View {
        let focused = watchingControlFocus == .musicChoose
        let hasSoundtrack = music.selectedChoice != nil
        let title = hasSoundtrack
            ? AppLocalization.string("slideshow.music.change", defaultValue: "Change Music")
            : AppLocalization.string("slideshow.music.choose", defaultValue: "Choose Music")
        return Button {
            noteControlInteraction()
            holdPlaybackForOverlay()
            showsMusicPicker = true
            refreshControlAutoHide()
        } label: {
            Label(title, systemImage: "music.note.list")
                .labelStyle(.iconOnly)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(focused ? .black : .white)
                .frame(width: 54, height: 54)
                .background(focused ? Color.white : Color.white.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($watchingControlFocus, equals: .musicChoose)
        .accessibilityLabel(title)
        .accessibilityIdentifier("slideshow-playback-music")
        .accessibilityHint(music.playbackError ?? "")
        .accessibilityValue(Text(verbatim: ProcessInfo.processInfo.arguments.contains("--slideshow-observe-music")
            ? (music.isActuallyPlaying ? "playing" : "paused") : ""))
        .onMoveCommand { direction in
            switch direction {
            case .down: watchingControlFocus = .slideshowPlayPause
            case .up where music.selectedChoice != nil: watchingControlFocus = .musicPlayPause
            default: break
            }
        }
    }

    private var soundtrackPanel: some View {
        let hasSoundtrack = music.selectedChoice != nil
        let shape = RoundedRectangle(cornerRadius: hasSoundtrack ? 20 : 27)
        return VStack(alignment: .leading, spacing: 9) {
            if hasSoundtrack { soundtrackMetadata }
            HStack(spacing: 8) {
                if hasSoundtrack {
                    soundtrackTransport
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 1, height: 22)
                        .accessibilityHidden(true)
                }
                soundtrackButton
            }
            .frame(maxWidth: hasSoundtrack ? .infinity : nil, alignment: .center)
        }
        .padding(hasSoundtrack ? 12 : 0)
        .frame(width: hasSoundtrack ? 260 : nil)
        .background(.black.opacity(hasSoundtrack ? 0.32 : 0), in: shape)
        .floatingSurface(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("slideshow.music.control_title", defaultValue: "Background Music"))
        .accessibilityIdentifier("slideshow-music-controls")
    }

    private var soundtrackMetadata: some View {
        HStack(spacing: 11) {
            soundtrackArtwork
            VStack(alignment: .leading, spacing: 3) {
                Text(music.nowPlaying?.title ?? music.selectedChoice?.title ?? "")
                    .font(.system(size: 21, weight: .semibold))
                    .accessibilityIdentifier("slideshow-music-title")
                if let subtitle = music.nowPlaying?.subtitle ?? music.selectedChoice?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.68))
                        .accessibilityIdentifier("slideshow-music-artist")
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let error = music.playbackError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(error)
            }
        }
    }

    private var soundtrackArtwork: some View {
        let placeholder = Image(systemName: "music.note")
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.09))
        return Group {
            if let track = music.nowPlaying?.onlineTrack {
                OnlineTrackArtwork(title: track.title, theme: track.themeID)
            } else if let url = music.nowPlaying?.artworkURL ?? music.selectedChoice?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
    }

    private var soundtrackTransport: some View {
        HStack(spacing: 8) {
            iconControlButton(
                AppLocalization.string("slideshow.music.previous", defaultValue: "Previous Song"),
                systemImage: "backward.end.fill", focus: .musicPrevious,
                identifier: "slideshow-music-previous", compact: true
            ) {
                Task { await music.skipToPrevious() }
            }
            iconControlButton(
                music.wantsMusicPlayback
                    ? AppLocalization.string("slideshow.music.pause", defaultValue: "Pause Music")
                    : AppLocalization.string("slideshow.music.play", defaultValue: "Play Music"),
                systemImage: music.wantsMusicPlayback ? "pause.fill" : "play.fill",
                focus: .musicPlayPause, identifier: "slideshow-music-play-pause", compact: true
            ) {
                music.toggleMusicPlayback()
            }
            iconControlButton(
                AppLocalization.string("slideshow.music.next", defaultValue: "Next Song"),
                systemImage: "forward.end.fill", focus: .musicNext,
                identifier: "slideshow-music-next", compact: true
            ) {
                Task { await music.skipToNext() }
            }
        }
        .onMoveCommand { if $0 == .down { watchingControlFocus = .slideshowPlayPause } }
    }

    private func iconControlButton(
        _ accessibilityLabel: String,
        systemImage: String,
        focus: WatchingControlFocus,
        identifier: String,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = watchingControlFocus == focus

        return Button {
            noteControlInteraction()
            action()
        } label: {
            if focus == .slideshowPlayPause {
                PlaybackButtonFace(symbol: systemImage, isFocused: isFocused)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 19 : 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .frame(width: compact ? 46 : controlDiameter, height: compact ? 46 : controlDiameter)
                    .background(isFocused ? Color.white : Color.black.opacity(compact ? 0 : 0.28), in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($watchingControlFocus, equals: focus)
        .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private var remoteSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable(true)
            .focusEffectDisabled()
            .focused($viewingSurfaceFocused)
            .onTapGesture { coordinator.toggleControls() }
            .onMoveCommand { direction in
                switch direction {
                case .left: coordinator.move(forward: false)
                case .right: coordinator.move(forward: true)
                case .up:
                    controlsEntryFocus = .musicChoose
                    coordinator.showControls()
                default: break
                }
            }
            .accessibilityLabel(currentMediaAccessibilityLabel)
            .accessibilityHint(AppLocalization.string(
                "slideshow.remote_hint",
                defaultValue: "Press left or right to skip, up for controls, or Play/Pause to pause or resume."
            ))
            .accessibilityIdentifier("slideshow-viewing-surface")
    }

    private var isWatching: Bool {
        switch coordinator.phase {
        case .earthIntro, .chapterTitle, .presentingItem, .transitioningItem, .earthChapterBridge, .ending:
            true
        default:
            false
        }
    }

    private var showsWatchingControls: Bool {
        isWatching && coordinator.showsControls
    }

    private var inspectingWithControls: Bool {
        showsWatchingControls && coordinator.isPaused && coordinator.inspectingPhoto
    }

    private var showsPhotoCaption: Bool {
        guard !showsWatchingControls || inspectingWithControls, coordinator.currentItem != nil else { return false }
        switch coordinator.phase {
        case .presentingItem, .transitioningItem:
            return true
        default:
            return false
        }
    }

    private var watchingContext: some View {
        GeometryReader { proxy in
            let canvasWidth = min(proxy.size.width, presentationScreenSize.width)
            let canvasHeight = min(proxy.size.height, presentationScreenSize.height)
            // Collection walls are presented in a tvOS full-screen cover. That
            // host can expose an overscan-expanded coordinate space whose
            // global origin is hundreds of points above the visible television
            // canvas. The interactive controls already neutralize that origin;
            // keep the passive location chrome on the same canvas
            // instead of letting it jump upward between presentation hosts.
            let canvasTopCorrection = max(0, -proxy.frame(in: .global).minY)

            ZStack(alignment: .topLeading) {
                if let page = coordinator.canvasPage {
                    watchingPhotoCaption(page)
                        .padding(.leading, 80)
                        // Leave the filmstrip and its playback controls below the inspected photo's caption.
                        .padding(.bottom, inspectingWithControls ? 272 : 52)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .opacity(showsPhotoCaption ? 1 : 0)
                        .accessibilityHidden(!showsPhotoCaption)
                }
                journeyContext
                    .padding(.leading, 72)
                    .padding(.top, 58)
            }
            .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .offset(y: canvasTopCorrection)
        }
        .allowsHitTesting(false)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.34),
            value: coordinator.currentItem?.record.id
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-immersive-chrome")
    }

    private func watchingPhotoCaption(_ page: SlideshowCanvasPage) -> some View {
        let record = page.record
        let place = coordinator.scope.kind == .anniversary ? record.placeID.flatMap { anniversaryPlaces[$0] } : page.visit
        let locationName = place.flatMap { PlaceDisplayLabel(place: $0).photoCaptionName }
        return HStack(alignment: .bottom, spacing: 22) {
            if page.descriptor.ids.count == 1, let destination = PhotoGlobeDestination(record: record) {
                SlideshowLocationGlobe(destination: destination, isVisible: showsPhotoCaption)
            }
            if showsPhotoCaption {
                PhotoCaptureCaption(
                    date: record.creationDate,
                    locationName: locationName,
                    showsTime: page.descriptor.ids.count == 1,
                    identifierPrefix: "slideshow"
                )
                .contentTransition(.opacity)
                .transition(.opacity)
            }
        }
    }

    private var journeyContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coordinator.journeys.count > 1, let index = coordinator.displayedJourneyIndex {
                SlideshowJourneyList(
                    journeys: coordinator.journeys,
                    currentIndex: index, yearsOnly: coordinator.scope.kind == .anniversary
                )
            }
            if coordinator.isBuffering {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .padding(9)
                    .background(.black.opacity(reduceTransparency ? 0.95 : 0.66), in: Circle())
                    .accessibilityLabel(AppLocalization.string(
                        "slideshow.loading_more", defaultValue: "Preparing the next memories…"))
            }
        }
    }

    /// The slideshow can be hosted in a presentation view whose unconstrained
    /// SwiftUI height is taller than the television output. Anchor persistent
    /// chrome to the active UIWindowScene's actual screen bounds so it cannot
    /// be laid out below the visible 16:9 canvas.
    private var presentationScreenSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen.bounds.size
            ?? scenes.first?.screen.bounds.size
            ?? CGSize(width: 1_920, height: 1_080)
    }

    private var preparationStatus: String {
        switch coordinator.preparation.stage {
        case .reading:
            return AppLocalization.string("slideshow.reading", defaultValue: "Loading photos…")
        case .analyzing:
            return AppLocalization.format(
                "slideshow.preparing_count",
                defaultValue: "Checked %1$lld of %2$lld · Ready to play: %3$lld",
                Int64(coordinator.preparation.analyzedCount),
                Int64(coordinator.preparation.candidateCount),
                Int64(coordinator.preparation.readyCount)
            )
        case .ready:
            return AppLocalization.format(
                "slideshow.ready_count",
                defaultValue: "%lld memories ready",
                Int64(coordinator.preparation.readyCount)
            )
        }
    }

    private func itemStatus(date: Date, kind mediaKind: PhotoMediaKind) -> String {
        let kind: String
        switch mediaKind {
        case .photo: kind = AppLocalization.string("detail.media_photo", defaultValue: "Photo")
        case .livePhoto: kind = AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo")
        case .video: kind = AppLocalization.string("detail.media_video", defaultValue: "Video")
        }
        return AppLocalization.format(
            "slideshow.item_status",
            defaultValue: "%1$@ · %2$@",
            AppLocalization.shortDate(date),
            kind
        )
    }

    private var currentMediaAccessibilityLabel: String {
        if let page = coordinator.canvasPage {
            if page.descriptor.ids.count > 1 {
                return [PlaceDisplayLabel(place: page.visit).displayCity, AppLocalization.shortDate(page.record.creationDate),
                        AppLocalization.photoCount(page.descriptor.ids.count)].joined(separator: ", ")
            }
            return itemStatus(date: page.record.creationDate, kind: page.record.mediaKind)
        }
        return coordinator.currentChapter.map { PlaceDisplayLabel(place: $0.visit).displayCity } ?? coordinator.scope.title
    }

    private var currentMediaAccessibilityValue: String {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-transition-fixture"), let page = coordinator.canvasPage {
            let transition = coordinator.observedTransition
            return "\(page.record.id) \(transition?.kind.rawValue ?? "opening") \(Int(((transition?.duration ?? 0) * 1000).rounded()))"
        }
        if ProcessInfo.processInfo.arguments.contains("--slideshow-observe-media") {
            return coordinator.lastViewedAssetID == coordinator.currentItem?.id ? coordinator.lastViewedAssetID ?? "" : ""
        }
#endif
        return ""
    }

    private func retainPreparedFrame(_ image: UIImage, for assetID: String) {
        let allowed = preparedFrameIDs
        guard allowed.contains(assetID) else { return }
        var retained = preparedFrames.filter { allowed.contains($0.key) }
        retained[assetID] = image
        preparedFrames = retained
        coordinator.releaseSinglePreview(for: assetID)
    }

    private func trimPreparedFrames() {
        let allowed = preparedFrameIDs
        preparedFrames = preparedFrames.filter { allowed.contains($0.key) }
    }

    private var preparedFrameIDs: Set<String> {
        guard let currentID = coordinator.currentItem?.record.id else { return [] }
        var ids: Set<String> = coordinator.collageTiles.isEmpty && !coordinator.preparingCollage ? [currentID] : []
        if coordinator.phase != .transitioningItem, coordinator.preloadsNextSingle,
           let nextID = coordinator.nextItemForPrefetch?.record.id {
            ids.insert(nextID)
        }
        return ids
    }

    private func prepareCurrentMedia(resetPresentation: Bool = true) {
        if resetPresentation {
            autoplayedAssetID = nil
            readyStaticAssetID = nil
            dwellSynchronizedAssetID = nil
        }
        guard let record = coordinator.currentItem?.record else {
            playback.releaseContent()
            return
        }
        if playback.preparedAssetID != record.id, !playback.isMuted { playback.isMuted = true }
        playback.prepareForAutoplay(record)
        playback.prefetch(coordinator.nextItemForPrefetch?.record)
        if preparedFrames[record.id] != nil { currentMediaBecameReady(record) }
    }

    private func currentMediaBecameReady(_ record: PhotoAssetRecord) {
        guard coordinator.currentItem?.record.id == record.id else { return }
        readyStaticAssetID = record.id
        coordinator.markCurrentItemReady(record.id, image: preparedFrames[record.id])
        startDynamicMediaIfNeeded()
    }

    private func currentDynamicMediaBecameReady(_ assetID: String) {
        guard coordinator.currentItem?.id == assetID else { return }
        coordinator.markCurrentItemReady(assetID)
        synchronizeDynamicDwellIfNeeded()
        finishDynamicMediaIfNeeded()
    }

    private func startDynamicMediaIfNeeded(resuming: Bool = false) {
        guard !coordinator.isPaused, scenePhase == .active,
              coordinator.phase == .presentingItem, !coordinator.isBuffering,
              let record = coordinator.currentItem?.record,
              playback.preparedAssetID == record.id,
              record.mediaKind.isPlayable,
              readyStaticAssetID == record.id || playback.hasLoadedContent else { return }
        if autoplayedAssetID == record.id {
            if resuming, !playback.isPlaying, !playback.didFinishPlayback, !playback.hasFailed {
                playback.toggle(record)
            }
            return
        }
        autoplayedAssetID = record.id
        playback.prepareForAutoplay(record)
        playback.toggle(record)
    }

    private func synchronizeDynamicDwellIfNeeded() {
        guard coordinator.phase == .presentingItem, playback.hasStartedPlayback,
              !playback.didFinishPlayback,
              let assetID = coordinator.currentItem?.record.id,
              coordinator.lastViewedAssetID == assetID,
              playback.preparedAssetID == assetID,
              dwellSynchronizedAssetID != assetID else { return }
        dwellSynchronizedAssetID = assetID
        coordinator.synchronizeDwellWithDynamicPlayback(assetID)
    }

    private func finishDynamicMediaIfNeeded() {
        guard playback.didFinishPlayback, let assetID = playback.preparedAssetID else { return }
        coordinator.dynamicPlaybackDidFinish(assetID)
    }

    private func focusWatchingSurface() {
        Task { @MainActor in
            await Task.yield()
            guard isWatching, !coordinator.showsControls else { return }
            viewingSurfaceFocused = true
        }
    }

    private func cancelMusicPicker() {
        music.cancelSelection()
        showsMusicPicker = false
    }

    private func finishMusicPicker() {
        music.cancelSelection()
        finishOverlayPlayback()
        refreshControlAutoHide()
        let committed = didCommitMusicChoice
        didCommitMusicChoice = false
        if coordinator.awaitsPlaybackConfirmation, committed {
            openingRevision += 1
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard !showsMusicPicker else { return }
            if coordinator.awaitsPlaybackConfirmation {
                openingFocus = .soundtrack
            } else if showsWatchingControls {
                watchingControlFocus = .musicChoose
            }
        }
    }

    private func holdPlaybackForOverlay() {
        guard overlayPlayback == nil else { return }
        overlayPlayback = .holding(resume: !coordinator.isPaused)
        coordinator.setPaused(true)
        synchronizeMusicPlayback()
    }

    private func finishOverlayPlayback() {
        if case .holding(let resume) = overlayPlayback {
            overlayPlayback = resume ? .resumeOnForeground : nil
        }
        resumePlaybackAfterOverlay()
    }

    private func resumePlaybackAfterOverlay() {
        guard case .resumeOnForeground = overlayPlayback, scenePhase == .active else { return }
        overlayPlayback = nil
        coordinator.setPaused(false)
    }

    private func synchronizeMusicPlayback() {
        let originalAudioActive = coordinator.soundEnabled
            && coordinator.phase == .presentingItem
            && !coordinator.isPaused
            && !coordinator.isBuffering
            && scenePhase == .active
            && playback.preparedAssetID == coordinator.currentItem?.id
            && playback.isOriginalAudioReady
        if !originalAudioActive, !playback.isMuted { playback.isMuted = true }
        music.updatePlaybackContext(
            slideshowPaused: coordinator.isPaused,
            presentationActive: !coordinator.awaitsPlaybackConfirmation && musicPresentationActive,
            originalAudioActive: originalAudioActive,
            sceneActive: scenePhase == .active
        )
        if originalAudioActive, playback.isMuted { playback.isMuted = false }
    }

    private var musicPresentationActive: Bool {
        switch coordinator.phase {
        case .earthIntro, .chapterTitle, .presentingItem, .transitioningItem,
             .earthChapterBridge, .ending:
            true
        default:
            false
        }
    }

    private func noteControlInteraction() {
        guard showsWatchingControls else { return }
        refreshControlAutoHide()
    }

    private func toggleViewerPlayback() {
        coordinator.togglePause()
        if coordinator.isPaused && isWatching { coordinator.showControls() }
    }

    private func hideWatchingControls() {
        controlAutoHideTask?.cancel()
        controlAutoHideTask = nil
        coordinator.hideControls()
    }

    /// While the slideshow is advancing, controls behave like native TV
    /// playback chrome: interaction grants a short reading window and then the
    /// photograph becomes visually dominant again. Paused and assistive modes
    /// deliberately keep controls stable until the user dismisses them.
    private func refreshControlAutoHide() {
        controlAutoHideTask?.cancel()
        controlAutoHideTask = nil
        guard showsWatchingControls,
              !coordinator.isPaused,
              !showsMusicPicker,
              !voiceOverEnabled else { return }

        controlAutoHideTask = Task { @MainActor in
            do { try await Task.sleep(for: controlAutoHideDelay) } catch { return }
            guard !Task.isCancelled,
                  showsWatchingControls,
                  !coordinator.isPaused,
                  !showsMusicPicker,
                  !voiceOverEnabled else { return }
            hideWatchingControls()
        }
    }

    private var controlAutoHideDelay: Duration {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-fast-controls-fixture") {
            return .seconds(3)
        }
#endif
        return .seconds(6)
    }

    private func updateIdleTimer(_ keepsAwake: Bool) {
        if keepsAwake {
            if previousIdleTimerSetting == nil { previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previous = previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previous
            previousIdleTimerSetting = nil
        }
    }

    private func leaveSlideshow() {
        controlAutoHideTask?.cancel()
        music.stopAndReset()
        playback.releaseContent()
        coordinator.cancel()
        exit()
    }
}

private struct SlideshowLocationGlobe: View {
    let destination: PhotoGlobeDestination
    let isVisible: Bool

    var body: some View {
        PhotoLocationMap(destination: destination, style: .slideshow, isVisible: isVisible)
            .frame(width: 280, height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.62), radius: 18, y: 8)
            .opacity(0.9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppLocalization.string(
                "detail.location_subtitle",
                defaultValue: "Where this memory was captured"
            ))
            .accessibilityIdentifier("slideshow-location-globe")
    }
}
