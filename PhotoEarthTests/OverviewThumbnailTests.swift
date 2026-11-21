import Foundation
import Testing
import UIKit
@testable import PhotoEarth

@MainActor struct OverviewThumbnailTests {
    @Test func originalCoverIsDownsampledAndKeepsItsPhotosOrientation() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 800), format: format)
            .jpegData(withCompressionQuality: 0.95) { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 800))
            }
        let image = try #require(await CoverOriginalImageRequest.decode(data, orientation: .right, longEdge: 640))
        let pixels = try #require(image.cgImage)
        #expect(pixels.width == 640)
        #expect(pixels.height == 320)
        #expect(image.imageOrientation == .right)
    }

    @Test func realAdapterCancellationDoesNotLoseTheNextPublicSampleRequest() async {
        let requester = OverviewPhotoKitRequester()
        let recorder = DeliveryRecorder()
        let key = OverviewImageKey(assetID: "sample-reykjavik-1", size: .dock)
        let cancelled = UUID()
        requester.request(key, network: false, reduced: false, token: cancelled) { _ in recorder.cancelledDeliveries += 1 }
        requester.cancel(cancelled)
        requester.invalidate([key.assetID])
        requester.request(key, network: false, reduced: false, token: UUID()) { result in
            if result.isFinal { recorder.finalImage = result.image }
        }
        for _ in 0..<100 where recorder.finalImage == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.cancelledDeliveries == 0)
        #expect(recorder.finalImage != nil)
        let width = recorder.finalImage?.cgImage?.width ?? 0
        #expect(width > 320 && width <= 640)
        #expect(key.requestKey().height == 384)
        #expect(key.requestKey(reduced: true).height == 192)
    }

    @Test func malformedOversizedDemandStillHonorsTheFifteenImageWindow() {
        let rig = Rig()
        rig.pipeline.update(Dictionary(uniqueKeysWithValues: (0..<100).map { (key($0), 1) }), moving: false)
        for _ in 0..<100 {
            guard let request = rig.backend.active.first else { break }
            rig.backend.deliver(request, .init(image: makeImage()))
        }
        #expect(rig.backend.requests.count == 15)
        #expect(rig.pipeline.retainedImageCount == 15)
    }

    @Test func queuedCloudCoversFollowTheCurrentFocusRowBeforeOtherVisibleRows() throws {
        var configuration = OverviewThumbnailPipeline.Configuration()
        configuration.networkLimit = 1
        let rig = Rig(configuration: configuration)
        let keys = (0..<4).map(key)
        let demand = Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) })
        rig.pipeline.update(demand, moving: false, focusedRowOrder: [keys[0]: 0, keys[1]: 1])
        for request in rig.backend.active { rig.backend.deliver(request, .init(needsNetwork: true)) }
        rig.advance(1)
        let first = try #require(rig.backend.active.filter { $0.network }.first)
        #expect(first.key == keys[0])
        rig.pipeline.update(demand, moving: false, focusedRowOrder: [keys[3]: 0, keys[2]: 1])
        rig.backend.deliver(first, .init(image: makeImage()))
        let next = try #require(rig.backend.active.filter { $0.network }.first)
        #expect(next.key == keys[3])
        #expect(rig.backend.cancelled.isEmpty)
    }

    @Test func localAndCloudConcurrencyAreIndependentAndOffscreenDoesNotDownload() {
        let rig = Rig()
        let keys = (0..<15).map(key)
        rig.pipeline.update(Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset < 5 ? 1 : 2) }), moving: false)
        #expect(rig.backend.requests.count == 4)
        for _ in 0..<15 {
            guard let request = rig.backend.active.first(where: { !$0.network }) else { break }
            rig.backend.deliver(request, .init(needsNetwork: true))
        }
        #expect(rig.backend.active.filter(\.network).count == 0)
        rig.advance(0.3)
        #expect(rig.backend.active.filter(\.network).count == 2)
        #expect(rig.backend.active.filter(\.network).allSatisfy { keys.prefix(5).contains($0.key) })
        #expect(rig.pipeline.metrics.peakLocal <= 4)
        #expect(rig.pipeline.metrics.peakNetwork <= 2)
    }

    @Test func degradedLocalDeliveryDoesNotStartADuplicateCloudRequest() {
        let rig = Rig()
        let image = makeImage()
        let item = rig.pipeline.thumbnail(for: key(0))
        rig.pipeline.update([key(0): 0], moving: false)
        let local = rig.backend.requests[0]
        rig.backend.deliver(local, .init(image: image, isFinal: false, needsNetwork: true))
        rig.advance(0.4)
        #expect(rig.backend.requests.count == 1)
        #expect(item.image === image)
        rig.backend.deliver(local, .init(needsNetwork: true))
        #expect(rig.backend.requests.count == 2)
        #expect(rig.backend.requests[1].network)
        #expect(rig.pipeline.activeRequestCount == 1)
    }

    @Test func localTimeoutCannotStarveNewFocusAndDoesNotFalselyDeclareICloud() {
        let rig = Rig()
        let item = rig.pipeline.thumbnail(for: key(0))
        rig.pipeline.update([key(0): 0, key(1): 1, key(2): 2, key(3): 2, key(4): 2], moving: false)
        let waiting = (0...4).map(key).first { key in !rig.backend.requests.contains { $0.key == key } }!
        rig.advance(2.1)
        #expect(rig.pipeline.metrics.timeouts == 4)
        #expect(rig.backend.active.contains { $0.key == key(0) && $0.network })
        #expect(item.status != .cloud)
        #expect(rig.backend.active.contains { $0.key == waiting && !$0.network })
    }

    @Test func fastScrollingDefersCloudButNeverLocalAndSettledFocusPreemptsOneSlowImage() {
        let rig = Rig()
        rig.backend.onRequest = { request, backend in
            if !request.network { backend.deliver(request, .init(needsNetwork: true)) }
        }
        rig.pipeline.update([key(0): 1, key(1): 1, key(2): 1], moving: true)
        rig.advance(1)
        #expect(rig.pipeline.metrics.localRequests == 3 && rig.pipeline.metrics.networkRequests == 0)
        rig.pipeline.update([key(0): 1, key(1): 1, key(2): 1], moving: false)
        rig.advance(0.3)
        #expect(rig.backend.active.count == 2)
        let next = [key(0), key(1), key(2)].first { key in !rig.backend.active.contains { $0.key == key } }!
        rig.pipeline.update([key(0): next == key(0) ? 0 : 1, key(1): next == key(1) ? 0 : 1, key(2): next == key(2) ? 0 : 1], moving: false)
        rig.advance(0.3)
        #expect(rig.backend.active.contains { $0.key == next && $0.network })
        #expect(rig.pipeline.metrics.cancellations == 1)
        #expect(rig.pipeline.metrics.peakNetwork == 2)
    }

    @Test func finishedThumbnailSurvivesAReversalWithoutAnotherRequest() {
        let rig = Rig()
        let expected = makeImage()
        rig.backend.onRequest = { request, backend in backend.deliver(request, .init(image: expected)) }
        let original = rig.pipeline.thumbnail(for: key(0))
        rig.pipeline.update([key(0): 0], moving: false)
        #expect(original.image === expected)
        #expect(rig.pipeline.activeRequestCount == 0, "Synchronous completion cannot leave a phantom handle")
        rig.pipeline.update([key(1): 0], moving: false)
        rig.pipeline.update([key(0): 0], moving: false)
        #expect(rig.pipeline.thumbnail(for: key(0)) === original)
        #expect(rig.backend.requests.count == 2)
        #expect(rig.pipeline.metrics.cacheHits == 1)
    }

    @Test func cancellationEditAndPermissionLossRejectLateImagesAndReleaseReferences() {
        let rig = Rig()
        let item = rig.pipeline.thumbnail(for: key(0))
        rig.pipeline.update([key(0): 0], moving: false)
        let stale = rig.backend.requests[0]
        rig.pipeline.invalidate([key(0).assetID])
        rig.backend.deliver(stale, .init(image: makeImage()))
        #expect(item.image == nil)
        let current = rig.backend.requests.last!
        rig.backend.deliver(current, .init(image: makeImage()))
        #expect(item.image != nil)
        rig.pipeline.invalidate(nil)
        #expect(item.image == nil && rig.pipeline.accountedBytes == 0)
        rig.backend.deliver(current, .init(image: makeImage()))
        #expect(item.image == nil)
    }

    @Test func visibleEditedCoverKeepsPixelsUntilReplacementAndDisappearsOnRemoval() {
        let rig = Rig()
        let asset = key(0)
        let item = rig.pipeline.thumbnail(for: asset)
        rig.pipeline.update([asset: 1], moving: false)
        let first = makeImage(width: 96)
        rig.backend.deliver(rig.backend.requests[0], .init(image: first))
        rig.pipeline.invalidate([asset.assetID])
        #expect(item.image === first)
        let replacement = makeImage(width: 64)
        rig.backend.deliver(rig.backend.requests.last!, .init(image: replacement))
        #expect(item.image === replacement)
        rig.pipeline.invalidate([asset.assetID], removed: [asset.assetID])
        #expect(item.image == nil)
    }

    @Test func failedCloudPreservesPreviewAndRetryBudgetIsFinite() {
        let rig = Rig()
        let item = rig.pipeline.thumbnail(for: key(0))
        let preview = makeImage()
        rig.pipeline.update([key(0): 0], moving: false)
        let local = rig.backend.requests[0]
        rig.backend.deliver(local, .init(image: preview, isFinal: false))
        rig.backend.deliver(local, .init(needsNetwork: true))
        rig.advance(0.3)
        rig.backend.deliver(rig.backend.requests.last!, .init(failed: true))
        #expect(item.image === preview && item.status == .unavailable)
        rig.advance(59)
        #expect(rig.pipeline.metrics.networkRequests == 1)
        rig.advance(2)
        #expect(rig.pipeline.metrics.networkRequests == 2)
        rig.backend.deliver(rig.backend.requests.last!, .init(failed: true))
        rig.advance(1_000)
        #expect(rig.pipeline.metrics.networkRequests == 2)
        #expect(item.image === preview)
    }

    @Test func missingAssetIsNotRetriedAsCloudAndDoesNotUseAnotherPicture() {
        let rig = Rig()
        rig.pipeline.update([key(0): 0], moving: false)
        rig.backend.deliver(rig.backend.requests[0], .init(assetUnavailable: true))
        rig.advance(100)
        #expect(rig.backend.requests.count == 1)
        #expect(rig.pipeline.thumbnail(for: key(0)).image == nil)
        #expect(rig.pipeline.thumbnail(for: key(0)).status == .unavailable)
    }

    @Test func imageMemoryAndCacheCountStayBoundedAcrossHundredsOfRows() {
        var configuration = OverviewThumbnailPipeline.Configuration()
        configuration.cacheLimit = 12
        configuration.memoryLimit = 8 * 1_024 * 1_024
        let rig = Rig(configuration: configuration)
        rig.backend.onRequest = { request, backend in backend.deliver(request, .init(image: makeImage(width: 320))) }
        for row in 0..<200 {
            rig.pipeline.update(Dictionary(uniqueKeysWithValues: (row * 5..<row * 5 + 5).map { (key($0), 1) }), moving: false)
            #expect(rig.pipeline.accountedBytes <= configuration.memoryLimit)
            #expect(rig.pipeline.retainedImageCount <= 12)
        }
        rig.pipeline.update([:], moving: false)
        rig.pipeline.memoryWarning()
        #expect(rig.pipeline.retainedImageCount == 0)
        #expect(rig.pipeline.metrics.peakAccountedBytes <= configuration.memoryLimit)
    }

    @Test func returningToPageTopReusesDockArtworkAcrossShelfExpansion() {
        var configuration = OverviewThumbnailPipeline.Configuration()
        configuration.cacheLimit = 2
        let rig = Rig(configuration: configuration)
        rig.backend.onRequest = { request, backend in backend.deliver(request, .init(image: makeImage())) }
        let dock = OverviewImageKey(assetID: "recent", size: .dock, usesOriginal: true)
        rig.pipeline.update([dock: 1], moving: false)
        let original = rig.pipeline.thumbnail(for: dock).image
        for index in 0..<6 { rig.pipeline.update([key(index): 1], moving: false) }
        #expect(rig.pipeline.retainedImageCount == 2)
        rig.pipeline.update([dock: 1], moving: false)
        #expect(original != nil)
        #expect(rig.pipeline.thumbnail(for: dock).image === original)
        #expect(rig.backend.requests.filter { $0.key == dock }.count == 1)
    }

    @Test func oversizedDeliveryIsNotKeptAndRetriesAtSmallerSize() {
        let rig = Rig()
        rig.pipeline.update([key(0): 0], moving: false)
        let first = rig.backend.requests[0]
        rig.backend.deliver(first, .init(image: makeImage(width: 2_000)))
        #expect(rig.pipeline.thumbnail(for: key(0)).image == nil)
        #expect(rig.backend.requests.count == 2)
        #expect(rig.backend.requests.last?.reduced == true)
        #expect(rig.pipeline.accountedBytes <= 48 * 1_024 * 1_024)
    }

    private func key(_ number: Int) -> OverviewImageKey { Self.key(number) }
    private static func key(_ number: Int) -> OverviewImageKey { .init(assetID: "fixture-\(number)", size: .card) }
    private static func makeImage(width: CGFloat = 64) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        }
    }
    private func makeImage(width: CGFloat = 64) -> UIImage { Self.makeImage(width: width) }

    @MainActor private final class DeliveryRecorder {
        var cancelledDeliveries = 0
        var finalImage: UIImage?
    }

    @MainActor private final class Rig {
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        let backend = OverviewTestRequester()
        let configuration: OverviewThumbnailPipeline.Configuration
        lazy var pipeline = OverviewThumbnailPipeline(requester: backend, configuration: configuration,
                                                       now: { [unowned self] in self.date }, automaticScheduling: false)
        init(configuration: OverviewThumbnailPipeline.Configuration = .init()) { self.configuration = configuration }
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds); pipeline.tick() }
    }
}

@MainActor final class OverviewTestRequester: OverviewImageRequesting {
    struct Request {
        let key: OverviewImageKey
        let network: Bool
        let reduced: Bool
        let token: UUID
        let completion: @MainActor @Sendable (OverviewImageDelivery) -> Void
    }
    var requests: [Request] = []
    var ended: Set<UUID> = []
    var cancelled: Set<UUID> = []
    var onRequest: ((Request, OverviewTestRequester) -> Void)?
    var active: [Request] { requests.filter { !ended.contains($0.token) && !cancelled.contains($0.token) } }
    func prepare(_ keys: [OverviewImageKey], preheat: [OverviewImageKey]) {}
    func request(_ key: OverviewImageKey, network: Bool, reduced: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        let request = Request(key: key, network: network, reduced: reduced, token: token, completion: completion)
        requests.append(request); onRequest?(request, self)
    }
    func cancel(_ token: UUID) { cancelled.insert(token) }
    func invalidate(_ ids: Set<String>?) {}
    func deliver(_ request: Request, _ delivery: OverviewImageDelivery) {
        if delivery.isFinal { ended.insert(request.token) }
        request.completion(delivery)
    }
}
