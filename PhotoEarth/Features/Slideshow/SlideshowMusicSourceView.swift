import SwiftUI

struct SlideshowMusicSourceView: View {
    private static let trackColumns = Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: 5)

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
        case browseOnline
    }

    private struct TrackSelection {
        let playlist: OnlineSlideshowPlaylist
        let track: OnlineSlideshowPlaylist.Track
        let explicitTrackChoice: Bool
    }

    @ObservedObject var controller: SlideshowMusicController
    let dismiss: () -> Void
    let cancel: () -> Void

    @State private var source: Source
    @State private var catalog = CatalogState.loading
    @State private var retry = 0
    @State private var browsedPlaylistID: String?
    @State private var lastGridTrackID: OnlineSlideshowPlaylist.Track.ID?
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
                if controller.automaticMusicEnabled, source == .online || controller.accessState == .available {
                    clearMusicButton
                }
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
        .onChange(of: pickerFocus, updateBrowserFocus)
        .onDisappear { connectionTask?.cancel() }
        .onExitCommand {
            pendingSelection = nil
            cancel()
        }
        .accessibilityElement(children: .contain)
    }

    private func updateBrowserFocus(_ previous: PickerFocus?, _ focus: PickerFocus?) {
        switch focus {
        case .playlist(let id):
            // A grid row can overlap several sidebar categories. Left returns to its own category.
            if case .track = previous, let browsedPlaylistID, id != browsedPlaylistID {
                pickerFocus = .playlist(browsedPlaylistID)
            } else if browsedPlaylistID != id {
                browsedPlaylistID = id
                lastGridTrackID = nil
                selectionFailed = false
            }
        case .track(let id):
            if case .playlist(let category) = previous,
               case .loaded(let snapshot) = catalog,
               let playlist = snapshot.playlists.first(where: { $0.id == category }) {
                let selected = category == selectedPlaylistID ? controller.onlineTrackID : nil
                if let entry = lastGridTrackID ?? selected ?? playlist.tracks.first?.id, entry != id {
                    pickerFocus = .track(entry)
                    return
                }
            }
            lastGridTrackID = id
        default:
            break
        }
    }

    private var sourceSwitch: some View {
        HStack(spacing: 4) {
            sourceButton(
                .online,
                title: AppLocalization.string("slideshow.music.online", defaultValue: "Online Music"),
                symbol: "waveform",
                focus: .online,
                identifier: "slideshow-music-source-online",
                action: browseOnlineMusic
            )
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
            if offline {
                Text(AppLocalization.string("slideshow.music.online.offline_help", defaultValue: "Reconnect to play music."))
                    .font(.system(size: 23))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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
        if controller.isConnecting || controller.accessState == .checking {
            ProgressView(AppLocalization.string("slideshow.music.checking", defaultValue: "Checking Apple Music…"))
        } else if controller.accessState == .available {
            AppleMusicSelectionView(controller: controller, didSelect: dismiss)
        } else if controller.accessState == .notSubscribed {
            VStack(spacing: 18) {
                Image(systemName: "music.note")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("slideshow.music.subscription_required",
                                            defaultValue: "With an Apple Music subscription, you can choose songs from its catalog"))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("slideshow-music-apple-status")
                Text(AppLocalization.string("slideshow.music.subscription_alternative",
                                            defaultValue: "PHOTO EARTH’s online music is available without a subscription."))
                    .font(.system(size: 27))
                    .foregroundStyle(.secondary)
                Button(AppLocalization.string("slideshow.music.browse_online", defaultValue: "Browse Online Music"),
                       action: browseOnlineMusic)
                    .buttonStyle(.borderedProminent)
                    .focused($pickerFocus, equals: .browseOnline)
                    .accessibilityIdentifier("slideshow-music-browse-online")
                    .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { pickerFocus = .browseOnline }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if let appleMusicStatus {
                    Text(appleMusicStatus)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("slideshow-music-apple-status")
                }
                if controller.accessState == .needsAuthorization || controller.accessState == .temporarilyUnavailable {
                    Button(
                        controller.accessState == .needsAuthorization
                            ? AppLocalization.string("slideshow.music.connect", defaultValue: "Connect Apple Music")
                            : AppLocalization.string("common.retry", defaultValue: "Try Again"),
                        action: connectAppleMusic
                    )
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func browseOnlineMusic() {
        source = .online
        pickerFocus = onlineFocus
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
                trackGrid(active)
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
                chooseTrack(track, in: playlist, explicitTrackChoice: false)
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
            .modifier(SlideshowBrowserRowAppearance(focused: pickerFocus == target, highlighted: isBrowsing))
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($pickerFocus, equals: target)
        .disabled(isPreparingSelection)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        .accessibilityIdentifier("slideshow-online-playlist-\(playlist.id)")
    }

    private func trackGrid(_ playlist: OnlineSlideshowPlaylist) -> some View {
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
                    LazyVGrid(columns: Self.trackColumns, spacing: 18) {
                        ForEach(playlist.tracks) { track in
                            trackButton(track, in: playlist)
                                .id(track.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
        let isSelected = playlist.id == selectedPlaylistID && track.id == controller.onlineTrackID
        return Button {
            chooseTrack(track, in: playlist, explicitTrackChoice: true)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                OnlineTrackArtwork(title: track.title, theme: track.themeID)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if pickerFocus == target {
                            RoundedRectangle(cornerRadius: 14).strokeBorder(.white, lineWidth: 5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 27, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.8))
                                .padding(9)
                                .accessibilityHidden(true)
                        }
                    }
                Text(verbatim: track.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(pickerFocus == target ? 1 : 0.86))
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($pickerFocus, equals: target)
        .disabled(isPreparingSelection)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(verbatim: track.title))
        .accessibilityIdentifier("slideshow-online-track-\(track.id.deletingLastPathComponent().lastPathComponent)")
    }

    private func chooseTrack(_ track: OnlineSlideshowPlaylist.Track, in playlist: OnlineSlideshowPlaylist,
                             explicitTrackChoice: Bool) {
        selectionFailed = false
        pendingSelection = TrackSelection(playlist: playlist, track: track, explicitTrackChoice: explicitTrackChoice)
    }

    private var clearMusicButton: some View {
        Button {
            controller.turnOffMusic()
            dismiss()
        } label: {
            Label(AppLocalization.string("slideshow.music.turn_off", defaultValue: "Turn Off Soundtrack"),
                  systemImage: "speaker.slash")
        }
        .buttonStyle(.bordered)
        .focused($pickerFocus, equals: .clearMusic)
        .disabled(isPreparingSelection)
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
            let snapshot = try await controller.onlineCatalog()
            try Task.checkCancellation()
            let playlists = snapshot.playlists
            browsedPlaylistID = (playlists.first { $0.id == selectedPlaylistID } ?? playlists.first)?.id
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
        let selected = await controller.selectOnline(pendingSelection.playlist, startingAt: pendingSelection.track.id,
                                                     explicitTrackChoice: pendingSelection.explicitTrackChoice)
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
        case .denied:
            AppLocalization.string("slideshow.music.access_denied", defaultValue: "Allow Apple Music access in Settings")
        case .restricted:
            AppLocalization.string("slideshow.music.restricted", defaultValue: "Apple Music is restricted on this Apple TV")
        case .temporarilyUnavailable:
            AppLocalization.string("slideshow.music.retry", defaultValue: "Apple Music is temporarily unavailable.")
        default:
            nil
        }
    }
}

struct SlideshowBrowserRowAppearance: ViewModifier {
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
