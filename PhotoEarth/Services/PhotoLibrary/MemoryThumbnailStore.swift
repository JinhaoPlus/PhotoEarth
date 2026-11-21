import Combine
import Photos
import UIKit

@MainActor
final class MemoryThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]

    private let requester = PhotoKitImageRequester()
    private var requestIDs: [PHImageRequestID] = []
    private var generation = UUID()
    private var notices: Set<AnyCancellable> = []
    private var records: [PhotoAssetRecord] = []

    init() {
        NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name).sink { [weak self] notice in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = notice.userInfo?["changed"] as? Set<String> ?? []
                let removed = notice.userInfo?["removed"] as? Set<String> ?? []
                guard self.records.contains(where: { changed.contains($0.id) || removed.contains($0.id) }) else { return }
                let current = self.records.filter { !removed.contains($0.id) }
                self.load(records: current)
            }
        }.store(in: &notices)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }.store(in: &notices)
    }

    func load(records: [PhotoAssetRecord]) {
        cancel()
        self.records = records.filter { !$0.id.hasPrefix("sample-") }
        let token = generation
        for record in self.records {
            if let cached = SharedPhotoImageScheduler.shared.cachedPreview(for: record.id, maximumLongEdge: 640) { images[record.id] = cached }
            let size = MemoryPhotoStripPaging.size(for: record)
            let targetSize = CGSize(width: size.width * 2, height: size.height * 2)
            let id = requester.requestImage(assetID: record.id, targetSize: targetSize, contentMode: .aspectFill,
                                           priority: .visible) { [weak self] result in
                guard let self, self.generation == token, let image = result.image else { return }
                self.images[record.id] = image
            }
            requestIDs.append(id)
        }
    }

    /// A new motion or hidden strip releases the complete bounded preview batch
    /// immediately; the shared LRU handles reuse when a page returns.
    func cancel() {
        generation = UUID()
        requestIDs.forEach(requester.cancelImageRequest)
        requestIDs = []; records = []; images = [:]
    }

    isolated deinit { requestIDs.forEach(requester.cancelImageRequest) }
}

/// Neighbor preparation never permits cloud traffic and never holds full-screen
/// images. Retention and cancellation use the same queue as the selected photo.
@MainActor final class PhotoNeighborPrefetcher {
    private let requester: PhotoKitImageRequester
    private var requests: [String: PHImageRequestID] = [:]
    init(scheduler: SharedPhotoImageScheduler? = nil) { requester = PhotoKitImageRequester(scheduler: scheduler) }

    func update(records: [PhotoAssetRecord]) {
        let neighbors = Array(records.prefix(2))
        let wanted = Set(neighbors.map(\.id))
        for id in Array(requests.keys) where !wanted.contains(id) {
            if let request = requests.removeValue(forKey: id) { requester.cancelImageRequest(request) }
        }
        for record in neighbors where requests[record.id] == nil {
            requests[record.id] = requester.requestImage(assetID: record.id,
                targetSize: CGSize(width: 960, height: 960), contentMode: .aspectFit, priority: .prefetch) { _ in }
        }
    }

    func cancel() {
        requests.values.forEach(requester.cancelImageRequest)
        requests = [:]
    }
    isolated deinit { requests.values.forEach(requester.cancelImageRequest) }
}
