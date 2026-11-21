import Foundation
import ImageIO
import Photos
import UIKit

/// Home keeps its visibility/dwell policy, while actual requests participate in
/// the same application-wide budget as wall, detail, classification and strip.
@MainActor final class OverviewPhotoKitRequester: OverviewImageRequesting {
    private var priorities: [UUID: PhotoImagePriority] = [:]
    private var preheating: [OverviewImageKey: UUID] = [:]
    private let scheduler: SharedPhotoImageScheduler
    init(scheduler: SharedPhotoImageScheduler? = nil) { self.scheduler = scheduler ?? .shared }
    func prepare(_ keys: [OverviewImageKey], preheat: [OverviewImageKey]) {
        let next = Set(preheat.prefix(5))
        for key in Array(preheating.keys) where !next.contains(key) {
            if let token = preheating.removeValue(forKey: key) { scheduler.cancel(token) }
        }
        for key in next where preheating[key] == nil {
            let token = UUID(); preheating[key] = token
            scheduler.request(key.requestKey(),
                              network: false, priority: .prefetch, token: token) { _ in }
        }
    }
    func setPriority(_ priority: PhotoImagePriority, token: UUID) {
        priorities[token] = priority
        scheduler.updatePriority(priority, token: token)
    }
    func request(_ key: OverviewImageKey, network: Bool, reduced: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        if let preview = scheduler.cachedPreview(for: key.assetID, maximumLongEdge: 640, fullFrameOnly: key.usesOriginal) {
            completion(.init(image: preview, isFinal: false))
        }
        scheduler.request(key.requestKey(reduced: reduced),
                          network: network, priority: priorities[token] ?? .visible, token: token) { [weak self] result in
            if result.isFinal { self?.priorities.removeValue(forKey: token) }
            completion(result)
        }
    }
    func cancel(_ token: UUID) { priorities.removeValue(forKey: token); scheduler.cancel(token) }
    func invalidate(_ ids: Set<String>?) {
        for key in Array(preheating.keys) where ids == nil || ids!.contains(key.assetID) {
            if let token = preheating.removeValue(forKey: key) { scheduler.cancel(token) }
        }
        scheduler.invalidateCache(ids)
    }
    isolated deinit { for token in preheating.values { scheduler.cancel(token) } }
}

/// Only this adapter may submit actual image/decode work to the worker actor.
@MainActor final class SharedPhotoKitRequester: SharedPhotoImageRequesting {
    private let worker = SharedPhotoKitWorker()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidation: Task<Void, Never>?

    func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        let worker = worker
        let barrier = invalidation
        tasks[token] = Task { [weak self] in
            await barrier?.value
            await worker.request(key, network: network, token: token) { [weak self] result in
                guard let self, self.tasks[token] != nil else { return }
                if result.isFinal { self.tasks.removeValue(forKey: token) }
                completion(result)
            }
        }
    }
    func cancel(_ token: UUID) {
        tasks.removeValue(forKey: token)?.cancel()
        let worker = worker
        Task { await worker.cancel(token) }
    }
    func invalidate(_ ids: Set<String>?) {
        let worker = worker
        let previous = invalidation
        invalidation = Task { await previous?.value; await worker.invalidate(ids) }
    }
}

/// PHAsset objects are immutable. This actor confines their synchronous fetch
/// and the small catalog; waiting for it does not block the image worker's cancel.
private actor OverviewAssetCatalog {
    private var assets: [String: PHAsset] = [:]

    func fetch(_ ids: [String]) -> [String: PHAsset] {
        let unique = Array(Set(ids.filter { !SamplePhotoResource.isSample($0) }).prefix(20))
        guard !Task.isCancelled, !unique.isEmpty, PhotoKitLibrary.hasReadAccess else { return [:] }
        let missing = unique.filter { assets[$0] == nil }
        if !missing.isEmpty {
            let interval = OverviewPerformance.begin("Shared asset lookup")
            let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
            result.enumerateObjects { asset, _, _ in self.assets[asset.localIdentifier] = asset }
            OverviewPerformance.end("Shared asset lookup", interval)
        }
        let output = assets.filter { unique.contains($0.key) }
        if assets.count > 40 { assets = output }
        return output
    }

    func invalidate(_ ids: Set<String>?) {
        if let ids { for id in ids { assets.removeValue(forKey: id) } }
        else { assets = [:] }
    }
}

private actor SharedPhotoKitWorker {
    private enum Pending { case asset, image(PHImageRequestID), original(Task<Void, Never>) }
    private let catalog = OverviewAssetCatalog()
    private var manager: PHCachingImageManager?
    private var pending: [UUID: Pending] = [:]
    private var contentRevision = UUID()

    func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) async {
        guard !Task.isCancelled else { return }
        pending[token] = .asset
        let revision = contentRevision
        if SamplePhotoResource.isSample(key.assetID) {
            // Public demo resources follow the same queue and budget. Deliberate
            // latency is available only in Debug UI validation, never live Photos.
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--home-slow-images") {
                do { try await Task.sleep(for: .seconds(network ? 4 : 0.08)) }
                catch { pending.removeValue(forKey: token); return }
                if !network {
                    pending.removeValue(forKey: token)
                    await completion(.init(needsNetwork: true))
                    return
                }
            }
#endif
            let image = Self.sampleImage(key)
            guard !Task.isCancelled, pending.removeValue(forKey: token) != nil, revision == contentRevision else { return }
            await completion(.init(image: image, assetUnavailable: image == nil))
            return
        }
        let values = await catalog.fetch([key.assetID])
        guard !Task.isCancelled, pending[token] != nil, revision == contentRevision else {
            pending.removeValue(forKey: token); return
        }
        guard let asset = values[key.assetID] else {
            pending.removeValue(forKey: token)
            await completion(.init(assetUnavailable: true))
            return
        }
        let isStillCover = key.usesOriginal && asset.mediaType == .image
        let requestOptions = options(network: network)
        requestOptions.version = .current
        if key.forCoverAnalysis {
            requestOptions.deliveryMode = .highQualityFormat
            requestOptions.resizeMode = .fast
        }
        if network {
            requestOptions.progressHandler = { [weak self] _, error, _, _ in
                if let error { OverviewPerformance.failure(error as NSError) }
                Task { await self?.deliver(.init(isFinal: false, needsNetwork: true), token: token, completion: completion) }
            }
        }
        let manager = self.manager ?? PHCachingImageManager()
        self.manager = manager
        let targetSize = key.forCoverAnalysis ? key.targetSize : size(for: key, asset: asset)
        let requestID = manager.requestImage(for: asset, targetSize: targetSize,
                                            contentMode: key.fillsTarget && !key.usesOriginal ? .aspectFill : .aspectFit, options: requestOptions) { [weak self] image, info in
            if let error = info?[PHImageErrorKey] as? NSError { OverviewPerformance.failure(error) }
            let failed = info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true
            let final = failed || (info?[PHImageResultIsDegradedKey] as? Bool) != true
            if key.forCoverAnalysis && !final { return }
            let preview = key.forCoverAnalysis ? image.flatMap(CoverAnalysisPreview.boundedImage) : image
            let result = OverviewImageDelivery(image: failed ? nil : preview,
                isFinal: final,
                needsNetwork: (info?[PHImageResultIsInCloudKey] as? Bool) == true, failed: failed)
            Task {
                if isStillCover {
                    await self?.deliverCover(result, for: asset, targetSize: targetSize, network: network,
                                             token: token, completion: completion)
                } else {
                    await self?.deliver(result, token: token, completion: completion)
                }
            }
        }
        // Callback work reenters the actor after this synchronous call, so the
        // request handle exists before even an immediate final result is handled.
        pending[token] = .image(requestID)
    }

    private func deliverCover(_ result: OverviewImageDelivery, for asset: PHAsset, targetSize: CGSize,
                              network: Bool, token: UUID,
                              completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) async {
        guard case .image = pending[token] else { return }
        guard result.isFinal else {
            await deliver(result, token: token, completion: completion)
            return
        }
        let requiredEdge = Int(max(targetSize.width, targetSize.height))
        let edge = result.image?.cgImage.map { max($0.width, $0.height) } ?? 0
        let action = PhotoImageSizing.coverAction(deliveredEdge: edge, requiredEdge: requiredEdge, network: network)
        if action == .display {
            await deliver(.init(image: result.image), token: token, completion: completion)
            return
        }
        if let image = result.image {
            await deliver(.init(image: image, isFinal: false), token: token, completion: completion)
        }
        guard case .image = pending[token] else { return }
        if action == .requestNetworkRendition {
            await deliver(.init(needsNetwork: true), token: token, completion: completion)
            return
        }
        // Only a visible cover whose Photos rendition was unavailable or too small
        // needs the full encoded current version. Keep the small frame on screen.
        pending[token] = .original(Task {
            let full = await CoverOriginalImageRequest().image(for: asset, longEdge: requiredEdge,
                                network: true, deadline: .now.advanced(by: .seconds(8)))
            guard !Task.isCancelled else { return }
            let image = full ?? result.image
            await deliver(.init(image: image, failed: image == nil), token: token, completion: completion)
        })
    }

    private func deliver(_ result: OverviewImageDelivery, token: UUID,
                         completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) async {
        guard pending[token] != nil else { return }
        if result.isFinal { pending.removeValue(forKey: token) }
        await completion(result)
    }

    func cancel(_ token: UUID) {
        switch pending.removeValue(forKey: token) {
        case let .image(id): manager?.cancelImageRequest(id)
        case let .original(task): task.cancel()
        case .asset, nil: break
        }
    }

    func invalidate(_ ids: Set<String>?) async {
        if ids == nil { contentRevision = UUID() }
        manager?.stopCachingImagesForAllAssets()
        await catalog.invalidate(ids)
    }

    private func options(network: Bool) -> PHImageRequestOptions {
        let value = PHImageRequestOptions()
        value.isSynchronous = false
        value.deliveryMode = .opportunistic
        value.resizeMode = .exact
        value.isNetworkAccessAllowed = network
        return value
    }

    private func size(for key: SharedPhotoImageKey, asset: PHAsset) -> CGSize {
        PhotoImageSizing.requestSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                    targetSize: key.targetSize, fillsTarget: key.fillsTarget)
    }

    private static func sampleImage(_ key: SharedPhotoImageKey) -> UIImage? {
        guard let url = SamplePhotoResource.url(for: key.assetID)
                ?? (key.assetID == "sample-reykjavik-1" ? Bundle.main.url(forResource: "SampleIceland", withExtension: "png") : nil),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = PhotoImageSizing.requestSize(pixelWidth: width, pixelHeight: height,
                                               targetSize: key.targetSize, fillsTarget: key.fillsTarget)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
