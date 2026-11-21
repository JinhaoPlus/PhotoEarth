import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Single completion across Photos callbacks, deadline and cancellation, including
/// cancellation before PhotoKit returns its request ID.
private nonisolated final class EvidenceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CameraEvidence, Never>?
    private var cancelWork: [@Sendable () -> Void] = []
    private var result: CameraEvidence?

    func run(_ start: (EvidenceRequest) -> (@Sendable () -> Void)) async -> CameraEvidence {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(returning: result); return }
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(.unknown) }
                let cancel = start(self)
                registerCancellation(cancel)
            }
        } onCancel: { self.finish(.unknown) }
    }

    func registerCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if result == nil {
            cancelWork.append(action)
            lock.unlock()
        } else {
            lock.unlock()
            action()
        }
    }

    func finish(_ value: CameraEvidence) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let work = cancelWork, receiver = continuation
        continuation = nil; cancelWork.removeAll(); lock.unlock()
        for action in work { DispatchQueue.global(qos: .utility).async(execute: action) }
        receiver?.resume(returning: value)
    }
}

nonisolated final class CameraHeader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 2 * 1024 * 1024
    private let canProveMissing: Bool
    init(canProveMissing: Bool) { self.canProveMissing = canProveMissing }

    func append(_ chunk: Data) -> CameraEvidence? {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - data.count
        data.append(chunk.prefix(remaining))
        if let source = CGImageSourceCreateWithData(data as CFData, nil), Self.hasCamera(source) { return .identified }
        return data.count == limit ? .unknown : nil
    }

    func completed() -> CameraEvidence {
        lock.lock(); defer { lock.unlock() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { return .unknown }
        if Self.hasCamera(source) { return .identified }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification].contains(where: { exif?[$0] != nil }) {
            return .unknown
        }
        return canProveMissing ? .confirmedMissing : .unknown
    }

    static func hasCamera(_ source: CGImageSource) -> Bool {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel].contains {
            guard let value = tiff?[$0] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// A negative result requires a completely inspected local original. A lens tag or
/// an unreadable camera tag is enough to keep the video eligible but unverified.
nonisolated struct VideoCameraFields {
    private static let deviceIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataMake, .quickTimeMetadataModel, .quickTimeUserDataMake, .quickTimeUserDataModel,
        .commonIdentifierMake, .commonIdentifierModel
    ]
    private static let captureIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataCameraLensModel, .quickTimeMetadataCameraLensIrisFNumber,
        .quickTimeMetadataCameraFocalLength35mmEquivalent, .quickTimeMetadataCameraISOSensitivity,
        .quickTimeMetadataCameraShutterSpeedTime, .quickTimeMetadataCameraShutterSpeedAngle
    ]
    private(set) var evidence = CameraEvidence.confirmedMissing

    mutating func inspect(_ items: [AVMetadataItem]) async throws {
        for item in items {
            try Task.checkCancellation()
            guard evidence != .identified else { return }
            if let id = item.identifier, Self.captureIdentifiers.contains(id) { evidence = .unknown }
            let knownIdentifier = item.identifier.map(Self.deviceIdentifiers.contains) ?? false
            guard knownIdentifier || item.commonKey == .commonKeyMake || item.commonKey == .commonKeyModel else { continue }
            let text = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                evidence = .identified
            } else {
                evidence = .unknown
            }
        }
    }
}

nonisolated enum CameraEvidenceReader {
    static func read(_ asset: PHAsset) async -> CameraEvidence {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            guard let video = resources.first(where: { $0.type == .video }),
                  let type = UTType(video.uniformTypeIdentifier),
                  type.conforms(to: .quickTimeMovie) || type.conforms(to: .mpeg4Movie) else { return .unknown }
            return await EvidenceRequest().run { request in
                let options = PHVideoRequestOptions()
                options.version = .original; options.isNetworkAccessAllowed = false
                let manager = PHImageManager.default()
                let id = manager.requestAVAsset(forVideo: asset, options: options) { asset, _, info in
                    guard let asset, info?[PHImageErrorKey] == nil, info?[PHImageCancelledKey] as? Bool != true else {
                        request.finish(.unknown)
                        return
                    }
                    let task = Task { request.finish(await videoEvidence(in: asset)) }
                    request.registerCancellation { task.cancel() }
                }
                return { manager.cancelImageRequest(id) }
            }
        }

        guard let photo = resources.first(where: { $0.type == .photo }), let type = UTType(photo.uniformTypeIdentifier) else { return .unknown }
        let supported = [UTType.jpeg, .heic, .png, .tiff].contains(where: { type.conforms(to: $0) })
        let header = CameraHeader(canProveMissing: supported && !resources.contains(where: { $0.type == .alternatePhoto }))
        return await EvidenceRequest().run { request in
            let manager = PHAssetResourceManager.default()
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            let id = manager.requestData(for: photo, options: options) { chunk in
                if let result = header.append(chunk) { request.finish(result) }
            } completionHandler: { error in request.finish(error == nil ? header.completed() : .unknown) }
            return { manager.cancelDataRequest(id) }
        }
    }

    static func videoEvidence(in asset: AVAsset) async -> CameraEvidence {
        do {
            var fields = VideoCameraFields()
            let containerFormats = try await asset.load(.availableMetadataFormats)
            for format in containerFormats {
                try await fields.inspect(asset.loadMetadata(for: format))
                if fields.evidence == .identified { return .identified }
            }
            guard let original = asset as? AVURLAsset, original.url.isFileURL else { return .unknown }
            let tracks = try await original.load(.tracks)
            guard tracks.contains(where: { $0.mediaType == .video }), try await original.load(.isReadable) else { return .unknown }
            for track in tracks {
                let formats = try await track.load(.availableMetadataFormats)
                for format in formats {
                    try await fields.inspect(track.loadMetadata(for: format))
                    if fields.evidence == .identified { return .identified }
                }
            }
            // Reading timed metadata samples may require streaming the movie. A video
            // with an uninspected metadata track cannot supply a definitive negative.
            if tracks.contains(where: { $0.mediaType == .metadata }) { return .unknown }
            return fields.evidence
        } catch { return .unknown }
    }
}
