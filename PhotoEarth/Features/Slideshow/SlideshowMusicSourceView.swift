import SwiftUI

struct SlideshowMusicSourceView: View {
    private enum Source { case online, appleMusic }

    private enum CatalogState {
        case loading
        case loaded(OnlineSlideshowCatalog.Snapshot)
        case failed(offline: Bool)
    }

    private enum PickerFocus: Hashable {
        case loading
        case preparingSelection
        case playlist(String)
        case track(OnlineSlideshowPlaylist.Track.ID)
        case retry
        case online
        case appleMusic
        case clearMusic
    }

    private struct TrackSelection {
        let playlist: OnlineSlideshowPlaylist
        let track: OnlineSlideshowPlaylist.Track
    }

    @ObservedObject var controller: SlideshowMusicController
    let dismiss: () -> Void
    let cancel: () -> Void

    @State private var source: Source
    @State private var catalog = CatalogState.loading
    @State private var retry = 0
    @State private var browsedPlaylistID: String?
    @State private var pendingSelection: TrackSelection?
    @State private var selectionFailed = false
    @State private var connectionTask: Task<Void, Never>?
    @FocusState private var pickerFocus: PickerFocus?

    init(controller: SlideshowMusicController, dismiss: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.controller = controller
        self.dismiss = dismiss
        self.cancel = cancel
        _source = State(initialValue: controller.selectedChoice != nil && !controller.isUsingOnlineMusic
            ? .appleMusic : .online)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: TVControlLayout.actionSpacing) {
                sourceSwitch
                Spacer()
                clearMusicButton
            }
            .focusSection()

            ZStack {
                Group {
                    switch source {
                    case .online:
                        onlineContent
                    case .appleMusic:
                        appleMusicContent
                    }
                }
                .disabled(isPreparingSelection)

                if isPreparingSelection {
                    Color.black.opacity(0.25)
                    ProgressView(AppLocalization.string("slideshow.music.preparing", defaultValue: "Preparing music…"))
                        .font(.system(size: 24, weight: .medium))
                        .tint(.white)
                        .padding(24)
                        .floatingSurface(in: RoundedRectangle(cornerRadius: 20))
                        .focusable()
                        .focusEffectDisabled()
                        .focused($pickerFocus, equals: .preparingSelection)
                        .accessibilityIdentifier("slideshow-music-selection-progress")
                }
            }
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 38)
        .frame(width: 1580, height: 840, alignment: .topLeading)
        .defaultFocus($pickerFocus, source == .online ? onlineFocus : nil)
        .task(id: pendingSelection?.track.id) { await selectPendingTrack() }
        .onChange(of: isPreparingSelection) { _, preparing in
            if preparing { pickerFocus = .preparingSelection }
        }
        .onChange(of: pickerFocus) { _, focus in
            if case .playlist(let id) = focus, browsedPlaylistID != id {
                browsedPlaylistID = id
                selectionFailed = false
            }
        }
        .onDisappear { connectionTask?.cancel() }
        .onExitCommand {
            pendingSelection = nil
            cancel()
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceSwitch: some View {
        HStack(spacing: 4) {
            sourceButton(
                .online,
                title: AppLocalization.string("slideshow.music.online", defaultValue: "Online Music"),
                symbol: "waveform",
                focus: .online,
                identifier: "slideshow-music-source-online"
            ) {
                source = .online
                if case .loaded = catalog { pickerFocus = onlineFocus }
            }
            sourceButton(
                .appleMusic, title: "Apple Music", symbol: "music.note",
                focus: .appleMusic, identifier: "slideshow-music-source-apple"
            ) {
                source = .appleMusic
                if controller.accessState != .available { connectAppleMusic() }
            }
        }
        .padding(5)
        .background(.white.opacity(0.08), in: Capsule())
        .disabled(isPreparingSelection)
    }

    private func sourceButton(
        _ target: Source, title: String, symbol: String,
        focus: PickerFocus, identifier: String, action: @escaping () -> Void
    ) -> some View {
        let isSelected = source == target
        let isFocused = pickerFocus == focus
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white.opacity(isSelected ? 1 : 0.75))
                .padding(.horizontal, 24)
                .frame(height: 54)
                .background(.white.opacity(isFocused ? 0.94 : isSelected ? 0.19 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($pickerFocus, equals: focus)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var onlineContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch catalog {
            case .loading:
                ProgressView(AppLocalization.string("slideshow.music.online", defaultValue: "Online Music"))
                    .focusable()
                    .focusEffectDisabled()
                    .focused($pickerFocus, equals: .loading)
            case .failed(let offline):
                catalogFailure(offline: offline)
            case .loaded(let snapshot):
                if snapshot.isCached { cachedCatalogNotice }
                catalogBrowser(snapshot.playlists)
                if selectionFailed { errorLabel }
            }
        }
        .task(id: retry) {
            if case .loaded = catalog {
                await focusOnlineContent()
            } else {
                await loadCatalog()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-music-online-picker")
    }

    private func catalogFailure(offline: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(offline
                ? AppLocalization.string("slideshow.music.online.offline", defaultValue: "No network connection")
                : SlideshowMusicController.onlineUnavailableMessage
            )
            .font(.system(size: 32, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("slideshow-music-catalog-status")
            Text(offline
                ? AppLocalization.string(
                    "slideshow.music.online.offline_help",
                    defaultValue: "Reconnect and try again, or press Back."
                )
                : AppLocalization.string(
                    "slideshow.music.online.retry_help",
                    defaultValue: "Try again, or press Back."
                )
            )
            .font(.system(size: 23))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            retryCatalogButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cachedCatalogNotice: some View {
        HStack(spacing: 24) {
            Label(
                AppLocalization.string(
                    "slideshow.music.online.cached",
                    defaultValue: "Showing the last loaded catalog. Playing music requires an internet connection."
                ),
                systemImage: "arrow.clockwise"
            )
            .font(.system(size: 22))
            .foregroundStyle(.secondary)
            Spacer()
            retryCatalogButton
        }
    }

    private var retryCatalogButton: some View {
        Button(AppLocalization.string("common.retry", defaultValue: "Try Again")) {
            catalog = .loading
            retry += 1
        }
        .buttonStyle(.bordered)
        .focused($pickerFocus, equals: .retry)
        .accessibilityIdentifier("slideshow-music-catalog-retry")
    }

    @ViewBuilder
    private var appleMusicContent: some View {
        if controller.accessState == .available {
            AppleMusicSelectionView(controller: controller, didSelect: dismiss)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if controller.isConnecting || controller.accessState == .checking {
                    ProgressView(AppLocalization.string("slideshow.music.checking", defaultValue: "Checking Apple Music…"))
                } else {
                    if let appleMusicStatus {
                        Text(appleMusicStatus)
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("slideshow-music-apple-status")
                    }
                    if controller.accessState != .restricted {
                        Button(
                            controller.accessState == .needsAuthorization
                                ? AppLocalization.string("slideshow.music.connect", defaultValue: "Connect Apple Music")
                                : AppLocalization.string("common.retry", defaultValue: "Try Again"),
                            action: connectAppleMusic
                        )
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func connectAppleMusic() {
        guard !controller.isConnecting else { return }
        connectionTask = Task { await controller.connect() }
    }

    private func catalogBrowser(_ playlists: [OnlineSlideshowPlaylist]) -> some View {
        let active = playlists.first { $0.id == browsedPlaylistID } ?? playlists.first
        return HStack(alignment: .top, spacing: 20) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(playlists) { playlist in
                        categoryButton(playlist, isBrowsing: playlist.id == active?.id)
                    }
                }
            }
            .frame(width: 362)
            .focusSection()

            Divider().overlay(.white.opacity(0.1))

            if let active {
                trackList(active)
                    .id(active.id)
                    .focusSection()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func categoryButton(_ playlist: OnlineSlideshowPlaylist, isBrowsing: Bool) -> some View {
        let target = PickerFocus.playlist(playlist.id)
        let isPlaying = playlist.id == selectedPlaylistID
        return Button {
            if isPlaying && controller.playbackError == nil {
                dismiss()
            } else if let track = playlist.tracks.first {
                chooseTrack(track, in: playlist)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: playlist.symbol)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                Text(playlist.displayTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if isPlaying || pickerFocus == target {
                    Image(systemName: isPlaying ? "checkmark" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 26, weight: .semibold))
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .modifier(SlideshowMusicRowAppearance(focused: pickerFocus == target, highlighted: isBrowsing))
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($pickerFocus, equals: target)
        .disabled(isPreparingSelection)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        .accessibilityIdentifier("slideshow-online-playlist-\(playlist.id)")
    }

    private func trackList(_ playlist: OnlineSlideshowPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.format(
                "slideshow.music.online.track_count",
                defaultValue: "%lld tracks",
                Int64(playlist.tracks.count)
            ))
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(playlist.tracks) { track in
                            trackButton(track, in: playlist)
                                .id(track.id)
                        }
                    }
                }
                .task {
                    guard playlist.id == selectedPlaylistID, let trackID = controller.onlineTrackID else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(trackID, anchor: .center)
                }
            }
        }
    }

    private func trackButton(_ track: OnlineSlideshowPlaylist.Track, in playlist: OnlineSlideshowPlaylist) -> some View {
        let target = PickerFocus.track(track.id)
        let isSelected = track.id == controller.onlineTrackID
        return Button {
            chooseTrack(track, in: playlist)
        } label: {
            HStack(spacing: 18) {
                Text(track.title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "play.circle")
                    .font(.system(size: 25))
                    .opacity(isSelected || pickerFocus == target ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 18)
            .modifier(SlideshowMusicRowAppearance(focused: pickerFocus == target, highlighted: isSelected))
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($pickerFocus, equals: target)
        .disabled(isPreparingSelection)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("slideshow-online-track-\(track.id.deletingLastPathComponent().lastPathComponent)")
    }

    private func chooseTrack(_ track: OnlineSlideshowPlaylist.Track, in playlist: OnlineSlideshowPlaylist) {
        if track.id == controller.onlineTrackID && controller.playbackError == nil {
            dismiss()
        } else {
            selectionFailed = false
            pendingSelection = TrackSelection(playlist: playlist, track: track)
        }
    }

    private var clearMusicButton: some View {
        Button {
            controller.clearMusic()
            dismiss()
        } label: {
            Label(
                AppLocalization.string("slideshow.music.turn_off", defaultValue: "Turn Off Soundtrack"),
                systemImage: "speaker.slash"
            )
        }
        .buttonStyle(.bordered)
        .focused($pickerFocus, equals: .clearMusic)
        .disabled(controller.selectedChoice == nil || isPreparingSelection)
        .accessibilityIdentifier("slideshow-music-off")
    }

    private var isPreparingSelection: Bool {
        pendingSelection != nil || controller.isPreparingSelection
    }

    private var selectedPlaylistID: String? {
        controller.isUsingOnlineMusic ? controller.selectedChoice?.id : nil
    }

    private var onlineFocus: PickerFocus? {
        switch catalog {
        case .loading: .loading
        case .failed: .retry
        case .loaded(let snapshot):
            (snapshot.playlists.first { $0.id == selectedPlaylistID } ?? snapshot.playlists.first)
                .map { .playlist($0.id) }
        }
    }

    private func loadCatalog() async {
        catalog = .loading
        do {
            let snapshot = try await OnlineSlideshowCatalog.load()
            try Task.checkCancellation()
            browsedPlaylistID = (snapshot.playlists.first { $0.id == selectedPlaylistID } ?? snapshot.playlists.first)?.id
            catalog = .loaded(snapshot)
        } catch {
            guard !Task.isCancelled else { return }
            let code = (error as? URLError)?.code
            catalog = .failed(offline: code == .notConnectedToInternet || code == .networkConnectionLost)
        }
        await focusOnlineContent()
    }

    private func focusOnlineContent() async {
        await Task.yield()
        guard !Task.isCancelled, source == .online else { return }
        switch pickerFocus {
        case nil, .online, .loading, .retry:
            pickerFocus = onlineFocus
        default:
            break
        }
    }

    private func selectPendingTrack() async {
        guard let pendingSelection else { return }
        let selected = await controller.selectOnline(pendingSelection.playlist, startingAt: pendingSelection.track.id)
        guard !Task.isCancelled else { return }
        self.pendingSelection = nil
        if selected {
            dismiss()
        } else {
            selectionFailed = true
            pickerFocus = .track(pendingSelection.track.id)
        }
    }

    private var errorLabel: some View {
        Label(SlideshowMusicController.onlineUnavailableMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange.opacity(0.9))
            .font(.system(size: 23))
            .accessibilityIdentifier("slideshow-music-online-error")
    }

    private var appleMusicStatus: String? {
        switch controller.accessState {
        case .notSubscribed:
            AppLocalization.string("slideshow.music.subscription_required", defaultValue: "Subscription required")
        case .denied:
            AppLocalization.string("slideshow.music.access_denied", defaultValue: "Allow Apple Music access in Settings")
        case .restricted:
            AppLocalization.string("slideshow.music.restricted", defaultValue: "Apple Music is restricted on this Apple TV")
        case .temporarilyUnavailable:
            AppLocalization.string("slideshow.music.retry", defaultValue: "Retry Apple Music")
        default:
            nil
        }
    }
}

private struct SlideshowMusicRowAppearance: ViewModifier {
    let focused: Bool
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(
                .white.opacity(focused ? 0.94 : highlighted ? 0.15 : 0),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .contentShape(.rect)
    }
}
