import AVFoundation
import Foundation
import PhotosUI
import SQLite3
import SwiftUI
import Testing
@testable import PhotoEarth

@Suite(.serialized)
@MainActor
struct PhotoMediaSupportTests {
    @Test func mediaRecordsKeepOnlyMeaningfulVideoDurations() {
        let livePhoto = record(id: "live", kind: .livePhoto, duration: 3.2)
        let video = record(id: "video", kind: .video, duration: 125.4)
        let invalidVideo = record(id: "invalid-video", kind: .video, duration: .infinity)

        #expect(livePhoto.duration == 0)
        #expect(video.duration == 125.4)
        #expect(invalidVideo.duration == 0)
        #expect(!PhotoMediaKind.photo.isPlayable)
        #expect(PhotoMediaKind.livePhoto.isPlayable)
        #expect(PhotoMediaKind.video.isPlayable)
    }

    @Test func mediaKindsAndVideoDurationRoundTripThroughSQLite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let records = [
            record(id: "still", kind: .photo, time: 1),
            record(id: "live", kind: .livePhoto, time: 2),
            record(id: "video", kind: .video, duration: 185.75, time: 3),
        ]
        try await store.save(snapshot(records))

        let page = try await store.photoPage(for: ["media-place"], offset: 0, limit: 48)
        let loaded = Dictionary(uniqueKeysWithValues: page.records.map { ($0.id, $0) })
        #expect(loaded["still"]?.mediaKind == .photo)
        #expect(loaded["live"]?.mediaKind == .livePhoto)
        #expect(loaded["video"]?.mediaKind == .video)
        #expect(loaded["video"]?.duration == 185.75)
    }

    @Test func legacyVersionFourIndexMigratesInPlaceAndForcesMetadataRefresh() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.sqlite")
        try createVersionFourDatabase(at: url)

        let store = SQLiteTravelIndexStore(databaseURL: url)
        let index = try #require(try await store.load())
        #expect(index.schemaVersion == TravelIndex.currentSchemaVersion)
        #expect(index.locatedPhotoCount == 1)

        let page = try await store.photoPage(for: ["legacy-place"], offset: 0, limit: 1)
        #expect(page.records.first?.mediaKind == .photo)
        #expect(page.records.first?.duration == 0)
        #expect(try await store.loadSyncState().token == nil)
    }

    @Test func incrementalMediaEditUpdatesPlaybackMetadataWithoutReclustering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let still = record(id: "edited-media", kind: .photo, time: 4)
        try await store.save(snapshot([still]))

        let run = try await store.beginMetadataScan(copyCurrent: true)
        let video = record(id: still.id, kind: .video, duration: 61.5, time: 4)
        let changedStructure = try await store.stageMetadata(
            PhotoMetadataBatch(records: [video], removedIDs: [video.id]),
            run: run
        )
        #expect(!changedStructure)
        _ = try await store.commitDisplayChanges(
            run: run,
            token: Data("media-edit".utf8),
            sourcePhotoCount: 1,
            authorization: "authorized"
        )

        let page = try await store.photoPage(for: ["media-place"], offset: 0, limit: 1)
        #expect(page.records.first?.mediaKind == .video)
        #expect(page.records.first?.duration == 61.5)
    }

    @Test func fictionalMediaNeverConsultsTheLibraryForPlaybackOrRetries() {
        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester)
        let live = record(id: "sample-ratio-landscape-60", kind: .livePhoto)
        let video = record(id: "sample-ratio-panorama-59", kind: .video, duration: 8)
        model.prepareForAutoplay(live)
        model.prefetch(video)
        for sample in [live, video] {
            model.prepare(sample)
            model.toggle(sample)
            model.toggle(sample)
            #expect(model.hasFailed)
            #expect(!model.isLoading)
        }
        #expect(requester.inspectedAssetIDs.isEmpty)
        #expect(requester.requestedAssetIDs.isEmpty)
    }

    @Test func playbackIsLazyRetryableAndCancelsWhenTheSelectionChanges() {
        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester)
        let first = record(id: "video-a", kind: .video, duration: 12)
        let second = record(id: "video-b", kind: .video, duration: 8)

        model.prepare(first)
        #expect(model.kind == .video)
        #expect(requester.playbackRequests.isEmpty)

        model.toggle(first)
        let failedToken = requester.latestPlaybackToken
        #expect(failedToken != nil)
        #expect(model.isLoading)
        requester.fail(failedToken)
        #expect(model.hasFailed)
        #expect(!model.isLoading)

        model.toggle(first)
        let cancelledToken = requester.latestPlaybackToken
        #expect(cancelledToken != nil)
        #expect(cancelledToken != failedToken)
        model.prepare(second)
        #expect(cancelledToken.map(requester.cancelled.contains) == true)
        #expect(model.kind == .video)
        #expect(!model.hasFailed)
    }

    @Test func slideshowAutoplayPromotesAnInFlightNextItemWithoutRequestingItTwice() {
        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester)
        let first = record(id: "video-a", kind: .video, duration: 12)
        let second = record(id: "video-b", kind: .video, duration: 8)

        model.prepareForAutoplay(first)
        let firstToken = requester.token(for: first.id)
        #expect(requester.requestedAssetIDs == [first.id])

        model.prefetch(second)
        #expect(requester.requestedAssetIDs == [first.id])
        requester.fail(firstToken)

        let secondToken = requester.token(for: second.id)
        #expect(secondToken != nil)
        #expect(requester.requestedAssetIDs == [first.id, second.id])

        model.prepareForAutoplay(second)
        #expect(model.preparedAssetID == second.id)
        #expect(model.isLoading)
        #expect(requester.requestedAssetIDs == [first.id, second.id])

        model.toggle(second)
        requester.fail(secondToken)
        #expect(model.hasFailed)
        #expect(!model.isLoading)
        #expect(requester.requestedAssetIDs == [first.id, second.id])
        model.releaseContent()
    }

    @Test func releasingSlideshowPlaybackCancelsItsSingleLookAheadRequest() {
        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester)
        let still = record(id: "still", kind: .photo)
        let next = record(id: "video-next", kind: .video, duration: 6)

        model.prepareForAutoplay(still)
        model.prefetch(next)
        let token = requester.token(for: next.id)
        #expect(token != nil)

        model.releaseContent()
        #expect(token.map(requester.cancelled.contains) == true)
    }

    @Test func slideshowVideoPreparationDoesNotPrerollBeforeThePlayerIsReady() throws {
        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester, isMuted: true)
        let video = record(id: "video-unready", kind: .video, duration: 6)

        model.prepareForAutoplay(video)
        let token = try #require(requester.token(for: video.id))
        let item = AVPlayerItem(asset: AVMutableComposition())
        requester.succeedVideo(token, item: item, duration: video.duration)

        let player = try #require(model.player)
        #expect(player.isMuted)
        #expect(!model.isPlaying)
        model.isMuted = false
        #expect(!player.isMuted)
        model.releaseContent()
    }

    @Test(arguments: [false, true])
    func slideshowOriginalSoundWaitsForNativePlaybackAndRequiresAnAudioTrack(hasAudio: Bool) async throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movieURL = folder.appendingPathComponent("video.mov")
        let duration = CMTime(seconds: 4, preferredTimescale: 600)
        try await writeTestMovie(to: movieURL, duration: duration)

        let movie = AVURLAsset(url: movieURL)
        let composition = AVMutableComposition()
        let videoTrack = try #require(try await movie.loadTracks(withMediaType: .video).first)
        let destination = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try destination.insertTimeRange(try await videoTrack.load(.timeRange), of: videoTrack, at: .zero)
        if hasAudio {
            let audioURL = folder.appendingPathComponent("audio.caf")
            try writeTestAudio(to: audioURL)
            let audio = AVURLAsset(url: audioURL)
            let track = try #require(try await audio.loadTracks(withMediaType: .audio).first)
            let destination = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        }

        let requester = ControlledMediaRequester()
        let model = PhotoDetailPlaybackModel(requester: requester, isMuted: true)
        defer { model.releaseContent() }
        let video = record(id: "video-with-original-sound", kind: .video, duration: duration.seconds)
        model.prepareForAutoplay(video)
        let token = try #require(requester.token(for: video.id))
        requester.succeedVideo(token, item: AVPlayerItem(asset: composition), duration: video.duration)
        #expect(!model.isOriginalAudioReady)

        model.toggle(video)
        #expect(model.isPlaying)
        #expect(!model.isOriginalAudioReady)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.hasStartedPlayback, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.hasStartedPlayback)
        #expect(model.isOriginalAudioReady == hasAudio)

        model.pause()
        #expect(!model.isOriginalAudioReady)
    }

    @Test func livePhotoAndPosterFillTheSameSlideshowCanvas() async throws {
        let record = record(id: "live-layout", kind: .livePhoto)
        let visit = try #require(snapshot([record]).index.places.first)
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.01
        let coordinator = EarthSlideshowCoordinator(
            scope: .init(id: visit.id, title: visit.name, kind: .recentVisit), places: [visit],
            configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()), makeSnapshot: {
                let frozen = try SlideshowSnapshot()
                try frozen.append([record])
                return frozen
            }, cameraAction: { _, _ in }
        )
        coordinator.start()
        defer { coordinator.cancel() }
        for _ in 0..<200 where coordinator.phase != .presentingItem {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(coordinator.phase == .presentingItem)
        coordinator.setPaused(true)
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        coordinator.markCurrentItemReady(record.id, image: poster)
        let requester = ControlledMediaRequester()
        let playback = PhotoDetailPlaybackModel(requester: requester, isMuted: true)
        playback.prepareForAutoplay(record)
        let token = try #require(requester.latestPlaybackToken)
        let completion = try #require(requester.playbackRequests[token])
        let placeholders = AsyncStream<PHLivePhoto> { stream in
            PHLivePhoto.request(withResourceFileURLs: [], placeholderImage: poster, targetSize: .zero, contentMode: .aspectFit) { photo, _ in
                if let photo { stream.yield(photo) }
                stream.finish()
            }
        }
        let live = try #require(await placeholders.first(where: { _ in true }))
        completion(.success(.init(descriptor: .init(record), content: .livePhoto(live))))

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ZStack {
            SlideshowMediaTimeline(coordinator: coordinator, playback: playback, onDisplay: { _ in })
        }.ignoresSafeArea())
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        func descendant<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            return root.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        let canvas = try #require(descendant(SlideshowTransitionCanvas.Stage.self, in: host.view))
        let motion = try #require(descendant(PHLivePhotoView.self, in: host.view))
        #expect(canvas.convert(canvas.bounds, to: window) == window.bounds)
        #expect(motion.convert(motion.bounds, to: window) == window.bounds)
    }

    private func record(
        id: String,
        kind: PhotoMediaKind,
        duration: TimeInterval = 0,
        time: TimeInterval = 0
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: id,
            coordinate: GeoCoordinate(latitude: 35, longitude: 139),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + time),
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            isFavorite: false,
            mediaKind: kind,
            duration: duration,
            placeID: "media-place"
        )
    }

    private func snapshot(_ records: [PhotoAssetRecord]) -> TravelIndexSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let place = TravelPlace(
            id: "media-place",
            name: "Tokyo",
            country: "Japan",
            coordinate: GeoCoordinate(latitude: 35, longitude: 139),
            startDate: date,
            endDate: date.addingTimeInterval(10),
            photoCount: records.count,
            coverAssetID: records.first?.id
        )
        return TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: date,
                sourcePhotoCount: records.count,
                locatedPhotoCount: records.count,
                places: [place],
                journeys: []
            ),
            photos: records
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-media-\(UUID().uuidString)")
    }

    private func createVersionFourDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "PhotoMediaSupportTests", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('schema_version', '4');
            INSERT INTO metadata VALUES ('generated_at', '1700000000');
            INSERT INTO metadata VALUES ('source_photo_count', '1');
            INSERT INTO metadata VALUES ('located_photo_count', '1');
            CREATE TABLE places (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, name TEXT NOT NULL, country TEXT,
                latitude REAL NOT NULL, longitude REAL NOT NULL, start_date REAL NOT NULL, end_date REAL NOT NULL,
                photo_count INTEGER NOT NULL, cover_asset_id TEXT
            );
            INSERT INTO places VALUES ('legacy-place', 0, 'Legacy', NULL, 35, 139, 1700000000, 1700000000, 1, 'legacy-photo');
            CREATE TABLE photos (
                id TEXT PRIMARY KEY NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
                creation_date REAL NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
                favorite INTEGER NOT NULL, place_id TEXT, latitude_cell INTEGER NOT NULL, longitude_cell INTEGER NOT NULL
            );
            INSERT INTO photos VALUES ('legacy-photo', 35, 139, 1700000000, 1920, 1080, 0, 'legacy-place', 12, 31);
            CREATE TABLE scan_photos (
                id TEXT PRIMARY KEY, latitude REAL NOT NULL, longitude REAL NOT NULL, creation_date REAL NOT NULL,
                pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL, favorite INTEGER NOT NULL,
                group_number INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE library_sync (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO library_sync VALUES ('token', 'bGVnYWN5');
            """
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite setup failed"
            throw NSError(domain: "PhotoMediaSupportTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}

@MainActor
private final class ControlledMediaRequester: PhotoMediaRequesting {
    typealias PlaybackCompletion = @MainActor (Result<PhotoMediaPlaybackResult, PhotoMediaPlaybackError>) -> Void

    private(set) var playbackRequests: [UUID: PlaybackCompletion] = [:]
    private(set) var playbackAssetIDs: [UUID: String] = [:]
    private(set) var requestedAssetIDs: [String] = []
    private(set) var cancelled: Set<UUID> = []
    private(set) var latestPlaybackToken: UUID?
    private(set) var inspectedAssetIDs: [String] = []

    func inspect(
        assetID: String,
        completion: @escaping @MainActor (PhotoMediaDescriptor?) -> Void
    ) -> UUID {
        inspectedAssetIDs.append(assetID)
        return UUID()
    }

    func requestPlayback(
        assetID: String,
        targetSize: CGSize,
        progress: @escaping @MainActor (Double?) -> Void,
        completion: @escaping PlaybackCompletion
    ) -> UUID {
        let token = UUID()
        playbackRequests[token] = completion
        playbackAssetIDs[token] = assetID
        requestedAssetIDs.append(assetID)
        latestPlaybackToken = token
        return token
    }

    func cancel(_ token: UUID) {
        cancelled.insert(token)
        playbackRequests[token] = nil
        playbackAssetIDs[token] = nil
    }

    func fail(_ token: UUID?) {
        guard let token, let completion = playbackRequests.removeValue(forKey: token) else { return }
        playbackAssetIDs[token] = nil
        completion(.failure(.contentUnavailable))
    }

    func succeedVideo(_ token: UUID, item: AVPlayerItem, duration: TimeInterval) {
        guard let completion = playbackRequests.removeValue(forKey: token) else { return }
        playbackAssetIDs[token] = nil
        completion(.success(PhotoMediaPlaybackResult(
            descriptor: PhotoMediaDescriptor(kind: .video, duration: duration),
            content: .video(item)
        )))
    }

    func token(for assetID: String) -> UUID? {
        playbackAssetIDs.first(where: { $0.value == assetID })?.key
    }

}

@MainActor
func writeTestAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
    let samples = try #require(buffer.floatChannelData?[0])
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        samples[frame] = 0.05 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
