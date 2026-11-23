import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UIKit
import Vision

private nonisolated final class SendableCGImage: @unchecked Sendable {
    let value: CGImage
    init(_ value: CGImage) { self.value = value }
}

private nonisolated final class SendableFeaturePrint: @unchecked Sendable {
    let value: VNFeaturePrintObservation
    init(_ value: VNFeaturePrintObservation) { self.value = value }
}

private nonisolated struct SendableAestheticsScore: Sendable {
    let overallScore: Float
    let isUtility: Bool
}

private nonisolated struct SendableVisionAnalysis: Sendable {
    let feature: SendableFeaturePrint
    let aesthetics: SendableAestheticsScore?
}

private actor VisionFeaturePrintEngine {
    func analysis(for image: SendableCGImage, featureRevision: Int) throws -> SendableVisionAnalysis {
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.revision = featureRevision
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        aestheticsRequest.revision = VNCalculateImageAestheticsScoresRequestRevision1
        let handler = VNImageRequestHandler(cgImage: image.value, orientation: .up)
        do {
            try handler.perform([featureRequest, aestheticsRequest])
        } catch {
            // Aesthetics is an optional quality signal. A device that cannot
            // run it must still retain Feature Print duplicate detection.
            let fallbackRequest = VNGenerateImageFeaturePrintRequest()
            fallbackRequest.revision = featureRevision
            let fallbackHandler = VNImageRequestHandler(cgImage: image.value, orientation: .up)
            try fallbackHandler.perform([fallbackRequest])
            guard let feature = fallbackRequest.results?.first as? VNFeaturePrintObservation else {
                throw EarthSlideshowPlanError.unavailable
            }
            return SendableVisionAnalysis(feature: SendableFeaturePrint(feature), aesthetics: nil)
        }
        guard let feature = featureRequest.results?.first as? VNFeaturePrintObservation else {
            throw EarthSlideshowPlanError.unavailable
        }
        let aesthetics = aestheticsRequest.results?.first.map {
            SendableAestheticsScore(overallScore: $0.overallScore, isUtility: $0.isUtility)
        }
        return SendableVisionAnalysis(
            feature: SendableFeaturePrint(feature),
            aesthetics: aesthetics
        )
    }

    func distance(_ lhs: SendableFeaturePrint, _ rhs: SendableFeaturePrint) throws -> Float {
        var distance: Float = 0
        try lhs.value.computeDistance(&distance, to: rhs.value)
        return distance
    }
}

@MainActor
private final class SlideshowThumbnailRequest {
    private let requester: any PhotoImageRequesting
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var bestImage: UIImage?
    private var finished = false
    private var timeout: Task<Void, Never>?

    init(requester: any PhotoImageRequesting) {
        self.requester = requester
    }

    func value(assetID: String, longEdge: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard !finished else { continuation.resume(returning: bestImage); return }
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.cancel()
            }
            requestID = requester.requestImage(
                assetID: assetID,
                targetSize: CGSize(width: longEdge, height: longEdge),
                contentMode: .aspectFit,
                priority: .visible
            ) { [weak self] delivery in
                guard let self, !self.finished else { return }
                if let image = delivery.image { self.bestImage = image }
                if delivery.isFinal || delivery.failed { self.finish(self.bestImage) }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        if let requestID { requester.cancelImageRequest(requestID) }
        finish(bestImage)
    }

    private func finish(_ image: UIImage?) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        requestID = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: image)
    }
}

@MainActor
protocol SlideshowThumbnailProviding: AnyObject {
    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage?
}

@MainActor
final class SharedSlideshowThumbnailProvider: SlideshowThumbnailProviding {
    private let requester: any PhotoImageRequesting

    init(requester: (any PhotoImageRequesting)? = nil) {
        self.requester = requester ?? PhotoKitImageRequester()
    }

    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? {
        if let url = SamplePhotoResource.url(for: record.id),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: longEdge,
               kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            return UIImage(cgImage: preview)
        }
        if let cached = SharedPhotoImageScheduler.shared.cachedPreview(for: record.id, fullFrameOnly: true),
           let frame = cached.cgImage, max(frame.width, frame.height) >= longEdge / 2 {
            return cached
        }
        let request = SlideshowThumbnailRequest(requester: requester)
        return await withTaskCancellationHandler {
            await request.value(assetID: record.id, longEdge: longEdge)
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }
}

@MainActor
final class PhotoSimilarityAnalyzer {
    private struct Representative {
        var record: PhotoAssetRecord
        var feature: SendableFeaturePrint?
        var exactFrameFingerprint: UInt64?
        var signature: FrameSignature?
        var aesthetics: SendableAestheticsScore?
        var sharpness: Double?
    }

    private let configuration: PhotoSimilarityConfiguration
    private let thumbnailProvider: any SlideshowThumbnailProviding
    private let vision = VisionFeaturePrintEngine()

    init(
        configuration: PhotoSimilarityConfiguration = .standard,
        thumbnailProvider: (any SlideshowThumbnailProviding)? = nil
    ) {
        self.configuration = configuration
        self.thumbnailProvider = thumbnailProvider ?? SharedSlideshowThumbnailProvider()
    }

    private struct FrameSignature {
        let hash: UInt64
        let pixels: [UInt8]
        var bands: [UInt32] {
            (0..<4).map { UInt32($0) << 16 | UInt32((hash >> ($0 * 16)) & 0xffff) }
        }
        init?(_ image: CGImage) {
            var pixels = [UInt8](repeating: 0, count: 9 * 8 * 4)
            guard pixels.withUnsafeMutableBytes({ buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8,
                    bitsPerComponent: 8, bytesPerRow: 36, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
                return true
            }) else { return nil }
            var bits: UInt64 = 0
            for i in 0..<64 {
                let offset = (i / 8 * 9 + i % 8) * 4
                if Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                    > Int(pixels[offset+4]) + Int(pixels[offset+5]) + Int(pixels[offset+6]) {
                    bits |= UInt64(1) << i
                }
            }
            hash = bits
            self.pixels = pixels
        }
        func matches(_ other: Self) -> Bool {
            guard (hash ^ other.hash).nonzeroBitCount <= 3 else { return false }
            var delta = 0
            for i in pixels.indices where i % 4 != 3 {
                delta += abs(Int(pixels[i]) - Int(other.pixels[i]))
                if delta > 9 * 8 * 3 * 3 { return false }
            }
            return true
        }
    }
    private var exactFrames = Set<UInt64>()
    private var signatures: [FrameSignature] = []
    private var bands: [UInt32: [Int]] = [:]
    private var recent: [Representative] = []

    func reset() {
        exactFrames.removeAll()
        signatures.removeAll()
        bands.removeAll()
        recent.removeAll()
    }

    struct Selection {
        let records: [PhotoAssetRecord]
        fileprivate let remember: @MainActor (Set<String>) -> Void

        @MainActor func commit(keeping accepted: [PhotoAssetRecord]? = nil) {
            remember(Set((accepted ?? records).map(\.id)))
        }
    }

    /// A page is selected atomically. Completed pages keep compact visual
    /// signatures for the whole show and only a small window of Vision data.
    func selectPage(_ candidates: [PhotoAssetRecord], longEdge: Int, prepareOpening: Bool = false,
                    progress: (Int) -> Void = { _ in }) async throws -> Selection {
        // Start the opening requests together under the shared PhotoKit budget.
        // Consume their results in candidate order to keep selection deterministic.
        let openingImages: [UIImage?]
        if prepareOpening && candidates.count <= 3 {
            async let first = preview(at: 0, in: candidates, longEdge: longEdge)
            async let second = preview(at: 1, in: candidates, longEdge: longEdge)
            async let third = preview(at: 2, in: candidates, longEdge: longEdge)
            openingImages = await [first, second, third]
        } else {
            openingImages = []
        }
        var batch: [Representative] = []
        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            let image = openingImages.isEmpty ? await thumbnailProvider.image(for: record, longEdge: longEdge) : openingImages[index]
            try Task.checkCancellation()
            let frame = image.flatMap(Self.normalizedCGImage)
            let exact = frame.flatMap(Self.exactFrameFingerprint)
            let signature = frame.flatMap(FrameSignature.init)
            progress(index + 1)
            if record.mediaKind != .video {
                if let exact, exactFrames.contains(exact) { continue }
                if let signature, signature.bands.contains(where: { band in
                    bands[band, default: []].suffix(24).contains { signatures[$0].matches(signature) }
                }) { continue }
            }
            var analysis: SendableVisionAnalysis?
            if let frame {
                analysis = try? await vision.analysis(for: SendableCGImage(frame), featureRevision: configuration.visionRevision)
            }
            try Task.checkCancellation()
            let candidate = Representative(record: record, feature: analysis?.feature,
                exactFrameFingerprint: exact, signature: signature, aesthetics: analysis?.aesthetics,
                sharpness: image?.cgImage.flatMap(Self.sharpness))
            if try await duplicateIndex(for: candidate, among: recent) != nil { continue }
            if let duplicate = try await duplicateIndex(for: candidate, among: batch) {
                if prefers(candidate, over: batch[duplicate]) {
                    batch[duplicate] = candidate
                }
            } else {
                batch.append(candidate)
            }
        }
        try Task.checkCancellation()
        // Ranking chooses the representative of a similar burst. Keep distinct
        // memories, including movies and favorites, on their original timeline.
        batch.sort { SlideshowOrdering.recordComesFirst($0.record, $1.record) }
        return Selection(records: batch.map(\.record)) { [weak self, batch] accepted in
            self?.remember(batch.filter { accepted.contains($0.record.id) })
        }
    }

    private func preview(at index: Int, in candidates: [PhotoAssetRecord], longEdge: Int) async -> UIImage? {
        guard candidates.indices.contains(index), !Task.isCancelled else { return nil }
        return await thumbnailProvider.image(for: candidates[index], longEdge: longEdge)
    }

    private func remember(_ batch: [Representative]) {
        for rep in batch where rep.record.mediaKind != .video {
            if let exact = rep.exactFrameFingerprint { exactFrames.insert(exact) }
            if let sig = rep.signature {
                for band in sig.bands {
                    bands[band, default: []].append(signatures.count)
                }
                signatures.append(sig)
            }
        }
        recent = Array((recent + batch).suffix(24))
    }

    private func duplicateIndex(
        for candidate: Representative,
        among representatives: [Representative]
    ) async throws -> Int? {
        let record = candidate.record
        for (index, representative) in representatives.enumerated() {
            try Task.checkCancellation()
            if record.mediaKind == .video || representative.record.mediaKind == .video {
                // Poster equality alone cannot establish that two movies
                // contain the same action.
                guard record.mediaKind == representative.record.mediaKind,
                      abs(record.duration - representative.record.duration) < 0.1,
                      conservativeMetadataDuplicate(record, representative.record) else { continue }
            }
            if let exactFrameFingerprint = candidate.exactFrameFingerprint,
               exactFrameFingerprint == representative.exactFrameFingerprint {
                return index
            }
            if let a = candidate.signature, let b = representative.signature, a.matches(b) {
                return index
            }
            if let feature = candidate.feature, let existing = representative.feature,
               let distance = try? await vision.distance(feature, existing) {
                if distance <= configuration.nearDuplicateDistance { return index }
                if distance <= configuration.relatedSceneDistance,
                   belongsToSameVisitAndMoment(record, representative.record) { return index }
            } else if candidate.signature == nil, representative.signature == nil,
                      conservativeMetadataDuplicate(record, representative.record) {
                return index
            }
        }
        return nil
    }

    private func belongsToSameVisitAndMoment(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Bool {
        lhs.placeID == rhs.placeID
            && abs(lhs.creationDate.timeIntervalSince(rhs.creationDate)) <= configuration.relatedTimeWindow
            && Self.distanceMeters(lhs.coordinate, rhs.coordinate) <= configuration.relatedDistanceMeters
    }

    private func conservativeMetadataDuplicate(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Bool {
        lhs.placeID == rhs.placeID
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.mediaKind == rhs.mediaKind
            && abs(lhs.creationDate.timeIntervalSince(rhs.creationDate)) <= configuration.metadataFallbackTimeWindow
            && Self.distanceMeters(lhs.coordinate, rhs.coordinate) <= configuration.metadataFallbackDistanceMeters
    }

    private func prefers(_ representative: Representative, over current: Representative) -> Bool {
        let candidate = representative.record
        if (representative.exactFrameFingerprint != nil) != (current.exactFrameFingerprint != nil) {
            return representative.exactFrameFingerprint != nil
        }
        if candidate.isFavorite != current.record.isFavorite { return candidate.isFavorite }
        // Only demote clearly soft previews. Smooth skies and portraits still
        // compete on aesthetics, and missing measurements remain eligible.
        let soft = representative.sharpness.map { $0 < 9 } ?? false
        let currentSoft = current.sharpness.map { $0 < 9 } ?? false
        if soft != currentSoft { return !soft }
        let isUtility = representative.aesthetics?.isUtility == true
        let currentIsUtility = current.aesthetics?.isUtility == true
        if isUtility != currentIsUtility { return !isUtility }
        let score = representative.aesthetics?.overallScore ?? 0
        let currentScore = current.aesthetics?.overallScore ?? 0
        if score != currentScore { return score > currentScore }
        let candidateFit = Self.televisionCompositionScore(candidate)
        let currentFit = Self.televisionCompositionScore(current.record)
        if candidateFit != currentFit { return candidateFit > currentFit }
        let candidatePixels = Int64(candidate.pixelWidth) * Int64(candidate.pixelHeight)
        let currentPixels = Int64(current.record.pixelWidth) * Int64(current.record.pixelHeight)
        if candidatePixels != currentPixels { return candidatePixels > currentPixels }
        return SlideshowOrdering.recordComesFirst(candidate, current.record)
    }

    /// Laplacian variance on the unpadded preview. Work and memory are
    /// constant across the original camera resolutions.
    private static func sharpness(_ image: CGImage) -> Double? {
        let edge = 96
        var luma = [UInt8](repeating: 0, count: edge * edge)
        let drawn = luma.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: edge, height: edge,
                bitsPerComponent: 8, bytesPerRow: edge, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0
        var squares = 0.0
        for y in 1..<(edge - 1) {
            for x in 1..<(edge - 1) {
                let i = y * edge + x
                let horizontal = Int(luma[i-1]) + Int(luma[i+1])
                let vertical = Int(luma[i-edge]) + Int(luma[i+edge])
                let derivative = Double(horizontal + vertical - 4 * Int(luma[i]))
                sum += derivative
                squares += derivative * derivative
            }
        }
        let n = Double((edge - 2) * (edge - 2))
        return squares / n - pow(sum / n, 2)
    }

    private static func televisionCompositionScore(_ record: PhotoAssetRecord) -> Double {
        guard record.pixelWidth > 0, record.pixelHeight > 0 else { return 0 }
        let ratio = Double(record.pixelWidth) / Double(record.pixelHeight)
        return 1 / (1 + abs(log(ratio / (16.0 / 9.0))))
    }

    private static func normalizedCGImage(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 384, height: 384)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let source = image.size
            guard source.width > 0, source.height > 0 else { return }
            let scale = min(size.width / source.width, size.height / source.height)
            let target = CGSize(width: source.width * scale, height: source.height * scale)
            image.draw(in: CGRect(
                x: (size.width - target.width) / 2,
                y: (size.height - target.height) / 2,
                width: target.width,
                height: target.height
            ))
        }
        return rendered.cgImage
    }

    private static func exactFrameFingerprint(_ image: CGImage) -> UInt64? {
        guard let bytes = image.dataProvider?.data else { return nil }
        return SHA256.hash(data: bytes as Data).prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func distanceMeters(_ lhs: GeoCoordinate, _ rhs: GeoCoordinate) -> Double {
        let radius = 6_371_000.0
        let latitude1 = lhs.latitude * .pi / 180
        let latitude2 = rhs.latitude * .pi / 180
        let deltaLatitude = (rhs.latitude - lhs.latitude) * .pi / 180
        let deltaLongitude = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
