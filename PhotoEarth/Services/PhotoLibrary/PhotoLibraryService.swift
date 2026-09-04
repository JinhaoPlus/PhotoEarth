import Combine
import Foundation
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

final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {
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
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            var records: [PhotoAssetRecord] = []
            records.reserveCapacity(assets.count)

            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                guard let location = asset.location, let creationDate = asset.creationDate else { return }
                let coordinate = GeoCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                guard coordinate.isValid else { return }
                records.append(
                    PhotoAssetRecord(
                        id: asset.localIdentifier,
                        coordinate: coordinate,
                        creationDate: creationDate,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        isFavorite: asset.isFavorite
                    )
                )
            }
            try Task.checkCancellation()
            return PhotoLibraryScan(sourcePhotoCount: assets.count, locatedPhotos: records)
        }.value
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

@MainActor
final class PhotoImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private var requestID: PHImageRequestID?
    private var loadToken = UUID()

    func load(assetID: String, targetSize: CGSize) {
        cancel()
        guard !assetID.hasPrefix("sample-") else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else { return }

        image = nil
        isLoading = true
        let token = UUID()
        loadToken = token
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let self else { return }
            guard self.loadToken == token else { return }
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            if cancelled || error != nil {
                self.isLoading = false
                return
            }
            if let image { self.image = image }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            if !degraded { self.isLoading = false }
        }
    }

    func cancel() {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        loadToken = UUID()
        requestID = nil
        isLoading = false
    }

    deinit {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
    }
}
