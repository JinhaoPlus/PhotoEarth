import Photos
import Testing
import UIKit
@testable import PhotoEarth

@MainActor struct SharedPhotoImageSchedulerTests {
    @Test func homeWallStripAndDetailShareOneLocalAndCloudBudget() {
        let rig = Rig()
        for index in 0..<18 {
            rig.scheduler.request(key(index), network: false, priority: index == 0 ? .detail : .visible,
                                  token: UUID()) { _ in }
        }
        #expect(rig.backend.active.count == 4)
        for request in Array(rig.backend.active) { rig.backend.deliver(request, .init()) }
        #expect(rig.scheduler.activeLocalCount <= 4)
        for index in 30..<40 {
            rig.scheduler.request(key(index), network: true, priority: .visible, token: UUID()) { _ in }
        }
        rig.advance(0.3)
        #expect(rig.scheduler.activeNetworkCount == 2)
        #expect(rig.scheduler.metrics.peakLocal == 4)
        #expect(rig.scheduler.metrics.peakNetwork == 2)
        #expect(rig.scheduler.accountedBytes <= rig.configuration.totalBytes)
    }

    @Test func sameImageSharesWorkAndOneConsumerCanLeaveWithoutCancellingTheOther() {
        let rig = Rig()
        let first = UUID(), second = UUID()
        let deliveries = Recorder()
        rig.scheduler.request(key(0), network: false, priority: .visible, token: first) { _ in deliveries.first += 1 }
        rig.scheduler.request(key(0), network: false, priority: .focus, token: second) { _ in deliveries.second += 1 }
        #expect(rig.backend.requests.count == 1)
        #expect(rig.scheduler.metrics.deduplicated == 1)
        rig.scheduler.cancel(first)
        #expect(rig.backend.cancelled.isEmpty)
        rig.backend.deliver(rig.backend.requests[0], .init(image: image()))
        #expect(deliveries.first == 0 && deliveries.second == 1)
        #expect(rig.scheduler.subscriptionCount == 0)
    }

    @Test func selectedDetailPreemptsSlowVisibleDownloadAndRejectsTheCancelledHandle() {
        let rig = Rig()
        let recorder = Recorder()
        for index in 0..<2 {
            rig.scheduler.request(key(index), network: true, priority: .visible, token: UUID()) { _ in recorder.first += 1 }
        }
        rig.advance(0.3)
        let old = rig.backend.requests
        rig.scheduler.request(key(8, edge: 3_840), network: true, priority: .detail, token: UUID()) { _ in recorder.second += 1 }
        #expect(rig.backend.active.contains { $0.key.assetID == "fixture-8" })
        #expect(rig.scheduler.activeNetworkCount == 2)
        #expect(rig.backend.cancelled.count == 1)
        let cancelled = old.first { rig.backend.cancelled.contains($0.token) }!
        rig.backend.deliver(cancelled, .init(image: image()))
        #expect(recorder.first == 0)
    }

    @Test func noCallbackTimesOutBothStagesAndKeepsAnAlreadyShownPreview() {
        let rig = Rig()
        let requester = PhotoKitImageRequester(scheduler: rig.scheduler)
        let loader = PhotoImageLoader(requester: requester)
        let preview = image(edge: 40)
        loader.load(assetID: "fixture-timeout", targetSize: CGSize(width: 960, height: 960), initialImage: preview)
        #expect(rig.backend.requests.count == 1)
        rig.advance(2.1)
        // Visible cloud downloads have a dwell gate; the local slot is released.
        rig.advance(0.3)
        #expect(rig.backend.requests.count == 2)
        #expect(rig.backend.requests[1].network)
        #expect(rig.scheduler.activeLocalCount == 0)
        rig.advance(30.1)
        #expect(loader.hasFailed && !loader.isLoading)
        #expect(loader.image === preview)
        #expect(rig.scheduler.subscriptionCount == 0)
        #expect(rig.scheduler.metrics.timeouts == 2)
    }

    @Test func degradedLocalResultWaitsForFinalBeforeCloudAndPrefetchNeverDownloads() {
        let rig = Rig()
        let requester = PhotoKitImageRequester(scheduler: rig.scheduler)
        _ = requester.requestImage(assetID: "fixture-degraded", targetSize: CGSize(width: 640, height: 640),
                                   contentMode: .aspectFit, priority: .focus) { _ in }
        let local = rig.backend.requests[0]
        rig.backend.deliver(local, .init(image: image(), isFinal: false, needsNetwork: true))
        rig.advance(0.4)
        #expect(rig.backend.requests.count == 1)
        rig.backend.deliver(local, .init(needsNetwork: true))
        #expect(rig.backend.requests.count == 2 && rig.backend.requests[1].network)
        _ = requester.requestImage(assetID: "fixture-neighbor", targetSize: CGSize(width: 960, height: 960),
                                   contentMode: .aspectFit, priority: .prefetch) { _ in }
        rig.backend.deliver(rig.backend.requests.last!, .init(needsNetwork: true))
        rig.advance(1)
        #expect(!rig.backend.requests.contains { $0.key.assetID == "fixture-neighbor" && $0.network })
    }

    @Test func focusingAnImageKeepsItsActiveLocalRequest() throws {
        let rig = Rig()
        let loader = PhotoImageLoader(requester: PhotoKitImageRequester(scheduler: rig.scheduler))
        loader.load(assetID: "fixture-priority", targetSize: CGSize(width: 640, height: 400), priority: .visible)
        let local = try #require(rig.backend.requests.first)

        loader.updatePriority(.focus)
        #expect(rig.backend.requests.count == 1)
        #expect(!rig.backend.cancelled.contains(local.token))

        let thumbnail = image()
        rig.backend.deliver(local, .init(image: thumbnail))
        loader.updatePriority(.visible)
        #expect(loader.image === thumbnail)
        #expect(rig.backend.requests.count == 1)
    }

    @Test func visibleCoverResumesACloudMissWithoutRepeatingTheLocalStage() throws {
        let rig = Rig()
        let loader = PhotoImageLoader(requester: PhotoKitImageRequester(scheduler: rig.scheduler))
        loader.load(assetID: "fixture-cloud-cover", targetSize: CGSize(width: 640, height: 400), priority: .prefetch)
        let local = try #require(rig.backend.requests.first)
        rig.backend.deliver(local, .init(needsNetwork: true))
        #expect(rig.backend.requests.count == 1)

        loader.updatePriority(.focus)
        let cloud = try #require(rig.backend.requests.last)
        #expect(cloud.network && loader.isLoading)

        loader.updatePriority(.prefetch)
        #expect(rig.backend.cancelled.contains(cloud.token))
        #expect(!loader.isLoading)

        loader.updatePriority(.focus)
        let resumed = try #require(rig.backend.requests.last)
        #expect(resumed.network && resumed.token != cloud.token)
        #expect(rig.backend.requests.filter { !$0.network }.count == 1)
        let thumbnail = image()
        rig.backend.deliver(resumed, .init(image: thumbnail))
        #expect(loader.image === thumbnail)
        #expect(!loader.isLoading && !loader.hasFailed)
    }

    @Test func selectedCoverOnlyReadsOriginalAfterAnUndersizedNetworkRendition() {
        #expect(PhotoImageSizing.coverAction(deliveredEdge: 640, requiredEdge: 640, network: false) == .display)
        #expect(PhotoImageSizing.coverAction(deliveredEdge: 639, requiredEdge: 640, network: true) == .display)
        #expect(PhotoImageSizing.coverAction(deliveredEdge: 200, requiredEdge: 640, network: false) == .requestNetworkRendition)
        #expect(PhotoImageSizing.coverAction(deliveredEdge: 200, requiredEdge: 640, network: true) == .requestOriginal)
        #expect(PhotoImageSizing.coverAction(deliveredEdge: 0, requiredEdge: 1, network: false) == .requestNetworkRendition)
    }

    @Test func localCoversShareThumbnailSlotsAndReuseOnlyFullFramePreviews() throws {
        let rig = Rig()
        let size = CGSize(width: 640, height: 400)
        let cropped = SharedPhotoImageKey(assetID: "same", targetSize: size, fillsTarget: true)
        rig.scheduler.request(cropped, network: false, priority: .visible, token: UUID()) { _ in }
        rig.backend.deliver(try #require(rig.backend.active.first), .init(image: image(edge: 100)))
        #expect(rig.scheduler.cachedPreview(for: "same", fullFrameOnly: true) == nil)

        let keys = ["same", "second", "third", "fourth"].map {
            SharedPhotoImageKey(assetID: $0, targetSize: size, fillsTarget: true, usesOriginal: true)
        }
        for key in keys {
            rig.scheduler.request(key, network: false, priority: .visible, token: UUID()) { _ in }
        }
        #expect(rig.backend.active.count == 4)
        for request in Array(rig.backend.active) {
            rig.backend.deliver(request, .init(image: image(edge: 300)))
        }
        #expect(rig.scheduler.cachedPreview(for: "same", fullFrameOnly: true) != nil)
        for key in keys {
            rig.scheduler.request(key, network: true, priority: .visible, token: UUID()) { _ in }
        }
        rig.advance(1)
        #expect(rig.backend.requests.allSatisfy { !$0.network })
    }

    @Test func selectedVisitCoverDisplaysTheSameAssetPreviewWhileWaitingForItsOriginal() throws {
        let rig = Rig()
        let loader = PhotoImageLoader(requester: PhotoKitImageRequester(scheduler: rig.scheduler))
        loader.load(assetID: "fixture-visit-cover", targetSize: CGSize(width: 640, height: 400),
                    usesOriginal: true)
        let local = try #require(rig.backend.requests.first)
        #expect(local.key.assetID == "fixture-visit-cover")
        #expect(local.key.usesOriginal && !local.network)
        let preview = image(edge: 64)
        rig.backend.deliver(local, .init(image: preview, isFinal: false))
        rig.backend.deliver(local, .init(needsNetwork: true))
        rig.advance(0.3)
        let cloud = try #require(rig.backend.requests.last)
        #expect(cloud.network && cloud.key == local.key)
        #expect(loader.image === preview)
        let full = image(edge: 640)
        rig.backend.deliver(cloud, .init(image: full))
        #expect(loader.image === full && !loader.isLoading)
    }

    @Test func fullImagesHaveASeparateOneImageCacheAndRecentWallPreviewIsReusable() {
        let rig = Rig()
        rig.scheduler.request(key(0, edge: 960), network: false, priority: .visible, token: UUID()) { _ in }
        let preview = image(edge: 40)
        rig.backend.deliver(rig.backend.requests.last!, .init(image: preview))
        for index in 10..<13 {
            rig.scheduler.request(key(index, edge: 3_840), network: false, priority: .detail, token: UUID()) { _ in }
            rig.backend.deliver(rig.backend.requests.last!, .init(image: image(edge: 80)))
        }
        #expect(rig.scheduler.cachedImageCount == 2)
        #expect(rig.scheduler.cachedPreview(for: "fixture-0") === preview)
        let before = rig.backend.requests.count
        rig.scheduler.request(key(0, edge: 960), network: false, priority: .focus, token: UUID()) { result in
            #expect(result.image === preview)
        }
        #expect(rig.backend.requests.count == before)
        rig.scheduler.memoryWarning()
        #expect(rig.scheduler.cachedImageCount == 0)
    }

    @Test func cachesStayBoundedWhileManyPagesPassAndQueuedCloudReusesLocalCompletion() throws {
        var configuration = SharedPhotoImageScheduler.Configuration()
        configuration.previewBytes = 12 * 1_024
        let rig = Rig(configuration: configuration)
        let preview = image(edge: 32)
        let pixels = try #require(preview.cgImage)
        // UIKit may optimize this synthetic monochrome image to two bytes per
        // pixel. Assert the actual decoded storage budget, not a presumed RGBA.
        let maximumRetained = configuration.previewBytes / (pixels.bytesPerRow * pixels.height)
        #expect(maximumRetained < 100)
        for index in 0..<100 {
            rig.scheduler.request(key(index, edge: 960), network: false, priority: .visible, token: UUID()) { _ in }
            rig.backend.deliver(rig.backend.requests.last!, .init(image: preview))
            #expect(rig.scheduler.cachedImageCount <= maximumRetained)
            #expect(rig.scheduler.accountedBytes <= configuration.totalBytes)
        }
        let shared = key(200)
        rig.scheduler.request(shared, network: false, priority: .focus, token: UUID()) { _ in }
        let local = rig.backend.requests.last!
        rig.scheduler.request(shared, network: true, priority: .focus, token: UUID()) { _ in }
        let count = rig.backend.requests.count
        rig.backend.deliver(local, .init(image: image()))
        #expect(rig.backend.requests.count == count)
        #expect(rig.scheduler.subscriptionCount == 0)
    }

    @Test func metadataInvalidationAndLastSubscriberCancellationRejectLateDelivery() {
        let rig = Rig()
        let recorder = Recorder()
        let token = UUID()
        rig.scheduler.request(key(0), network: false, priority: .visible, token: token) { _ in recorder.first += 1 }
        let cancelled = rig.backend.requests.last!
        rig.scheduler.cancel(token)
        rig.backend.deliver(cancelled, .init(image: image()))
        #expect(recorder.first == 0)
        rig.scheduler.request(key(0), network: false, priority: .visible, token: UUID()) { _ in recorder.second += 1 }
        let stale = rig.backend.requests.last!
        rig.scheduler.invalidate(["fixture-0"])
        #expect(recorder.second == 1)
        rig.backend.deliver(stale, .init(image: image()))
        #expect(recorder.second == 1)
        #expect(rig.scheduler.cachedImageCount == 0 && rig.scheduler.subscriptionCount == 0)
    }

    @Test func wallRequestsRespectActualGeometryAndFocusUsesABoundedUpgrade() {
        let narrow = PhotoImageSizing.wallTargetSize(pixelWidth: 1_000, pixelHeight: 5_000,
            cardSize: CGSize(width: 75, height: 375), displayScale: 1, isFocused: false)
        let panorama = PhotoImageSizing.wallTargetSize(pixelWidth: 30_000, pixelHeight: 3_000,
            cardSize: CGSize(width: 800, height: 375), displayScale: 2, isFocused: true)
        #expect(narrow.width < 200 && narrow.height <= 640)
        #expect(panorama.width <= 1_600 && panorama.height <= 160)
        #expect(narrow.width / narrow.height == 0.2)
    }

    private func key(_ index: Int, edge: Int = 640) -> SharedPhotoImageKey {
        .init(assetID: "fixture-\(index)", targetSize: CGSize(width: edge, height: edge == 3_840 ? 2_160 : edge), fillsTarget: false)
    }
    private func image(edge: CGFloat = 20) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in }
    }
    @MainActor private final class Recorder { var first = 0; var second = 0 }
    @MainActor private final class Rig {
        let backend = Backend()
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        let configuration: SharedPhotoImageScheduler.Configuration
        init(configuration: SharedPhotoImageScheduler.Configuration = .init()) { self.configuration = configuration }
        lazy var scheduler = SharedPhotoImageScheduler(requester: backend, configuration: configuration,
            now: { [unowned self] in self.date }, automaticScheduling: false)
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds); scheduler.tick() }
    }
    @MainActor private final class Backend: SharedPhotoImageRequesting {
        struct Request {
            let key: SharedPhotoImageKey
            let network: Bool
            let token: UUID
            let completion: @MainActor @Sendable (OverviewImageDelivery) -> Void
        }
        var requests: [Request] = []
        var ended: Set<UUID> = []
        var cancelled: Set<UUID> = []
        var active: [Request] { requests.filter { !ended.contains($0.token) && !cancelled.contains($0.token) } }
        func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                     completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
            requests.append(Request(key: key, network: network, token: token, completion: completion))
        }
        func cancel(_ token: UUID) { cancelled.insert(token) }
        func invalidate(_ ids: Set<String>?) {}
        func deliver(_ request: Request, _ result: OverviewImageDelivery) {
            if result.isFinal { ended.insert(request.token) }
            request.completion(result)
        }
    }
}
