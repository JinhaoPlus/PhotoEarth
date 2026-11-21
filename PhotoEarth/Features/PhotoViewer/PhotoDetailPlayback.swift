import AVFoundation
import Combine
import Photos
import PhotosUI
import SwiftUI
import UIKit

nonisolated struct PhotoMediaDescriptor: Equatable, Sendable {
    let kind: PhotoMediaKind
    let duration: TimeInterval

    init(kind: PhotoMediaKind, duration: TimeInterval = 0) {
        self.kind = kind
        self.duration = kind == .video && duration.isFinite ? max(0, duration) : 0
    }

    init(_ record: PhotoAssetRecord) {
        self.init(kind: record.mediaKind, duration: record.duration)
    }
}

@MainActor
enum PhotoMediaPlaybackContent {
    case livePhoto(PHLivePhoto)
    case video(AVPlayerItem)
}

@MainActor
struct PhotoMediaPlaybackResult {
    let descriptor: PhotoMediaDescriptor
    let content: PhotoMediaPlaybackContent
}

nonisolated enum PhotoMediaPlaybackError: Error, Equatable {
    case assetUnavailable
    case unsupportedAsset
    case contentUnavailable
}

@MainActor
protocol PhotoMediaRequesting: AnyObject {
    @discardableResult
    func inspect(
        assetID: String,
        completion: @escaping @MainActor (PhotoMediaDescriptor?) -> Void
    ) -> UUID

    @discardableResult
    func requestPlayback(
        assetID: String,
        targetSize: CGSize,
        progress: @escaping @MainActor (Double?) -> Void,
        completion: @escaping @MainActor (Result<PhotoMediaPlaybackResult, PhotoMediaPlaybackError>) -> Void
    ) -> UUID

    func cancel(_ token: UUID)
}

/// A detail-only loader. Fetching one PHAsset happens off the main actor, and
/// motion bytes are requested only after the user asks to play them.
@MainActor
final class PhotoKitMediaRequester: PhotoMediaRequesting {
    private final class Request {
        var task: Task<Void, Never>?
        var nativeID: PHImageRequestID?
    }

    private lazy var manager = PHImageManager.default()
    private var requests: [UUID: Request] = [:]
    private var cachedAsset: (id: String, asset: PHAsset)?

    func inspect(
        assetID: String,
        completion: @escaping @MainActor (PhotoMediaDescriptor?) -> Void
    ) -> UUID {
        let token = UUID()
        let request = Request()
        requests[token] = request
        request.task = Task { [weak self, weak request] in
            guard let self, let request else { return }
            let asset = await self.asset(for: assetID)
            guard !Task.isCancelled, self.requests[token] === request else { return }
            self.requests[token] = nil
            completion(asset.flatMap(Self.descriptor))
        }
        return token
    }

    func requestPlayback(
        assetID: String,
        targetSize: CGSize,
        progress: @escaping @MainActor (Double?) -> Void,
        completion: @escaping @MainActor (Result<PhotoMediaPlaybackResult, PhotoMediaPlaybackError>) -> Void
    ) -> UUID {
        let token = UUID()
        let request = Request()
        requests[token] = request
        request.task = Task { [weak self, weak request] in
            guard let self, let request else { return }
            guard let asset = await self.asset(for: assetID) else {
                self.finish(token, request: request, result: .failure(.assetUnavailable), completion: completion)
                return
            }
            guard !Task.isCancelled, self.requests[token] === request,
                  let descriptor = Self.descriptor(asset), descriptor.kind.isPlayable else {
                if !Task.isCancelled {
                    self.finish(token, request: request, result: .failure(.unsupportedAsset), completion: completion)
                }
                return
            }

            switch descriptor.kind {
            case .livePhoto:
                let options = PHLivePhotoRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.progressHandler = { [weak self, weak request] value, error, _, _ in
                    Task { @MainActor in
                        guard let self, let request, self.requests[token] === request else { return }
                        progress(error == nil ? min(max(value, 0), 1) : nil)
                    }
                }
                request.nativeID = manager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { [weak self, weak request] livePhoto, info in
                    Task { @MainActor in
                        guard let self, let request, self.requests[token] === request else { return }
                        if Self.wasCancelled(info) { self.requests[token] = nil; return }
                        if Self.isDegraded(info) { return }
                        guard let livePhoto, Self.error(info) == nil else {
                            self.finish(token, request: request, result: .failure(.contentUnavailable), completion: completion)
                            return
                        }
                        self.finish(
                            token,
                            request: request,
                            result: .success(PhotoMediaPlaybackResult(descriptor: descriptor, content: .livePhoto(livePhoto))),
                            completion: completion
                        )
                    }
                }
            case .video:
                let options = PHVideoRequestOptions()
                options.version = .current
                options.deliveryMode = .automatic
                options.isNetworkAccessAllowed = true
                options.progressHandler = { [weak self, weak request] value, error, _, _ in
                    Task { @MainActor in
                        guard let self, let request, self.requests[token] === request else { return }
                        progress(error == nil ? min(max(value, 0), 1) : nil)
                    }
                }
                request.nativeID = manager.requestPlayerItem(forVideo: asset, options: options) { [weak self, weak request] item, info in
                    Task { @MainActor in
                        guard let self, let request, self.requests[token] === request else { return }
                        if Self.wasCancelled(info) { self.requests[token] = nil; return }
                        guard let item, Self.error(info) == nil else {
                            self.finish(token, request: request, result: .failure(.contentUnavailable), completion: completion)
                            return
                        }
                        self.finish(
                            token,
                            request: request,
                            result: .success(PhotoMediaPlaybackResult(descriptor: descriptor, content: .video(item))),
                            completion: completion
                        )
                    }
                }
            case .photo:
                finish(token, request: request, result: .failure(.unsupportedAsset), completion: completion)
            }
        }
        return token
    }

    func cancel(_ token: UUID) {
        guard let request = requests.removeValue(forKey: token) else { return }
        request.task?.cancel()
        if let nativeID = request.nativeID { manager.cancelImageRequest(nativeID) }
    }

    private func asset(for id: String) async -> PHAsset? {
        guard !SamplePhotoResource.isSample(id), PhotoKitLibrary.hasReadAccess else { return nil }
        if cachedAsset?.id == id { return cachedAsset?.asset }
        let asset = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            }
        }.value
        if let asset { cachedAsset = (id, asset) }
        return asset
    }

    private func finish(
        _ token: UUID,
        request: Request,
        result: Result<PhotoMediaPlaybackResult, PhotoMediaPlaybackError>,
        completion: @escaping @MainActor (Result<PhotoMediaPlaybackResult, PhotoMediaPlaybackError>) -> Void
    ) {
        guard requests[token] === request else { return }
        requests[token] = nil
        completion(result)
    }

    private static func descriptor(_ asset: PHAsset) -> PhotoMediaDescriptor? {
        switch asset.mediaType {
        case .image:
            return PhotoMediaDescriptor(kind: asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
        case .video:
            return PhotoMediaDescriptor(kind: .video, duration: asset.duration)
        default:
            return nil
        }
    }

    private static func wasCancelled(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true
    }

    private static func isDegraded(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true
    }

    private static func error(_ info: [AnyHashable: Any]?) -> Error? {
        info?[PHImageErrorKey] as? Error
    }

    isolated deinit {
        for request in requests.values {
            request.task?.cancel()
            if let nativeID = request.nativeID { manager.cancelImageRequest(nativeID) }
        }
    }
}

nonisolated struct LivePhotoPlaybackCommand: Equatable, Sendable {
    enum Action: Sendable { case stop, play }
    let action: Action
    let generation: UInt64
}

/// AVFoundation invokes observer blocks from sendable contexts even when their
/// queue is the main queue. This relay makes that hop explicit and keeps the
/// playback model isolated to the main actor.
private final class MainActorPlaybackRelay<Value: Sendable>: @unchecked Sendable {
    private let action: @MainActor @Sendable (Value) -> Void

    init(action: @escaping @MainActor @Sendable (Value) -> Void) {
        self.action = action
    }

    func send(_ value: Value) {
        Task { @MainActor [action] in action(value) }
    }
}

@MainActor
final class PhotoDetailPlaybackModel: ObservableObject {
    @Published private(set) var kind: PhotoMediaKind = .photo
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var livePhoto: PHLivePhoto?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double?
    @Published private(set) var hasFailed = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var liveCommand = LivePhotoPlaybackCommand(action: .stop, generation: 0)
    @Published private(set) var preparedAssetID: String?
    @Published private(set) var hasStartedPlayback = false
    @Published private(set) var didFinishPlayback = false

    var isMuted: Bool {
        didSet { player?.isMuted = isMuted }
    }

    private let requester: any PhotoMediaRequesting
    private var inspectToken: UUID?
    private var contentToken: UUID?
    private var generation = UUID()
    private var liveCommandGeneration: UInt64 = 0
    private var timeObserver: Any?
    private var playbackStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private weak var observedPlayer: AVPlayer?
    private var wantsPlayback = false

    // Slideshow playback keeps one bounded look-ahead resource. A ready
    // PHLivePhoto or AVPlayerItem can be promoted without issuing a second
    // PhotoKit request when the next memory becomes current.
    private var queuedPrefetchRecord: PhotoAssetRecord?
    private var prefetchedRecord: PhotoAssetRecord?
    private var prefetchedResult: PhotoMediaPlaybackResult?
    private var prefetchToken: UUID?
    private var prefetchGeneration = UUID()
    private var prefetchIsPromoted = false

    init(requester: (any PhotoMediaRequesting)? = nil, isMuted: Bool = false) {
        self.requester = requester ?? PhotoKitMediaRequester()
        self.isMuted = isMuted
    }

    var isPlayable: Bool { kind.isPlayable }
    var hasLoadedContent: Bool { livePhoto != nil || player != nil }

    func prepare(_ record: PhotoAssetRecord) {
        guard preparedAssetID != record.id else { return }
        let promotesPrefetch = prefetchedRecord?.id == record.id
        let readyPrefetch = promotesPrefetch ? prefetchedResult : nil
        let inFlightPrefetch = promotesPrefetch && prefetchToken != nil

        if !promotesPrefetch {
            cancelPrefetch()
            queuedPrefetchRecord = nil
        }
        resetCurrent()
        preparedAssetID = record.id
        let descriptor = PhotoMediaDescriptor(record)
        kind = descriptor.kind
        duration = descriptor.duration

        if let readyPrefetch {
            clearPrefetchState()
            install(readyPrefetch, startsPlayback: false)
        } else if inFlightPrefetch {
            // The existing request now belongs to the current memory. A play
            // command received before it completes is remembered below.
            prefetchIsPromoted = true
            isLoading = true
        }

        guard !SamplePhotoResource.isSample(record.id) else { return }
        let expectedGeneration = generation
        inspectToken = requester.inspect(assetID: record.id) { [weak self] descriptor in
            guard let self, self.generation == expectedGeneration, self.preparedAssetID == record.id else { return }
            self.inspectToken = nil
            guard let descriptor else { return }
            self.kind = descriptor.kind
            self.duration = descriptor.duration
        }
    }

    /// Slideshow-only preparation. Photo detail continues to call `prepare`
    /// and therefore never downloads motion until the user explicitly plays.
    func prepareForAutoplay(_ record: PhotoAssetRecord) {
        prepare(record)
        guard record.mediaKind.isPlayable, !SamplePhotoResource.isSample(record.id),
              !hasLoadedContent, !isLoading, !hasFailed else { return }
        loadCurrent(record, startsPlayback: false)
    }

    /// Queue at most one following dynamic asset. Current loading has priority;
    /// the look-ahead request starts only after it finishes, so this model never
    /// fans out unbounded PhotoKit media work.
    func prefetch(_ record: PhotoAssetRecord?) {
        guard let record, record.mediaKind.isPlayable,
              !SamplePhotoResource.isSample(record.id), record.id != preparedAssetID else {
            queuedPrefetchRecord = nil
            if !prefetchIsPromoted { cancelPrefetch() }
            return
        }
        if prefetchedRecord?.id == record.id {
            queuedPrefetchRecord = nil
            return
        }
        queuedPrefetchRecord = record
        if !prefetchIsPromoted, prefetchedRecord != nil { cancelPrefetch() }
        startQueuedPrefetchIfPossible()
    }

    func toggle(_ record: PhotoAssetRecord) {
        if preparedAssetID != record.id { prepare(record) }
        guard isPlayable else { return }
        // Sample posters have no motion resource. A retry must stay within
        // the sample library, including when Photos access is undetermined.
        guard !SamplePhotoResource.isSample(record.id) else {
            hasFailed = true
            return
        }
        if isLoading {
            wantsPlayback = true
            return
        }
        if hasFailed {
            player?.pause()
            removePlayerObservers()
            player = nil
            livePhoto = nil
            currentTime = 0
            loadCurrent(record, startsPlayback: true)
            return
        }
        if isPlaying { pause() }
        else if livePhoto != nil { startLivePhoto() }
        else if player != nil { startVideo() }
        else { loadCurrent(record, startsPlayback: true) }
    }

    func pause() {
        wantsPlayback = false
        if let player { player.pause() }
        if livePhoto != nil {
            liveCommandGeneration &+= 1
            liveCommand = LivePhotoPlaybackCommand(action: .stop, generation: liveCommandGeneration)
        }
        isPlaying = false
    }

    func livePhotoPlaybackDidBegin() {
        guard livePhoto != nil else { return }
        isPlaying = true
        hasStartedPlayback = true
    }

    func livePhotoPlaybackDidEnd() {
        guard livePhoto != nil, isPlaying else { return }
        isPlaying = false
        didFinishPlayback = true
    }

    func suspend() {
        pause()
        cancelContentRequest()
        cancelPrefetch()
        queuedPrefetchRecord = nil
    }

    func releaseContent() {
        reset()
    }

    private func loadCurrent(_ record: PhotoAssetRecord, startsPlayback: Bool) {
        cancelContentRequest()
        hasFailed = false
        isLoading = true
        wantsPlayback = startsPlayback
        progress = nil
        let expectedGeneration = generation
        contentToken = requester.requestPlayback(
            assetID: record.id,
            targetSize: CGSize(width: 3_840, height: 2_160),
            progress: { [weak self] progress in
                guard let self, self.generation == expectedGeneration else { return }
                self.progress = progress
            },
            completion: { [weak self] result in
                guard let self, self.generation == expectedGeneration, self.preparedAssetID == record.id else { return }
                self.contentToken = nil
                self.isLoading = false
                self.progress = nil
                switch result {
                case .failure:
                    self.hasFailed = true
                    self.wantsPlayback = false
                case .success(let result):
                    let shouldStart = self.wantsPlayback
                    self.wantsPlayback = false
                    self.install(result, startsPlayback: shouldStart)
                }
                self.startQueuedPrefetchIfPossible()
            }
        )
    }

    private func startQueuedPrefetchIfPossible() {
        guard contentToken == nil,
              !(prefetchIsPromoted && prefetchToken != nil),
              let record = queuedPrefetchRecord,
              record.id != preparedAssetID else { return }
        if prefetchedRecord?.id == record.id {
            queuedPrefetchRecord = nil
            return
        }
        cancelPrefetch()
        queuedPrefetchRecord = nil
        prefetchedRecord = record
        let expectedGeneration = UUID()
        prefetchGeneration = expectedGeneration
        prefetchToken = requester.requestPlayback(
            assetID: record.id,
            targetSize: CGSize(width: 3_840, height: 2_160),
            progress: { _ in },
            completion: { [weak self] result in
                guard let self, self.prefetchGeneration == expectedGeneration,
                      self.prefetchedRecord?.id == record.id else { return }
                self.prefetchToken = nil
                let wasPromoted = self.prefetchIsPromoted && self.preparedAssetID == record.id
                switch result {
                case .failure:
                    self.clearPrefetchState()
                    if wasPromoted {
                        self.isLoading = false
                        self.hasFailed = true
                        self.wantsPlayback = false
                    }
                case .success(let result):
                    if wasPromoted {
                        self.clearPrefetchState()
                        self.isLoading = false
                        let shouldStart = self.wantsPlayback
                        self.wantsPlayback = false
                        self.install(result, startsPlayback: shouldStart)
                    } else {
                        self.prefetchedResult = result
                    }
                }
                if wasPromoted { self.startQueuedPrefetchIfPossible() }
            }
        )
    }

    private func install(_ result: PhotoMediaPlaybackResult, startsPlayback: Bool) {
        kind = result.descriptor.kind
        duration = result.descriptor.duration
        hasFailed = false
        switch result.content {
        case .livePhoto(let livePhoto):
            removePlayerObservers()
            player?.pause()
            player = nil
            self.livePhoto = livePhoto
            if startsPlayback { startLivePhoto() }
        case .video(let item):
            livePhoto = nil
            installPlayer(item)
            if startsPlayback {
                startVideo()
            }
        }
    }

    private func startLivePhoto() {
        guard livePhoto != nil else { return }
        didFinishPlayback = false
        liveCommandGeneration &+= 1
        liveCommand = LivePhotoPlaybackCommand(action: .play, generation: liveCommandGeneration)
        isPlaying = true
    }

    private func installPlayer(_ item: AVPlayerItem) {
        removePlayerObservers()
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        observedPlayer = player
        currentTime = 0
        let playerID = ObjectIdentifier(player)
        let playbackStatusRelay = MainActorPlaybackRelay<Void> { [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID, self.isPlaying,
                  !self.hasStartedPlayback else { return }
            self.hasStartedPlayback = true
        }
        playbackStatusObserver = player.observe(\.timeControlStatus) { player, _ in
            if player.timeControlStatus == .playing { playbackStatusRelay.send(()) }
        }
        let timeRelay = MainActorPlaybackRelay<CMTime> { [weak self] time in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID else { return }
            self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            timeRelay.send(time)
        }
        let endRelay = MainActorPlaybackRelay<Void> { [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID else { return }
            let finishedWhilePlaying = self.isPlaying
            self.isPlaying = false
            self.currentTime = self.duration
            if finishedWhilePlaying { self.didFinishPlayback = true }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            endRelay.send(())
        }
        let failureRelay = MainActorPlaybackRelay<Void> { [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == playerID else { return }
            self.isPlaying = false
            self.hasFailed = true
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            failureRelay.send(())
        }
    }

    private func startVideo() {
        guard let player else { return }
        didFinishPlayback = false
        if duration > 0, currentTime >= duration - 0.25 {
            player.seek(to: .zero)
            currentTime = 0
        }
        isPlaying = true
        player.play()
    }

    private func cancelContentRequest() {
        if let contentToken { requester.cancel(contentToken) }
        contentToken = nil
        isLoading = false
        progress = nil
        wantsPlayback = false
    }

    private func resetCurrent() {
        generation = UUID()
        if let inspectToken { requester.cancel(inspectToken) }
        inspectToken = nil
        cancelContentRequest()
        pause()
        removePlayerObservers()
        player = nil
        livePhoto = nil
        preparedAssetID = nil
        kind = .photo
        duration = 0
        currentTime = 0
        hasFailed = false
        hasStartedPlayback = false
        didFinishPlayback = false
    }

    private func reset() {
        resetCurrent()
        cancelPrefetch()
        queuedPrefetchRecord = nil
    }

    private func cancelPrefetch() {
        if let prefetchToken { requester.cancel(prefetchToken) }
        prefetchGeneration = UUID()
        clearPrefetchState()
    }

    private func clearPrefetchState() {
        prefetchToken = nil
        prefetchedRecord = nil
        prefetchedResult = nil
        prefetchIsPromoted = false
    }

    private func removePlayerObservers() {
        playbackStatusObserver?.invalidate()
        playbackStatusObserver = nil
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }

    isolated deinit {
        if let inspectToken { requester.cancel(inspectToken) }
        if let contentToken { requester.cancel(contentToken) }
        if let prefetchToken { requester.cancel(prefetchToken) }
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player?.pause()
    }
}

struct LivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let command: LivePhotoPlaybackCommand
    let playbackModel: PhotoDetailPlaybackModel
    var isMuted = false
    var onDisplay: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(playbackModel: playbackModel)
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.contentMode = .scaleAspectFit
        view.isMuted = isMuted
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        view.isMuted = isMuted
        context.coordinator.playbackModel = playbackModel
        context.coordinator.onDisplay = onDisplay
        guard context.coordinator.lastCommand != command else { return }
        context.coordinator.lastCommand = command
        switch command.action {
        case .play: view.startPlayback(with: .full)
        case .stop: view.stopPlayback()
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.lastCommand = nil
        view.stopPlayback()
        view.livePhoto = nil
    }

    @MainActor
    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var lastCommand: LivePhotoPlaybackCommand?
        var onDisplay: (() -> Void)?
        weak var playbackModel: PhotoDetailPlaybackModel?

        init(playbackModel: PhotoDetailPlaybackModel) {
            self.playbackModel = playbackModel
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            guard let expectedLivePhoto = livePhotoView.livePhoto,
                  let command = lastCommand, command.action == .play else { return }
            let model = playbackModel
            Task { @MainActor [weak model] in
                // PHLivePhotoView may synchronously invoke its delegate from
                // updateUIView. Publishing on the following actor turn keeps
                // ObservableObject mutations outside SwiftUI's update pass.
                await Task.yield()
                guard let model, model.livePhoto === expectedLivePhoto,
                      model.liveCommand == command, self.lastCommand == command else { return }
                model.livePhotoPlaybackDidBegin()
                self.onDisplay?()
            }
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            guard let expectedLivePhoto = livePhotoView.livePhoto,
                  let command = lastCommand, command.action == .play else { return }
            let model = playbackModel
            Task { @MainActor [weak model] in
                await Task.yield()
                guard let model, model.livePhoto === expectedLivePhoto,
                      model.liveCommand == command, self.lastCommand == command else { return }
                model.livePhotoPlaybackDidEnd()
            }
        }
    }
}

struct PhotoVideoPlaybackView: UIViewRepresentable {
    let player: AVPlayer
    var onDisplay: (() -> Void)?

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.observeDisplay(ifNeeded: onDisplay)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.cancelDisplayObservation()
            view.playerLayer.player = player
            view.observeDisplay(ifNeeded: onDisplay)
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Void) {
        view.cancelDisplayObservation()
        view.playerLayer.player = nil
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var observation: NSKeyValueObservation?

        func observeDisplay(ifNeeded onDisplay: (() -> Void)?) {
            guard let onDisplay, let player = playerLayer.player else { return }
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak player] _, _ in
                guard let view = self, let player else { return }
                Task { @MainActor in
                    guard view.playerLayer.player === player, view.playerLayer.isReadyForDisplay else { return }
                    view.cancelDisplayObservation()
                    onDisplay()
                }
            }
        }

        func cancelDisplayObservation() {
            observation?.invalidate()
            observation = nil
        }
    }
}
