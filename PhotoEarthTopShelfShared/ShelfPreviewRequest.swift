import CoreImage
import Photos
import UIKit

@MainActor enum CoverWaitingArtwork {
    static let image: UIImage = {
        let size = CGSize(width: 180, height: 270)
        let bounds = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.33, green: 0.40, blue: 0.47, alpha: 1).setFill()
            context.fill(bounds)
            UIColor(red: 0.69, green: 0.77, blue: 0.79, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: -66, y: -24, width: 228, height: 172))
            UIColor(red: 0.49, green: 0.52, blue: 0.62, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 58, y: 128, width: 180, height: 166))
        }
        guard let input = base.cgImage else { return base }
        let blurred = CIImage(cgImage: input).clampedToExtent().applyingGaussianBlur(sigma: 26)
        return CIContext().createCGImage(blurred, from: bounds).map { UIImage(cgImage: $0) } ?? base
    }()
}

@MainActor final class ShelfPreviewRequest {
    static func blurredPosterURL() -> URL? {
        CoverWaitingArtwork.image.jpegData(compressionQuality: 0.85).flatMap(JourneyShelfImageURL.make(jpeg:))
    }

    private var continuation: CheckedContinuation<Data?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var timer: Task<Void, Never>?

    func jpegFromOriginal(asset: PHAsset, network: Bool, deadline: ContinuousClock.Instant) async -> Data? {
        guard asset.mediaType == .image else { return await jpeg(asset: asset, network: network, deadline: deadline) }
        let requestDeadline = min(deadline, .now.advanced(by: network ? .seconds(6) : .milliseconds(250)))
        guard let image = await CoverOriginalImageRequest().image(for: asset, longEdge: 960, network: network,
                                                                 deadline: requestDeadline),
              !Task.isCancelled, .now < deadline else { return nil }
        return Self.render(image)
    }

    func jpeg(asset: PHAsset, network: Bool, deadline: ContinuousClock.Instant) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = network
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                // Two screen scales share a single bounded, metadata-free render.
                let size = CGSize(width: 768, height: 768)
                requestID = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] image, info in
                    guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        guard let image, image.size.width > 0, image.size.height > 0 else { self.finish(nil); return }
                        self.finish(Self.render(image))
                    }
                }
                timer = Task {
                    try? await Task.sleep(until: min(deadline, .now.advanced(by: .milliseconds(network ? 1_150 : 300))), clock: .continuous)
                    if !Task.isCancelled { finish(nil) }
                }
            }
        } onCancel: { Task { @MainActor in self.finish(nil) } }
    }

    private static func render(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let source = JourneyShelfPosterCrop.sourceRect(in: image.size)
        for (width, quality) in [(480.0, 0.75), (360.0, 0.65), (256.0, 0.5)] {
            let size = CGSize(width: width, height: width / JourneyShelfPosterCrop.aspectRatio)
            let ratio = size.width / source.width
            let rect = CGRect(x: -source.minX * ratio, y: -source.minY * ratio,
                              width: image.size.width * ratio, height: image.size.height * ratio)
            let bytes = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: quality) { _ in image.draw(in: rect) }
            if bytes.count <= JourneyShelfImageURL.posterCacheLimit { return bytes }
        }
        return nil
    }

    private func finish(_ bytes: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        PHImageManager.default().cancelImageRequest(requestID)
        continuation.resume(returning: bytes)
    }
}
