import Combine
import Photos
import UIKit

@MainActor
final class MemoryThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]

    private let manager = PHCachingImageManager()
    private var requestIDs: [PHImageRequestID] = []
    private var cachedAssets: [PHAsset] = []
    private var cachedTargetSize = CGSize.zero
    private var cachedOptions: PHImageRequestOptions?
    private var generation = UUID()
    private var recentAssetIDs: [String] = []

    func load(records: [PhotoAssetRecord], targetSize: CGSize) {
        generation = UUID()
        cancelRequestsAndCaching()
        let assetIDs = records.map(\.id).filter { !$0.hasPrefix("sample-") }
        guard !assetIDs.isEmpty else { return }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        let assets = assetIDs.compactMap { assetsByID[$0] }
        guard !assets.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        cachedAssets = assets
        cachedTargetSize = targetSize
        cachedOptions = options
        manager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )

        let requestGeneration = UUID()
        generation = requestGeneration
        for assetID in assetIDs {
            guard let asset = assetsByID[assetID] else { continue }
            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                guard let image else { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let error = info?[PHImageErrorKey] as? Error
                guard !cancelled, error == nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, generation == requestGeneration else { return }
                    images[assetID] = image
                    remember(assetID)
                }
            }
            requestIDs.append(requestID)
        }
    }

    func cancel() {
        generation = UUID()
        cancelRequestsAndCaching()
    }

    private func cancelRequestsAndCaching() {
        requestIDs.forEach(manager.cancelImageRequest)
        requestIDs.removeAll()
        if let cachedOptions, !cachedAssets.isEmpty {
            manager.stopCachingImages(
                for: cachedAssets,
                targetSize: cachedTargetSize,
                contentMode: .aspectFill,
                options: cachedOptions
            )
        }
        cachedAssets.removeAll()
        cachedOptions = nil
    }

    private func remember(_ assetID: String) {
        recentAssetIDs.removeAll { $0 == assetID }
        recentAssetIDs.append(assetID)
        while recentAssetIDs.count > 72 {
            let expired = recentAssetIDs.removeFirst()
            images.removeValue(forKey: expired)
        }
    }

    deinit {
        requestIDs.forEach(manager.cancelImageRequest)
    }
}
