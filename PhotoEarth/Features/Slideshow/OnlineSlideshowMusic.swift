import AVFoundation
import Combine
import Foundation
import UIKit

struct OnlineSlideshowPlaylist: Identifiable, Sendable {
    // A period keeps this local ID outside the remote catalog slug space.
    static let recommendedID = "local.recommended"

    struct Presentation: Decodable, Sendable {
        let titles: [String: String]
        let symbol: String?
    }

    struct Track: Identifiable, Equatable, Sendable {
        let title: String
        let artist: String
        let url: URL
        let themeID: String
        var id: URL { url }
    }

    let id: String
    let tracks: [Track]
    let presentation: Presentation?

    var displayTitle: String {
        for language in [AppLocalization.localeIdentifier, "en"] {
            if let title = presentation?.titles[language]?.trimmingCharacters(in: .whitespacesAndNewlines),
               (1...60).contains(title.count), !title.contains(where: \.isNewline) {
                return title
            }
        }
        return switch id {
        case Self.recommendedID:
            AppLocalization.string("slideshow.music.recommended", defaultValue: "Recommended")
        case "quiet-moments":
            AppLocalization.string("slideshow.music.online.quiet_moments", defaultValue: "Quiet Moments")
        case "open-road":
            AppLocalization.string("slideshow.music.online.open_road", defaultValue: "Open Road")
        case "piano":
            AppLocalization.string("slideshow.music.online.piano", defaultValue: "Piano")
        case "lofi":
            AppLocalization.string("slideshow.music.online.lofi", defaultValue: "Lo-Fi Beats")
        case "ambient":
            AppLocalization.string("slideshow.music.online.ambient", defaultValue: "Ambient")
        case "synthwave":
            AppLocalization.string("slideshow.music.online.synthwave", defaultValue: "Retro Electronic")
        case "cinematic":
            AppLocalization.string("slideshow.music.online.cinematic", defaultValue: "Narrative Music")
        case "chiptune":
            AppLocalization.string("slideshow.music.online.chiptune", defaultValue: "Chiptune")
        case "jazz":
            AppLocalization.string("slideshow.music.online.jazz", defaultValue: "Jazz")
        default:
            AppLocalization.string("slideshow.music.online", defaultValue: "Online Music")
        }
    }

    var symbol: String {
        if let symbol = presentation?.symbol, (1...64).contains(symbol.utf8.count),
           symbol.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 46 }),
           UIImage(systemName: symbol) != nil {
            return symbol
        }
        return switch id {
        case Self.recommendedID: "sparkles.rectangle.stack"
        case "quiet-moments": "moon.stars"
        case "open-road": "road.lanes"
        case "piano": "pianokeys"
        case "lofi": "headphones"
        case "ambient": "sparkles"
        case "cinematic": "film"
        case "chiptune": "gamecontroller"
        case "jazz": "music.note.list"
        default: "waveform"
        }
    }
}

enum OnlineSlideshowCatalog {
    struct Snapshot {
        let playlists: [OnlineSlideshowPlaylist]
        let isCached: Bool
    }

    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    private struct Manifest: Decodable {
        struct Playlist: Decodable {
            struct Track: Decodable {
                let title: String
                let artist: String
                let stream: String
            }

            let id: String
            let tracks: [Track]
            let presentation: OnlineSlideshowPlaylist.Presentation?

            private enum CodingKeys: String, CodingKey { case id, tracks, presentation }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                tracks = try values.decode([Track].self, forKey: .tracks)
                // Older catalogs and invalid presentation data can use the bundled labels.
                presentation = try? values.decode(OnlineSlideshowPlaylist.Presentation.self, forKey: .presentation)
            }
        }

        let version: Int
        let playlists: [Playlist]
    }

    nonisolated static let url = URL(string: "https://photoearth-online-music.pages.dev/catalog-v2.json")!
    nonisolated private static let previousURL = URL(string: "https://photoearth-online-music.pages.dev/catalog-v1.json")!
    private static let simulatesOffline: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--online-music-offline-fixture")
        #else
        false
        #endif
    }()

    private static var defaultCacheDirectory: URL {
        if simulatesOffline {
            // The cold-start fixture may be rerun on a simulator that already loaded the real catalog.
            return URL.temporaryDirectory.appendingPathComponent("OnlineSlideshowOfflineFixture", isDirectory: true)
        }
        return URL.cachesDirectory.appendingPathComponent("OnlineSlideshowCatalog", isDirectory: true)
    }

    static func load(
        from catalogURL: URL = url, cacheDirectory: URL? = nil, fetch: Fetch? = nil
    ) async throws -> Snapshot {
        guard catalogURL.scheme == "https" else { throw URLError(.unsupportedURL) }
        let cacheDirectory = cacheDirectory ?? defaultCacheDirectory
        let fetch = fetch ?? networkData
        var endpoint = catalogURL
        do {
            var (data, status) = try await download(from: endpoint, fetch: fetch)
            if endpoint == url && status == 404 {
                endpoint = previousURL
                (data, status) = try await download(from: endpoint, fetch: fetch)
            }
            guard status == 200 else { throw URLError(.badServerResponse) }
            let playlists = try decode(data, from: endpoint)
            try Task.checkCancellation()
            if let file = cacheFile(for: endpoint, in: cacheDirectory) {
                // A cache write failure does not prevent an otherwise valid catalog from opening.
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return Snapshot(playlists: playlists, isCached: false)
        } catch {
            try Task.checkCancellation()
            let candidates = catalogURL == url ? [url, previousURL] : [catalogURL]
            for candidate in candidates {
                if let file = cacheFile(for: candidate, in: cacheDirectory),
                   let handle = try? FileHandle(forReadingFrom: file) {
                    defer { try? handle.close() }
                    if let bytes = try? handle.read(upToCount: 65_537),
                       let playlists = try? decode(bytes, from: candidate) {
                        return Snapshot(playlists: playlists, isCached: true)
                    }
                }
            }
            throw error
        }
    }

    private static func cacheFile(for endpoint: URL, in directory: URL) -> URL? {
        guard endpoint == url || endpoint == previousURL else { return nil }
        return directory.appendingPathComponent(endpoint.lastPathComponent)
    }

    private static func download(from endpoint: URL, fetch: Fetch) async throws -> (Data, Int) {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, http.url == endpoint else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }

    private static func networkData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if simulatesOffline {
            throw URLError(.notConnectedToInternet)
        }
        return try await URLSession.shared.data(for: request)
    }

    static func decode(_ data: Data, from catalogURL: URL = url) throws -> [OnlineSlideshowPlaylist] {
        let isPreviousCatalog = catalogURL == previousURL
        guard data.count <= (isPreviousCatalog ? 32_768 : 65_536) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let ids = manifest.playlists.map(\.id)
        guard manifest.version == (isPreviousCatalog ? 1 : 2),
              !ids.isEmpty, ids.count <= (isPreviousCatalog ? 8 : 12), Set(ids).count == ids.count,
              ids.allSatisfy(isSlug) else {
            throw URLError(.cannotParseResponse)
        }
        let root = catalogURL.deletingLastPathComponent()
        return try manifest.playlists.map { playlist in
            let streams = playlist.tracks.map(\.stream)
            guard (2...(isPreviousCatalog ? 32 : 64)).contains(streams.count),
                  Set(streams).count == streams.count else {
                throw URLError(.cannotParseResponse)
            }
            let tracks = try playlist.tracks.map { track in
                guard !track.title.isEmpty, track.title.count <= 120,
                      !track.artist.isEmpty, track.artist.count <= 120,
                      isSlug(track.stream) else {
                    throw URLError(.cannotParseResponse)
                }
                return OnlineSlideshowPlaylist.Track(
                    title: track.title, artist: track.artist,
                    url: root.appendingPathComponent("tracks", isDirectory: true)
                        .appendingPathComponent(track.stream, isDirectory: true)
                        .appendingPathComponent("index.m3u8"),
                    themeID: playlist.id
                )
            }
            return OnlineSlideshowPlaylist(id: playlist.id, tracks: tracks, presentation: playlist.presentation)
        }
    }

    private static func isSlug(_ value: String) -> Bool {
        (1...120).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }
}

@MainActor
final class OnlineSlideshowMusicDriver: SlideshowMusicPlaying {
    private let makePlayer: @MainActor () -> AVPlayer
    private var player: AVPlayer?
    private var tracks: [OnlineSlideshowPlaylist.Track] = []
    private var index = 0
    private var preparation = UUID()
    private var itemGeneration = UUID()
    private var playbackContinuation: AsyncStream<SlideshowMusicPlaybackSnapshot>.Continuation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObservation: AnyCancellable?
    private var failureObservation: AnyCancellable?
    private var failed = false
    private var playbackRequested = false
    private var volumeTarget: Float = 1
    private var volumeTask: Task<Void, Never>?

    init(makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() }) {
        self.makePlayer = makePlayer
    }

    var currentTrackID: OnlineSlideshowPlaylist.Track.ID? {
        tracks.indices.contains(index) ? tracks[index].id : nil
    }

    func prepare(_ playlist: OnlineSlideshowPlaylist, startingAt trackID: OnlineSlideshowPlaylist.Track.ID)
        async throws -> SlideshowMusicPlaybackSnapshot
    {
        guard let start = playlist.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw URLError(.cannotParseResponse)
        }
        let token = UUID()
        preparation = token
        let asset = AVURLAsset(url: playlist.tracks[start].url)
        guard try await asset.load(.isPlayable) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        guard preparation == token else { throw CancellationError() }
        tracks = playlist.tracks
        index = start
        playbackRequested = false
        loadItem(asset: asset)
        return publish()
    }

    func playbackUpdates() -> AsyncStream<SlideshowMusicPlaybackSnapshot> {
        playbackContinuation?.finish()
        let stream = AsyncStream.makeStream(
            of: SlideshowMusicPlaybackSnapshot.self, bufferingPolicy: .bufferingNewest(1)
        )
        playbackContinuation = stream.continuation
        stream.continuation.yield(playbackSnapshot())
        return stream.stream
    }

    func play() async throws -> SlideshowMusicPlaybackSnapshot {
        guard tracks.indices.contains(index), let player else { return .stopped }
        playbackRequested = true
        if failed { loadItem() }
        player.play()
        return publish()
    }

    func pause() -> SlideshowMusicPlaybackSnapshot {
        playbackRequested = false
        player?.pause()
        return publish()
    }

    func setDucked(_ ducked: Bool) {
        let target: Float = ducked ? 0.5 : 1
        guard target != volumeTarget else { return }
        volumeTarget = target
        volumeTask?.cancel()
        volumeTask = nil
        guard let player else { return }
        guard player.timeControlStatus == .playing, player.volume != target else {
            player.volume = target
            return
        }

        let start = player.volume
        volumeTask = Task { @MainActor [weak player] in
            for step in 1...8 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard !Task.isCancelled, let player else { return }
                player.volume = start + (target - start) * Float(step) / 8
            }
        }
    }

    func stop() {
        preparation = UUID()
        itemGeneration = UUID()
        tracks.removeAll()
        index = 0
        failed = false
        playbackRequested = false
        itemObservation = nil
        endObservation = nil
        failureObservation = nil
        timeControlObservation = nil
        volumeTask?.cancel()
        volumeTask = nil
        volumeTarget = 1
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playbackContinuation?.finish()
        playbackContinuation = nil
    }

    func skipToNext() async throws -> SlideshowMusicPlaybackSnapshot {
        advance(by: 1)
    }

    func skipToPrevious() async throws -> SlideshowMusicPlaybackSnapshot {
        advance(by: -1)
    }

    func playbackSnapshot() -> SlideshowMusicPlaybackSnapshot {
        guard tracks.indices.contains(index) else { return .stopped }
        let track = tracks[index]
        return SlideshowMusicPlaybackSnapshot(
            isPlaying: player?.timeControlStatus == .playing,
            nowPlaying: SlideshowMusicNowPlaying(title: track.title, subtitle: track.artist, artworkURL: nil, onlineTrack: track),
            failed: failed
        )
    }

    @discardableResult
    private func advance(by step: Int) -> SlideshowMusicPlaybackSnapshot {
        guard !tracks.isEmpty else { return .stopped }
        let shouldResume = playbackRequested && !failed
        index = (index + tracks.count + step) % tracks.count
        loadItem()
        if shouldResume { player?.play() }
        return publish()
    }

    private func loadItem(asset: AVURLAsset? = nil) {
        failed = false
        let generation = UUID()
        itemGeneration = generation
        let item = AVPlayerItem(asset: asset ?? AVURLAsset(url: tracks[index].url))
        item.preferredForwardBufferDuration = 8
        if player == nil {
            let newPlayer = makePlayer()
            newPlayer.volume = volumeTarget
            player = newPlayer
        }
        guard let player else { return }
        player.pause()
        player.replaceCurrentItem(with: item)
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation else { return }
                self.publish()
            }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, change in
            guard change.newValue == .failed else { return }
            Task { @MainActor [weak self] in self?.markFailure(generation) }
        }
        endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.itemGeneration == generation else { return }
                    self.advance(by: 1)
                }
            }
        failureObservation = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in self?.markFailure(generation) }
            }
    }

    private func markFailure(_ generation: UUID) {
        guard itemGeneration == generation else { return }
        failed = true
        playbackRequested = false
        player?.pause()
        publish()
    }

    @discardableResult
    private func publish() -> SlideshowMusicPlaybackSnapshot {
        let snapshot = playbackSnapshot()
        playbackContinuation?.yield(snapshot)
        return snapshot
    }
}
