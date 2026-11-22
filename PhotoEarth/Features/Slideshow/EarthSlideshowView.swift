import AVFoundation
import SwiftUI
import UIKit

struct EarthSlideshowView: View {
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
    }

    private enum MusicPickerPlayback {
        case pausedWhileBrowsing(resume: Bool)
        case resumeOnForeground
    }

    @ObservedObject var coordinator: EarthSlideshowCoordinator
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
    @State private var showsMusicPicker = false
    @State private var musicPickerPlayback: MusicPickerPlayback?
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
                openingView
            } else {
                switch coordinator.phase {
                case .idle, .cancelled:
                    Color.clear
                case .preparing:
                    preparationView
                case .earthIntro, .earthChapterBridge:
                    earthTransitionView
                case .chapterTitle:
                    chapterView
                case .presentingItem, .transitioningItem:
                    mediaView
                        .id(coordinator.mediaRetryRevision)
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
            if voiceOverEnabled { coordinator.showControls() }
            focusWatchingSurface()
            synchronizeMusicPlayback()
        }
        .task {
            await music.activate()
            synchronizeMusicPlayback()
        }
        .onChange(of: coordinator.currentItem?.record.id, initial: true) { _, _ in
            prepareCurrentMedia()
        }
        .onChange(of: coordinator.mediaRetryRevision) { _, _ in
            playback.releaseContent()
            prepareCurrentMedia()
        }
        .onChange(of: coordinator.nextItemForPrefetch?.record.id, initial: true) { _, _ in
            playback.prefetch(coordinator.nextItemForPrefetch?.record)
            trimPreparedFrames()
        }
        .onChange(of: coordinator.phase) { _, phase in
            if isWatching, !coordinator.showsControls { focusWatchingSurface() }
            if phase == .presentingItem {
                if let id = coordinator.currentItem?.id, readyStaticAssetID == id {
                    coordinator.markCurrentItemReady(id)
                }
                startDynamicMediaIfNeeded()
                synchronizeDynamicDwellIfNeeded()
                finishDynamicMediaIfNeeded()
            } else if phase != .transitioningItem {
                playback.pause()
            }
            trimPreparedFrames()
            synchronizeMusicPlayback()
            refreshControlAutoHide()
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
        .onChange(of: watchingControlFocus) { _, focus in
            if focus != nil, showsWatchingControls {
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
                resumePlaybackAfterMusicPicker()
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
            // Music authorization can temporarily make the scene inactive
            // while the picker is already holding playback.
            if phase == .background || !showsMusicPicker {
                coordinator.suspend()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)) { notice in
            if let removed = notice.userInfo?["removed"] as? Set<String> {
                coordinator.removeAssets(removed)
            }
        }
        .onPlayPauseCommand {
            if !showsMusicPicker, musicPickerPlayback == nil {
                noteControlInteraction()
                toggleViewerPlayback()
            }
        }
        .onExitCommand {
            if showsMusicPicker {
                cancelMusicPicker()
            } else if musicPickerPlayback != nil {
                return
            } else if showsWatchingControls {
                hideWatchingControls()
            } else {
                leaveSlideshow()
            }
        }
        .onDisappear {
            updateIdleTimer(false)
            guard !showsMusicPicker else { return }
            controlAutoHideTask?.cancel()
            music.stopAndReset()
            playback.releaseContent()
            preparedFrames.removeAll()
            coordinator.cancel()
        }
        .sheet(isPresented: $showsMusicPicker, onDismiss: finishMusicPicker) {
            SlideshowMusicSourceView(controller: music, dismiss: { showsMusicPicker = false }, cancel: cancelMusicPicker)
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

    /// Two decoded stills are the entire visual look-ahead budget: the memory
    /// about to be shown and, once an outgoing transition has settled, its
    /// successor. The shared scheduler deduplicates these requests with the
    /// visible image surface and keeps them inside the global 4/2 budget.
    @ViewBuilder
    private var imagePreloadLayer: some View {
        if scenePhase == .active, let current = coordinator.currentItem?.record {
            ZStack {
                preloadImage(current, priority: .focus, revision: coordinator.mediaRetryRevision)
                    .id(coordinator.mediaRetryRevision)
                if coordinator.phase != .transitioningItem,
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
            isActive: scenePhase == .active,
            priority: priority,
            initialImage: preparedFrames[record.id],
            onImageChange: { image in
                guard let image, revision == nil || revision == coordinator.mediaRetryRevision else { return }
                retainPreparedFrame(image, for: record.id)
                if coordinator.currentItem?.record.id == record.id {
                    currentMediaBecameReady(record)
                }
            }
        )
        .id("slideshow-preload-\(record.id)")
    }

    private var openingView: some View {
        VStack(spacing: 22) {
            Text(coordinator.scope.title)
                .font(.system(size: 54, weight: .semibold))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slideshow-opening-title")
            HStack(spacing: TVControlLayout.actionSpacing) {
                Button {
                    coordinator.beginPlayback(music: music.selectedChoice == nil ? .none : (music.isUsingOnlineMusic ? .online : .appleMusic))
                } label: {
                    Label(AppLocalization.string("slideshow.begin", defaultValue: "Start Slideshow"),
                          systemImage: "play.fill")
                        .labelStyle(PageActionLabelStyle())
                }
                .buttonStyle(.glassProminent)
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
        .frame(maxWidth: 1060)
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

    private var openingSoundtrackTitle: String {
        if let title = music.selectedChoice?.title {
            AppLocalization.format("slideshow.music.shortcut.current", defaultValue: "Soundtrack · %@", title)
        } else {
            AppLocalization.string("slideshow.music.choose", defaultValue: "Choose Soundtrack")
        }
    }

    private var preparationView: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 62, weight: .ultraLight))
                .foregroundStyle(.cyan)
            Text(AppLocalization.string("slideshow.preparing", defaultValue: "Preparing Your Slideshow"))
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
            colors: [.clear, .clear, .black.opacity(0.2)],
            startPoint: .top,
            endPoint: .bottom
        )
        .accessibilityLabel(
            coordinator.currentChapter.map { PlaceDisplayLabel(place: $0.visit).displayCity }
                ?? coordinator.scope.title
        )
        .accessibilityIdentifier("slideshow-earth-transition")
    }

    private var chapterView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            if let chapter = coordinator.currentChapter {
                Text(PlaceDisplayLabel(place: chapter.visit).styledName(citySize: 82))
                    .font(.system(size: 82, weight: .ultraLight))
                    .lineLimit(2)
                Text(AppLocalization.dateRange(from: chapter.visit.startDate, to: chapter.visit.endDate))
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.76))
            }
            Spacer().frame(height: 104)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 96)
        .transition(
            reduceMotion
                ? .opacity
                : .offset(y: 22).combined(with: .opacity)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("slideshow-chapter")
    }

    private var mediaView: some View {
        GeometryReader { proxy in
            let canvasWidth = min(proxy.size.width, presentationScreenSize.width)
            let canvasHeight = min(proxy.size.height, presentationScreenSize.height)
            let canvasTopCorrection = max(0, -proxy.frame(in: .global).minY)

            mediaCanvas
                .frame(width: canvasWidth, height: canvasHeight)
                .clipped()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .offset(y: canvasTopCorrection)
        }
    }

    private var mediaCanvas: some View {
        ZStack {
            if let item = coordinator.currentItem {
                let revision = coordinator.mediaRetryRevision
                CinematicSlideshowMediaLayer(
                    item: item,
                    initialImage: preparedFrames[item.record.id],
                    playback: playback,
                    reduceMotion: reduceMotion,
                    isPaused: coordinator.isPaused,
                    motionDuration: cinematicMotionDuration(for: item.record),
                    isActive: scenePhase == .active,
                    onImageChange: { image in
                        guard let image, revision == coordinator.mediaRetryRevision else { return }
                        retainPreparedFrame(image, for: item.record.id)
                        currentMediaBecameReady(item.record)
                    },
                    onDynamicDisplay: {
                        guard revision == coordinator.mediaRetryRevision else { return }
                        currentDynamicMediaBecameReady(item.record.id)
                    },
                    onFullFrameUnavailable: {
                        if !item.record.mediaKind.isPlayable {
                            coordinator.markCurrentItemUnavailable(item.record.id, revision: revision)
                        }
                    }
                )
                .id(item.record.id)
                .zIndex(Double(coordinator.presentationOrder))
                .transition(itemTransition(item.transition))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .task(id: MediaAvailabilityKey(id: item.id, paused: coordinator.isPaused, active: scenePhase == .active)) {
                    guard scenePhase == .active, !coordinator.isPaused else { return }
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    coordinator.markCurrentItemUnavailable(item.record.id, revision: revision)
                }

                if coordinator.phase == .transitioningItem,
                   item.transition.kind == .dateReveal {
                    cinematicDateReveal(item.record.creationDate)
                        .zIndex(Double(coordinator.presentationOrder) + 0.5)
                        .transition(.opacity.animation(.easeInOut(duration: 0.52)))
                }
            }
        }
        .animation(mediaAnimation, value: coordinator.currentItem?.record.id)
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
                    if music.selectedChoice != nil {
                        soundtrackPanel
                    } else {
                        soundtrackButton
                            .floatingSurface(in: Capsule())
                    }
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
            Label(AppLocalization.string("slideshow.next_journey", defaultValue: "Next Trip"),
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
        coordinator.isPaused && coordinator.currentItem != nil
            && scenePhase == .active
    }

    private var isPhotoSelectionFocused: Bool {
        if case .photo = watchingControlFocus { return true }
        return false
    }

    private var photoSelectionRail: some View {
        HStack(spacing: 12) {
            ForEach(coordinator.selectionRecords) { record in
                photoSelectionButton(record)
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("slideshow.select_memory", defaultValue: "Choose a Photo"))
        .accessibilityIdentifier("slideshow-photo-selection")
    }

    private func photoSelectionButton(_ record: PhotoAssetRecord) -> some View {
        let isCurrent = coordinator.currentItem?.id == record.id
        let isFocused = watchingControlFocus == .photo(record.id)
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button {
            coordinator.selectPausedItem(record.id)
        } label: {
            PhotoAssetImage(
                assetID: record.id,
                targetSize: CGSize(width: 280, height: 176)
            )
            .frame(width: 126, height: 80)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(isFocused ? 1 : isCurrent ? 0.82 : 0.20),
                                   lineWidth: isFocused ? 3 : isCurrent ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.44), radius: isFocused ? 8 : 3, y: 3)
            .accessibilityHidden(true)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($watchingControlFocus, equals: .photo(record.id))
        .scaleEffect(isFocused && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        .accessibilityLabel(itemStatus(record))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("slideshow-select-photo-\(record.id)")
    }

    private var soundtrackButton: some View {
        let focused = watchingControlFocus == .musicChoose
        let hasSoundtrack = music.selectedChoice != nil
        let title = hasSoundtrack
            ? AppLocalization.string("slideshow.music.change", defaultValue: "Change Music")
            : AppLocalization.string("slideshow.music.choose", defaultValue: "Choose Soundtrack")
        return Button {
            noteControlInteraction()
            musicPickerPlayback = .pausedWhileBrowsing(resume: !coordinator.isPaused)
            showsMusicPicker = true
            coordinator.setPaused(true)
            synchronizeMusicPlayback()
            refreshControlAutoHide()
        } label: {
            Group {
                if hasSoundtrack {
                    Image(systemName: "music.note")
                        .frame(width: 46)
                } else {
                    Label(title, systemImage: "music.note")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 14)
                }
            }
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .frame(height: 46)
            .background(focused ? Color.white : Color.white.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
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
        VStack(alignment: .leading, spacing: 9) {
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
            HStack(spacing: 8) {
                soundtrackTransport
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 22)
                    .accessibilityHidden(true)
                soundtrackButton
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .frame(width: 260)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 20))
        .floatingSurface(in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("slideshow.music.control_title", defaultValue: "Background Music"))
        .accessibilityIdentifier("slideshow-music-controls")
    }

    private var soundtrackArtwork: some View {
        let placeholder = Image(systemName: "music.note")
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.09))
        return Group {
            if let url = music.nowPlaying?.artworkURL ?? music.selectedChoice?.artworkURL {
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
                defaultValue: "Left or right changes memory. Up shows controls. Play/Pause pauses the slideshow."
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

    private var showsLocationGlobe: Bool {
        guard !showsWatchingControls, coordinator.currentItem != nil else { return false }
        switch coordinator.phase {
        case .presentingItem:
            return true
        case .transitioningItem:
            return coordinator.currentItem?.transition.kind != .dateReveal
        default:
            return false
        }
    }

    private var watchingContext: some View {
        GeometryReader { proxy in
            let locationSize = CGSize(width: 280, height: 176)
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
                if showsLocationGlobe, let record = coordinator.currentItem?.record,
                   let destination = PhotoGlobeDestination(record: record) {
                    SlideshowLocationGlobe(destination: destination)
                        .position(
                            x: 80 + locationSize.width / 2,
                            y: canvasHeight - 52 - locationSize.height / 2
                        )
                }
                if coordinator.currentJourney != nil || coordinator.isBuffering {
                    journeyIndicator
                        .padding(.leading, 72)
                        .padding(.top, 58)
                }
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

    private var journeyIndicator: some View {
        HStack(spacing: 12) {
            if let journey = coordinator.currentJourney {
                Text(AppLocalization.format(
                    "slideshow.current_journey",
                    defaultValue: "Trip %1$lld of %2$lld · %3$@",
                    Int64(coordinator.currentJourneyNumber), Int64(coordinator.journeyCount),
                    AppLocalization.dateRange(from: journey.startDate, to: journey.endDate)
                ))
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .accessibilityIdentifier("slideshow-current-journey")
            }
            if coordinator.isBuffering {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .accessibilityLabel(AppLocalization.string(
                        "slideshow.loading_more", defaultValue: "Preparing the next memories…"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.black.opacity(reduceTransparency ? 0.95 : 0.66), in: Capsule())
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
                defaultValue: "Preparing %1$lld of %2$lld · %3$lld ready",
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

    private func itemStatus(_ record: PhotoAssetRecord) -> String {
        let kind: String
        switch record.mediaKind {
        case .photo: kind = AppLocalization.string("detail.media_photo", defaultValue: "Photo")
        case .livePhoto: kind = AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo")
        case .video: kind = AppLocalization.string("detail.media_video", defaultValue: "Video")
        }
        return AppLocalization.format(
            "slideshow.item_status",
            defaultValue: "%1$@ · %2$@",
            AppLocalization.shortDate(record.creationDate),
            kind
        )
    }

    private var currentMediaAccessibilityLabel: String {
        coordinator.currentItem.map { itemStatus($0.record) }
            ?? coordinator.currentChapter.map { PlaceDisplayLabel(place: $0.visit).displayCity }
            ?? coordinator.scope.title
    }

    private var currentMediaAccessibilityValue: String {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slideshow-observe-media") {
            return coordinator.lastViewedAssetID == coordinator.currentItem?.id ? coordinator.lastViewedAssetID ?? "" : ""
        }
#endif
        return ""
    }

    private var mediaAnimation: Animation? {
        guard !reduceMotion, let transition = coordinator.currentItem?.transition else { return nil }
        let duration = coordinator.activeTransitionDuration ?? transition.duration
        return .timingCurve(0.33, 0, 0.2, 1, duration: duration)
    }

    private func itemTransition(_ transition: EarthSlideshowTransition) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let direction: CGFloat = coordinator.navigationDirection >= 0 ? 1 : -1
        switch transition.kind {
        case .dissolve:
            return cinematicDissolve(
                incomingScale: 0.998,
                outgoingScale: 0.998
            )
        case .directional:
            return cinematicDissolve(
                incomingScale: 0.994,
                incomingOffset: 16 * direction,
                outgoingScale: 0.998,
                outgoingOffset: -6 * direction
            )
        case .settle:
            return cinematicDissolve(
                incomingScale: 0.989,
                outgoingScale: 0.996
            )
        case .dateReveal:
            return cinematicDissolve(
                incomingScale: 0.996,
                outgoingScale: 0.994
            )
        }
    }

    /// Every photo change shares one visual grammar: the two memories overlap
    /// and dissolve. Content relationships may add a barely perceptible drift
    /// or pull-back, but never turn the photograph into a page being pushed off
    /// screen. Scales stay at or below one so the original frame is not cropped.
    private func cinematicDissolve(
        incomingScale: CGFloat,
        incomingOffset: CGFloat = 0,
        outgoingScale: CGFloat,
        outgoingOffset: CGFloat = 0
    ) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CinematicMemoryTransitionModifier(
                    opacity: 0,
                    scale: incomingScale,
                    horizontalOffset: incomingOffset
                ),
                identity: .identity
            ),
            // The incoming image supplies the fade. Keeping the backing image
            // opaque avoids dipping through black halfway through the dissolve.
            removal: .modifier(
                active: CinematicMemoryTransitionModifier(
                    opacity: 1,
                    scale: outgoingScale,
                    horizontalOffset: outgoingOffset
                ),
                identity: .identity
            )
        )
    }

    private func cinematicDateReveal(_ date: Date) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(AppLocalization.shortDate(date))
                    .font(.system(size: 32, weight: .light))
                    .monospacedDigit()
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.82))
                    .shadow(color: .black.opacity(0.7), radius: 12, y: 4)
                    .accessibilityIdentifier("slideshow-date-reveal")
                Spacer()
            }
            .padding(.horizontal, 104)
            .padding(.bottom, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.08), location: 0.68),
                    .init(color: .black.opacity(0.28), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    private func cinematicMotionDuration(for record: PhotoAssetRecord) -> TimeInterval {
        let dwell: TimeInterval
        switch record.mediaKind {
        case .photo:
            dwell = coordinator.configuration.stillDuration
        case .livePhoto:
            dwell = coordinator.configuration.livePhotoDuration
        case .video:
            dwell = record.duration > 0
                ? min(record.duration, coordinator.configuration.maximumVideoDuration)
                : coordinator.configuration.maximumVideoDuration
        }
        return max(2.5, dwell + (coordinator.currentItem?.transition.duration ?? 0))
    }

    private func retainPreparedFrame(_ image: UIImage, for assetID: String) {
        let allowed = preparedFrameIDs
        guard allowed.contains(assetID) else { return }
        var retained = preparedFrames.filter { allowed.contains($0.key) }
        retained[assetID] = image
        preparedFrames = retained
    }

    private func trimPreparedFrames() {
        let allowed = preparedFrameIDs
        preparedFrames = preparedFrames.filter { allowed.contains($0.key) }
    }

    private var preparedFrameIDs: Set<String> {
        guard let currentID = coordinator.currentItem?.record.id else { return [] }
        var ids: Set<String> = [currentID]
        if coordinator.phase != .transitioningItem,
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
        coordinator.markCurrentItemReady(record.id)
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
        if case .pausedWhileBrowsing(let resume) = musicPickerPlayback {
            musicPickerPlayback = resume ? .resumeOnForeground : nil
        }
        resumePlaybackAfterMusicPicker()
        refreshControlAutoHide()
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

    private func resumePlaybackAfterMusicPicker() {
        guard case .resumeOnForeground = musicPickerPlayback, scenePhase == .active else { return }
        musicPickerPlayback = nil
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
            presentationActive: musicPresentationActive,
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

private struct CinematicMemoryTransitionModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let horizontalOffset: CGFloat

    static let identity = CinematicMemoryTransitionModifier(
        opacity: 1,
        scale: 1,
        horizontalOffset: 0
    )

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: horizontalOffset)
    }
}

/// A memory is presented as a small cinematic composition rather than a bare
/// image on black: a restrained ambient wash carries the photograph's color to
/// the television edges, while the original remains fully visible above it.
private struct CinematicSlideshowMediaLayer: View {
    let item: EarthSlideshowItem
    let initialImage: UIImage?
    @ObservedObject var playback: PhotoDetailPlaybackModel
    let reduceMotion: Bool
    let isPaused: Bool
    let motionDuration: TimeInterval
    let isActive: Bool
    let onImageChange: (UIImage?) -> Void
    let onDynamicDisplay: () -> Void
    let onFullFrameUnavailable: () -> Void
    @State private var videoPlayer: AVPlayer?

    var body: some View {
        GeometryReader { proxy in
            mediaContent(size: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .onChange(of: playback.player, initial: true) { _, player in
            // Retain the outgoing, paused video frame until its dissolve ends.
            if playback.preparedAssetID == item.id { videoPlayer = player }
        }
    }

    private func mediaContent(size: CGSize) -> some View {
        ZStack {
            Color.black

            if let initialImage {
                Image(uiImage: initialImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .scaleEffect(1.1)
                    .saturation(0.78)
                    .brightness(-0.16)
                    .blur(radius: 52)
                    .opacity(0.56)
                    .transition(.opacity)
            }

            Color.black.opacity(0.34)

            CinematicMotionSurface(
                assetID: item.record.id,
                duration: motionDuration,
                reduceMotion: reduceMotion || item.record.mediaKind == .video,
                isPaused: isPaused
            ) {
                PhotoAssetImage(
                    assetID: item.record.id,
                    contentMode: .fit,
                    targetSize: CGSize(width: 3_840, height: 2_160),
                    allowsRetry: true,
                    isActive: isActive,
                    priority: .detail,
                    initialImage: initialImage,
                    onImageChange: onImageChange,
                    onRetryVisibilityChange: { visible in
                        if visible { onFullFrameUnavailable() }
                    }
                )
            }

            if let videoPlayer {
                PhotoVideoPlaybackView(player: videoPlayer, onDisplay: onDynamicDisplay)
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            } else if playback.preparedAssetID == item.id, let livePhoto = playback.livePhoto {
                LivePhotoPlaybackView(
                    livePhoto: livePhoto,
                    command: playback.liveCommand,
                    playbackModel: playback,
                    isMuted: playback.isMuted,
                    onDisplay: onDynamicDisplay
                )
                .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.2), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.7),
                    .init(color: .black.opacity(0.28), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: initialImage != nil)
    }
}

/// A slow push or pull gives still memories a sense of a held camera without
/// cropping them. Both endpoints stay at or below 1.0 scale; the small offset
/// fits inside the resulting inset even for a full-screen 16:9 photograph.
private struct CinematicMotionSurface<Content: View>: View {
    let assetID: String
    let duration: TimeInterval
    let reduceMotion: Bool
    let isPaused: Bool
    private let content: Content

    @State private var startedAt = Date()
    @State private var pausedAt: Date?
    @State private var accumulatedPause: TimeInterval = 0

    init(
        assetID: String,
        duration: TimeInterval,
        reduceMotion: Bool,
        isPaused: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.assetID = assetID
        self.duration = duration
        self.reduceMotion = reduceMotion
        self.isPaused = isPaused
        self.content = content()
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || isPaused)) { context in
            let progress = motionProgress(at: context.date)
            let transform = transform(at: progress)
            content
                .scaleEffect(transform.scale)
                .offset(x: transform.x, y: transform.y)
        }
        .onAppear {
            startedAt = Date()
            pausedAt = isPaused ? Date() : nil
        }
        .onChange(of: isPaused) { _, paused in
            if paused {
                pausedAt = Date()
            } else if let pausedAt {
                accumulatedPause += max(0, Date().timeIntervalSince(pausedAt))
                self.pausedAt = nil
            }
        }
    }

    private func motionProgress(at date: Date) -> Double {
        guard !reduceMotion else { return 1 }
        let effectiveDate = pausedAt ?? date
        let elapsed = max(0, effectiveDate.timeIntervalSince(startedAt) - accumulatedPause)
        let linear = min(1, elapsed / max(0.1, duration))
        return linear * linear * (3 - 2 * linear)
    }

    private func transform(at progress: Double) -> (scale: CGFloat, x: CGFloat, y: CGFloat) {
        guard !reduceMotion else { return (1, 0, 0) }
        let seed = stableSeed
        let pushesIn = seed & 1 == 0
        let horizontalSign: CGFloat = seed & 2 == 0 ? -1 : 1
        let verticalSign: CGFloat = seed & 4 == 0 ? -1 : 1
        let travel = pushesIn ? 1 - progress : progress
        let scale = pushesIn ? 0.955 + 0.045 * progress : 1 - 0.045 * progress
        return (
            CGFloat(scale),
            horizontalSign * 16 * CGFloat(travel),
            verticalSign * 9 * CGFloat(travel)
        )
    }

    private var stableSeed: UInt64 {
        assetID.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

/// A passive version of the photo-detail globe: it keeps the real capture
/// coordinate visible without introducing another focus target or a caption
/// over the memory. MapKit's own legal attribution remains unobstructed.
private struct SlideshowLocationGlobe: View {
    let destination: PhotoGlobeDestination

    var body: some View {
        PhotoLocationMap(destination: destination, style: .slideshow)
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
