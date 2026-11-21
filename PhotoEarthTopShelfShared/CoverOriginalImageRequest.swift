import ImageIO
import Photos
import UIKit

/// Reads the largest Photos rendition and releases the encoded bytes after
/// decoding a bounded image for the card.
@MainActor final class CoverOriginalImageRequest {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var timer: Task<Void, Never>?

    func image(for asset: PHAsset, longEdge: Int, network: Bool, deadline: ContinuousClock.Instant) async -> UIImage? {
        guard !Task.isCancelled, .now < deadline else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let options = PHImageRequestOptions()
                options.version = .current
                options.isNetworkAccessAllowed = network
                requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                    [weak self] data, _, orientation, _ in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        guard let data else { self.finish(nil); return }
                        let image = await Self.decode(data, orientation: orientation, longEdge: longEdge)
                        self.finish(image)
                    }
                }
                timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    @concurrent static func decode(_ data: Data, orientation: CGImagePropertyOrientation, longEdge: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdge
              ] as CFDictionary) else { return nil }
        let direction: UIImage.Orientation = switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
        return UIImage(cgImage: image, scale: 1, orientation: direction)
    }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        PHImageManager.default().cancelImageRequest(requestID)
        continuation.resume(returning: image)
    }
}
