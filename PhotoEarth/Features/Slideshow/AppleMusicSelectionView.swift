import SwiftUI

struct AppleMusicSelectionView: View {
    @ObservedObject var controller: SlideshowMusicController
    let didSelect: () -> Void

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var selectionFocusScope
    @State private var searchTerm = ""
    @State private var pendingChoice: SlideshowMusicChoice?
    @FocusState private var focusedChoiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            searchField
            if let message = controller.errorMessage,
               !controller.browseContent.isEmpty || !controller.searchResults.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
            }
            libraryContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focusedChoiceID, initialBrowseFocusID, priority: .userInitiated)
        .focusScope(selectionFocusScope)
        .task {
            await controller.loadBrowseIfNeeded()
        }
        .task(id: searchTerm) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await controller.search(searchTerm)
        }
        .task(id: pendingChoice?.id) {
            guard let pendingChoice else { return }
            let selected = await controller.select(pendingChoice)
            guard !Task.isCancelled else { return }
            self.pendingChoice = nil
            if selected { didSelect() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-music-picker")
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.62))
            TextField(
                AppLocalization.string(
                    "slideshow.music.search",
                    defaultValue: "Search Apple Music"
                ),
                text: $searchTerm
            )
            .textFieldStyle(.plain)
            .accessibilityIdentifier("slideshow-music-search")
            if controller.isSearching {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.75)
            }
        }
        .font(.system(size: 24))
        .padding(.horizontal, 22)
        .frame(width: 620, height: 66)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if let message = controller.errorMessage,
           controller.browseContent.isEmpty,
           controller.searchResults.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.system(size: 23))
                    .foregroundStyle(.white.opacity(0.72))
                Button(AppLocalization.string("common.retry", defaultValue: "Try Again")) {
                    Task { await controller.reloadBrowse() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if controller.isLoadingBrowse && controller.browseContent.isEmpty {
            HStack(spacing: 16) {
                ProgressView().tint(.white)
                Text(AppLocalization.string(
                    "slideshow.music.loading",
                    defaultValue: "Loading your Apple Music…"
                ))
            }
            .font(.system(size: 23))
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        musicSection(
                            title: AppLocalization.string(
                                "slideshow.music.recent",
                                defaultValue: "Recently Played"
                            ),
                            choices: controller.browseContent.recentlyPlayed,
                            sectionID: "recent"
                        )
                        musicSection(
                            title: AppLocalization.string(
                                "slideshow.music.playlists",
                                defaultValue: "Your Playlists"
                            ),
                            choices: controller.browseContent.playlists,
                            sectionID: "playlists"
                        )
                        musicSection(
                            title: AppLocalization.string(
                                "slideshow.music.songs",
                                defaultValue: "Recently Played Songs"
                            ),
                            choices: controller.browseContent.songs,
                            sectionID: "songs"
                        )
                        if controller.browseContent.isEmpty, !controller.isLoadingBrowse {
                            emptyState(
                                AppLocalization.string(
                                    "slideshow.music.library_empty",
                                    defaultValue: "No recent music was found. Search Apple Music above."
                                )
                            )
                        }
                    } else {
                        musicSection(
                            title: AppLocalization.string(
                                "slideshow.music.results",
                                defaultValue: "Search Results"
                            ),
                            choices: controller.searchResults,
                            sectionID: "results"
                        )
                        if controller.searchResults.isEmpty, !controller.isSearching {
                            emptyState(
                                AppLocalization.string(
                                    "slideshow.music.no_results",
                                    defaultValue: "No matching music found."
                                )
                            )
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .task(id: initialBrowseFocusID) {
                guard let target = initialBrowseFocusID,
                      searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                resetFocus(in: selectionFocusScope)
                focusedChoiceID = target
            }
        }
    }

    @ViewBuilder
    private func musicSection(
        title: String,
        choices: [SlideshowMusicChoice],
        sectionID: String
    ) -> some View {
        if !choices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                ScrollView(.horizontal) {
                    LazyHStack(spacing: TVControlLayout.actionSpacing) {
                        ForEach(choices) { choice in
                            let focusID = "\(sectionID):\(choice.id)"
                            Button {
                                pendingChoice = choice
                            } label: {
                                SlideshowMusicChoiceCard(
                                    choice: choice,
                                    isSelected: controller.selectedChoice?.id == choice.id
                                )
                            }
                            .buttonStyle(SlideshowMusicCardButtonStyle())
                            .focused($focusedChoiceID, equals: focusID)
                            .disabled(pendingChoice != nil)
                            .accessibilityLabel(choiceAccessibilityLabel(choice))
                            .accessibilityAddTraits(controller.selectedChoice?.id == choice.id ? .isSelected : [])
                            .accessibilityIdentifier("slideshow-music-choice-\(focusID)")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .contentMargins(.horizontal, -18, for: .scrollContent)
                .scrollClipDisabled()
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 23))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.top, 24)
    }

    private func choiceAccessibilityLabel(_ choice: SlideshowMusicChoice) -> String {
        guard let subtitle = choice.subtitle, !subtitle.isEmpty else { return choice.title }
        return "\(choice.title), \(subtitle)"
    }

    private var initialBrowseFocusID: String? {
        if let first = controller.browseContent.recentlyPlayed.first {
            return "recent:\(first.id)"
        }
        if let first = controller.browseContent.playlists.first {
            return "playlists:\(first.id)"
        }
        if let first = controller.browseContent.songs.first {
            return "songs:\(first.id)"
        }
        return nil
    }
}

private struct SlideshowMusicChoiceCard: View {
    let choice: SlideshowMusicChoice
    let isSelected: Bool
    private let artworkSide: CGFloat = 206

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .pink)
                            .padding(12)
                    }
                }
            Text(choice.title)
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1)
            Text(choice.subtitle ?? kindName)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
        }
        .frame(width: artworkSide, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(isSelected ? .pink.opacity(0.8) : .white.opacity(0.1), lineWidth: 2)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = choice.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    fallbackArtwork
                case .empty:
                    ZStack {
                        fallbackArtwork
                        ProgressView().tint(.white)
                    }
                @unknown default:
                    fallbackArtwork
                }
            }
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        LinearGradient(
            colors: [.pink.opacity(0.8), .purple.opacity(0.68), .cyan.opacity(0.52)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: iconName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var iconName: String {
        switch choice.kind {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .station: "dot.radiowaves.left.and.right"
        }
    }

    private var kindName: String {
        switch choice.kind {
        case .song:
            AppLocalization.string("slideshow.music.kind.song", defaultValue: "Song")
        case .album:
            AppLocalization.string("slideshow.music.kind.album", defaultValue: "Album")
        case .playlist:
            AppLocalization.string("slideshow.music.kind.playlist", defaultValue: "Playlist")
        case .station:
            AppLocalization.string("slideshow.music.kind.station", defaultValue: "Station")
        }
    }
}

private struct SlideshowMusicCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                }
                .scaleEffect(isFocused && !reduceMotion ? 1.035 : 1)
                .brightness(isFocused ? 0.1 : 0)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0.24), radius: isFocused ? 22 : 10, y: 9)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}
