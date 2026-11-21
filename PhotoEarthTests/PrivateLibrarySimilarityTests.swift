import CoreLocation
import Foundation
import Photos
import Testing
import UIKit
@testable import PhotoEarth

@MainActor
struct PrivateLibrarySimilarityTests {
    private static let environmentKey = "PHOTOEARTH_PRIVATE_PAIR_GROUPS"

    private struct Source: Decodable {
        let key: String
        let date: Double
        let latitude: Double
        let longitude: Double
        let kind: String

        var media: PhotoMediaKind? {
            switch kind {
            case "photo": .photo
            case "live", "livePhoto": .livePhoto
            case "video": .video
            default: nil
            }
        }

        var uuid: UUID? { key.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) } }
        var valid: Bool {
            uuid != nil && date.isFinite && (-90...90).contains(latitude)
                && (-180...180).contains(longitude) && media != nil
        }
    }

    private enum InputError: Error {
        case invalidReviewManifest, photoAccessUnavailable
    }

    private enum Match {
        case found(PhotoAssetRecord), missing, ambiguous
    }

    private struct Scene {
        let ordinal: Int
        let records: [PhotoAssetRecord]
    }

    private final class ReviewedPreviews: SlideshowThumbnailProviding {
        var images: [String: UIImage] = [:]
        private(set) var missingRequestCount = 0

        func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? {
            guard let image = images[record.id] else {
                missingRequestCount += 1
                return nil
            }
            return image
        }
    }

    /// Each group was independently reviewed on the Mac. Members of a group
    /// depict the same scene; the first images of different groups are distinct.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_PAIR_GROUPS"] != nil))
    func keepsEachDistinctSceneAndSuppressesItsOtherFrameOnAnotherPage() async throws {
        guard let value = ProcessInfo.processInfo.environment[Self.environmentKey],
              let groups = try? JSONDecoder().decode([[Source]].self, from: Data(value.utf8)),
              groups.count >= 4,
              groups.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.valid } }) else {
            throw InputError.invalidReviewManifest
        }
        let sourceIDs = groups.flatMap { $0.compactMap(\.uuid) }
        guard Set(sourceIDs).count == sourceIDs.count else { throw InputError.invalidReviewManifest }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw InputError.photoAccessUnavailable }

        var located: [Scene] = []
        var reasons: [Int: String] = [:]
        var matchCounts: [String: Int] = [:]
        for (index, sources) in groups.enumerated() {
            var records: [PhotoAssetRecord] = []
            let number = index + 1
            for source in sources {
                switch match(source) {
                case .found(let record):
                    records.append(record)
                    matchCounts[record.id, default: 0] += 1
                case .missing: reasons[number] = reasons[number] ?? "unmatched"
                case .ambiguous: reasons[number] = "ambiguous_metadata"
                }
            }
            if records.count == sources.count { located.append(Scene(ordinal: number, records: records)) }
        }

        let previews = ReviewedPreviews()
        let requester = SharedSlideshowThumbnailProvider()
        var ready: [Scene] = []
        for scene in located {
            guard scene.records.allSatisfy({ matchCounts[$0.id] == 1 }) else {
                reasons[scene.ordinal] = "non_unique_asset"
                continue
            }
            var images: [String: UIImage] = [:]
            for record in scene.records {
                for _ in 0..<2 {
                    try Task.checkCancellation()
                    if let image = await requester.image(for: record, longEdge: 384),
                       let frame = image.cgImage,
                       max(frame.width, frame.height) >= 256, min(frame.width, frame.height) >= 32 {
                        images[record.id] = image
                        break
                    }
                }
                if images[record.id] == nil { break }
            }
            guard images.count == scene.records.count else {
                reasons[scene.ordinal] = "preview_unavailable"
                continue
            }
            previews.images.merge(images) { previous, _ in previous }
            ready.append(scene)
        }
        let unavailable = reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        print("PHOTO_EARTH_REVIEWED_SCENES total=\(groups.count) readable=\(ready.count) excludedGroups=[\(unavailable)]")

        // Isolate each pair before testing the combined session. A match to a
        // different scene must never mask a missed match to its own reference.
        var expectedMatchesKept: [Int] = []
        var distinctScenesMerged: [Int] = []
        var sessionRepeats: [Int] = []
        let session = PhotoSimilarityAnalyzer(thumbnailProvider: previews)
        for scene in ready {
            let opening = scene.records[0]
            let isolated = PhotoSimilarityAnalyzer(thumbnailProvider: previews)
            let reference = try await isolated.selectPage([opening], longEdge: 384)
            reference.commit()
            var missed = false
            for candidate in scene.records.dropFirst() {
                if !(try await isolated.selectPage([candidate], longEdge: 384)).records.isEmpty { missed = true }
            }
            if missed { expectedMatchesKept.append(scene.ordinal) }
            let firstPage = try await session.selectPage([opening], longEdge: 384)
            if firstPage.records.isEmpty { distinctScenesMerged.append(scene.ordinal) }
            firstPage.commit()
        }
        for scene in ready {
            let later = try await session.selectPage(Array(scene.records.dropFirst()), longEdge: 384)
            if !later.records.isEmpty { sessionRepeats.append(scene.ordinal) }
            later.commit()
        }
        print("PHOTO_EARTH_REVIEWED_RESULT falseMergeGroups=\(distinctScenesMerged) missedPairGroups=\(expectedMatchesKept) crossPageRepeatGroups=\(sessionRepeats)")
        let readableCount = ready.count
        let missingRequestCount = previews.missingRequestCount
        #expect(readableCount >= 4, "At least four complete, independently reviewed groups require matching TV assets and readable previews.")
        #expect(missingRequestCount == 0)
        #expect(distinctScenesMerged.isEmpty)
        #expect(expectedMatchesKept.isEmpty)
        #expect(sessionRepeats.isEmpty)
    }

    private func match(_ source: Source) -> Match {
        guard let uuid = source.uuid, let media = source.media else { return .missing }
        let forms = [uuid.uuidString, uuid.uuidString.lowercased()]
        let identifiers = Set([source.key] + forms.flatMap { stem in
            ["/L0/001", "/L0/000", "/L0/002"].map { stem + $0 }
        })
        let exact = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var identified: [PhotoAssetRecord] = []
        for index in 0..<exact.count {
            if let record = PhotoKitLibrary.record(exact.object(at: index)), record.mediaKind == media {
                identified.append(record)
            }
        }
        if identified.count == 1 { return .found(identified[0]) }
        if identified.count > 1 { return .ambiguous }

        let date = Date(timeIntervalSinceReferenceDate: source.date)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
            date.addingTimeInterval(-0.5) as NSDate, date.addingTimeInterval(0.5) as NSDate)
        let nearby = PHAsset.fetchAssets(with: media == .video ? .video : .image, options: options)
        let location = CLLocation(latitude: source.latitude, longitude: source.longitude)
        var match: PhotoAssetRecord?
        for index in 0..<nearby.count {
            let asset = nearby.object(at: index)
            guard let position = asset.location, location.distance(from: position) <= 5,
                  let row = PhotoKitLibrary.record(asset), row.mediaKind == media else { continue }
            if match != nil { return .ambiguous }
            match = row
        }
        return match.map(Match.found) ?? .missing
    }
}
