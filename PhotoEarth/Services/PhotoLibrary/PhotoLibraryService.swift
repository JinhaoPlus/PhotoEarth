import Combine
import Foundation
import ImageIO
import Photos
import UIKit

nonisolated enum PhotoLibraryAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
}

nonisolated struct PhotoLibraryScan: Sendable {
    let sourcePhotoCount: Int
    let locatedPhotos: [PhotoAssetRecord]
}

nonisolated protocol PhotoLibraryProviding: Sendable {
    func authorizationStatus() async -> PhotoLibraryAccess
    func requestAuthorization() async -> PhotoLibraryAccess
    func scanLocatedPhotos() async throws -> PhotoLibraryScan
}

private actor ScanRecordCollector {
    var records: [PhotoAssetRecord] = []
    func append(_ batch: [PhotoAssetRecord]) { records += batch }
}

final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {
    nonisolated static var hasReadAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    nonisolated let scanLedger = TravelScanLedger()
    let changeObserver = PhotoLibraryChangeRelay()
    func authorizationStatus() async -> PhotoLibraryAccess {
        Self.access(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAccess {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.access(from: status))
            }
        }
    }

    func scanLocatedPhotos() async throws -> PhotoLibraryScan {
        _ = try await prepareScope()
        let collected = ScanRecordCollector()
        let total = try await enumeratePhotos { await collected.append($0.records) }
        return await PhotoLibraryScan(sourcePhotoCount: total, locatedPhotos: collected.records)

    }

    private static func access(from status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}

nonisolated struct PhotoImageDelivery: Sendable {
    let image: UIImage?
    let isFinal: Bool
    var failed = false
}

@MainActor
protocol PhotoImageRequesting {
    func requestImage(_ key: SharedPhotoImageKey, priority: PhotoImagePriority,
                      completion: @escaping @MainActor (PhotoImageDelivery) -> Void) -> PHImageRequestID
    func updatePriority(_ priority: PhotoImagePriority, for requestID: PHImageRequestID)
    func cancelImageRequest(_ requestID: PHImageRequestID)
}

extension PhotoImageRequesting {
    func requestImage(assetID: String, targetSize: CGSize, contentMode: PHImageContentMode,
                      priority: PhotoImagePriority = .visible,
                      completion: @escaping @MainActor (PhotoImageDelivery) -> Void) -> PHImageRequestID {
        requestImage(.init(assetID: assetID, targetSize: targetSize, fillsTarget: contentMode == .aspectFill),
                     priority: priority, completion: completion)
    }
}

/// A logical image request tries local data first, then upgrades through the
/// shared cloud queue. UI code never synchronously fetches a PHAsset.
@MainActor final class PhotoKitImageRequester: PhotoImageRequesting {
    private final class Request {
        enum Stage {
            case local(UUID), network(UUID), waitsForVisibility

            var token: UUID? {
                switch self {
                case .local(let token), .network(let token): token
                case .waitsForVisibility: nil
                }
            }
        }

        let key: SharedPhotoImageKey
        var priority: PhotoImagePriority
        let completion: @MainActor (PhotoImageDelivery) -> Void
        var stage = Stage.waitsForVisibility
        init(key: SharedPhotoImageKey, priority: PhotoImagePriority,
             completion: @escaping @MainActor (PhotoImageDelivery) -> Void) {
            self.key = key; self.priority = priority; self.completion = completion
        }
    }
    private let scheduler: SharedPhotoImageScheduler
    private var requests: [PHImageRequestID: Request] = [:]
    private var nextID: PHImageRequestID = -2

    init(scheduler: SharedPhotoImageScheduler? = nil) { self.scheduler = scheduler ?? .shared }

    func requestImage(_ key: SharedPhotoImageKey, priority: PhotoImagePriority,
                      completion: @escaping @MainActor (PhotoImageDelivery) -> Void) -> PHImageRequestID {
        let id = nextID
        nextID = nextID == .min ? -2 : nextID - 1
        let request = Request(key: key, priority: priority, completion: completion)
        requests[id] = request
        start(id, network: false)
        return id
    }

    private func start(_ id: PHImageRequestID, network: Bool) {
        guard let request = requests[id] else { return }
        let token = UUID()
        request.stage = network ? .network(token) : .local(token)
        scheduler.request(request.key, network: network, priority: request.priority, token: token) { [weak self] result in
            guard let self, let current = self.requests[id], current.stage.token == token else { return }
            if !result.isFinal {
                current.completion(.init(image: result.image, isFinal: false))
            } else if result.assetUnavailable || (result.image != nil && !result.failed) || network {
                self.requests.removeValue(forKey: id)
                current.completion(.init(image: result.image, isFinal: true,
                                         failed: result.failed || result.assetUnavailable || result.image == nil))
            } else if current.priority == .prefetch {
                current.stage = .waitsForVisibility
                current.completion(.init(image: nil, isFinal: true, failed: true))
            } else {
                // Cloud access is permitted only once local completion or its
                // bounded timeout has released the original native request.
                self.start(id, network: true)
            }
        }
    }

    func updatePriority(_ priority: PhotoImagePriority, for requestID: PHImageRequestID) {
        guard let request = requests[requestID], request.priority != priority else { return }
        request.priority = priority
        switch request.stage {
        case .waitsForVisibility:
            guard priority != .prefetch else { return }
            request.completion(.init(image: nil, isFinal: false))
            start(requestID, network: true)
        case .network(let token) where priority == .prefetch:
            request.stage = .waitsForVisibility
            scheduler.cancel(token)
            request.completion(.init(image: nil, isFinal: true, failed: true))
        case .local(let token), .network(let token):
            scheduler.updatePriority(priority, token: token)
        }
    }

    func cancelImageRequest(_ requestID: PHImageRequestID) {
        if let token = requests.removeValue(forKey: requestID)?.stage.token {
            scheduler.cancel(token)
        }
    }

    isolated deinit {
        for request in requests.values {
            if let token = request.stage.token { scheduler.cancel(token) }
        }
    }
}

@MainActor
final class PhotoImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false
    @Published private(set) var hasFailed = false

    private let requester: any PhotoImageRequesting
    private var requestID: PHImageRequestID?
    private var loadToken = UUID()
    private(set) var loadedAssetID: String?

    init(requester: (any PhotoImageRequesting)? = nil) {
        self.requester = requester ?? PhotoKitImageRequester()
    }

    func load(assetID: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill,
              initialImage: UIImage? = nil, priority: PhotoImagePriority = .visible, usesOriginal: Bool = false) {
        let key = SharedPhotoImageKey(assetID: assetID, targetSize: targetSize, fillsTarget: contentMode == .aspectFill,
                                      usesOriginal: usesOriginal)
        let preview = initialImage ?? (loadedAssetID == assetID ? image : nil)
            ?? SharedPhotoImageScheduler.shared.cachedPreview(for: assetID, maximumLongEdge: min(key.longEdge, 1_600), fullFrameOnly: usesOriginal)
        cancel()
        loadedAssetID = assetID
        image = preview
        isLoading = true
        let token = UUID()
        loadToken = token
        requestID = requester.requestImage(key, priority: priority) { [weak self] delivery in
            guard let self, self.loadToken == token else { return }
            if let deliveredImage = delivery.image {
                // Opportunistic thumbnails must not replace a larger wall preview.
                let currentPixels = self.image.map { $0.size.width * $0.size.height * $0.scale * $0.scale } ?? 0
                let deliveredPixels = deliveredImage.size.width * deliveredImage.size.height * deliveredImage.scale * deliveredImage.scale
                if delivery.isFinal || deliveredPixels >= currentPixels { self.image = deliveredImage }
            }
            if delivery.isFinal || delivery.failed {
                self.isLoading = false
                self.hasFailed = delivery.failed || delivery.image == nil
            } else {
                if !self.isLoading { self.isLoading = true }
                if self.hasFailed { self.hasFailed = false }
            }
        }
    }

    func updatePriority(_ priority: PhotoImagePriority) {
        guard let requestID else { return }
        requester.updatePriority(priority, for: requestID)
    }

    /// A reused SwiftUI image must not expose another photo's failed state
    /// while its own request is still being installed.
    func shouldOfferRetry(for assetID: String) -> Bool {
        loadedAssetID == assetID && hasFailed && !isLoading
    }

    /// Stop work that no longer has a visible consumer without tearing the
    /// already-rendered frame out of an outgoing SwiftUI scroll transition.
    func suspend() {
        loadToken = UUID()
        if let requestID { requester.cancelImageRequest(requestID) }
        requestID = nil
        isLoading = false
        hasFailed = false
    }

    func cancel() {
        suspend()
        image = nil
        loadedAssetID = nil
    }

    isolated deinit {
        if let requestID { requester.cancelImageRequest(requestID) }
    }
}
