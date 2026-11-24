import Combine
import Foundation
import ImageIO
import UIKit
import Vision

private nonisolated final class CoverVisionImage: @unchecked Sendable {
    let image: CGImage
    let orientation: CGImagePropertyOrientation
    init(_ image: CGImage, orientation: CGImagePropertyOrientation) {
        self.image = image; self.orientation = orientation
    }

    @MainActor convenience init?(thumbnail: UIImage) {
        guard let image = thumbnail.cgImage else { return nil }
        let orientation: CGImagePropertyOrientation
        switch thumbnail.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        self.init(image, orientation: orientation)
    }
}

#if DEBUG
/// Opt-in physical-device measurement. All file inputs are private, disposable
/// previews. The output records timings and counts with no asset identifiers.
@MainActor enum CityCoverTimingQA {
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoEarth/CoverTimingQA", isDirectory: true)
    }
    private static var phases: [[String: Any]] = []
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func recordPublication(_ phase: String, since start: TimeInterval, itemCount: Int) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-cover-publication") else { return }
        phases.append(["stage": phase, "seconds": now - start, "count": itemCount])
        write(["events": Array(phases.suffix(32))], name: "publication.json")
    }

    static func run() async {
        let input = folder.appendingPathComponent("input", isDirectory: true)
        guard FileManager.default.fileExists(atPath: input.path) else { return }
        defer { try? FileManager.default.removeItem(at: input) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let photos = try decoder.decode([PhotoAssetRecord].self,
                from: Data(contentsOf: input.appendingPathComponent("photos.json")))
            guard !photos.isEmpty, photos.count <= ScenicCoverPolicy.candidateLimit else { return }
            let engine = ScenicVisionEngine()
            func measure(useLibrary: Bool) async throws -> [String: Any] {
                let start = now
                var read: [Double] = []
                var vision: [Double] = []
                var analyses: [String: ScenicCoverAnalysis] = [:]
                for slot in photos.indices {
                    try Task.checkCancellation()
                    let photo = photos[slot]
                    let startRead = now
                    let preview: CoverVisionImage?
                    if useLibrary {
                        let delivery = await CoverThumbnailRequest(scheduler: .shared).value(for: photo)
                        preview = delivery.image.flatMap(CoverVisionImage.init(thumbnail:))
                    } else {
                        let file = input.appendingPathComponent(String(format: "%02d.jpg", slot + 1))
                        let source = CGImageSourceCreateWithURL(file as CFURL, nil)
                        preview = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                            .map { CoverVisionImage($0, orientation: .up) }
                    }
                    read.append(now - startRead)
                    guard let preview else { continue }
                    let startVision = now
                    analyses[photo.id] = try await engine.analyze(preview)
                    vision.append(now - startVision)
                }
                let startRanking = now
                let selected = CityCoverPolicy.best(in: photos, analyses: analyses)
                let rankingSeconds = now - startRanking
                let winner = selected.flatMap { photos.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                return ["seconds": now - start, "readSamples": read, "visionSamples": vision, "rankingSeconds": rankingSeconds,
                        "requested": photos.count, "analyzed": analyses.count, "winner": winner,
                        "peakConcurrentNetworkRequests": SharedPhotoImageScheduler.shared.metrics.peakNetwork]
            }
            let cold = try await measure(useLibrary: false)
            let warm = try await measure(useLibrary: false)
            write(["batchedLocalPreviews": [cold, warm]], name: "compute.json")
            let local = try await measure(useLibrary: true)
            write(["local": local], name: "photokit.json")
        } catch {
            write(["error": String(describing: type(of: error))], name: "failure.json")
        }
    }

    private static func write(_ result: [String: Any], name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
#endif

private actor ScenicVisionEngine {
    func analyze(_ image: CoverVisionImage) throws -> ScenicCoverAnalysis {
        try Task.checkCancellation()
        let classification = VNClassifyImageRequest()
        classification.revision = VNClassifyImageRequestRevision2
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image.image, orientation: image.orientation)
        try handler.perform([classification, faces])
        try Task.checkCancellation()
        let scenery = classification.results?.filter { ScenicCoverPolicy.labels.contains($0.identifier) }
            .map(\.confidence).max() ?? 0
        let largestFace = faces.results?.map { Float($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        // Classification remains useful if an optional aesthetics model fails.
        try? handler.perform([aesthetics])
        try Task.checkCancellation()
        let utility = aesthetics.results?.first?.isUtility ?? false
        let labels = Dictionary((classification.results ?? []).map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        return ScenicCoverAnalysis(scenery: scenery, aesthetics: aesthetics.results?.first?.overallScore,
                                   isUtility: utility, largestFace: largestFace,
                                   landmark: CityCoverPolicy.landmarkConfidence(labels))
    }
}

nonisolated enum CoverAnalysisPreview {
    static let preferredEdge = 512
    static let fallbackEdge = 320
    static let minimumEdge = 256

    /// PhotoKit's fast sizing can return a larger local derivative. Keep its
    /// orientation metadata and reduce the actual pixel buffer before Vision.
    static func boundedImage(_ image: UIImage) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let longEdge = max(source.width, source.height)
        guard longEdge >= minimumEdge else { return nil }
        guard longEdge > preferredEdge else { return image }
        let factor = Double(preferredEdge) / Double(longEdge)
        let width = max(1, Int(Double(source.width) * factor))
        let height = max(1, Int(Double(source.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        return UIImage(cgImage: resized, scale: image.scale, orientation: image.imageOrientation)
    }
}

@MainActor final class CoverThumbnailRequest {
    private let scheduler: SharedPhotoImageScheduler
    private var started = false
    private var pending: (id: UUID, continuation: CheckedContinuation<OverviewImageDelivery, Never>)?
    init(scheduler: SharedPhotoImageScheduler) { self.scheduler = scheduler }

    func value(for photo: PhotoAssetRecord, deadline: ContinuousClock.Instant? = nil) async -> OverviewImageDelivery {
        guard !started else { return .init(failed: true) }
        started = true
        let end = deadline ?? ContinuousClock.now.advanced(by: .seconds(12))
        return await withTaskCancellationHandler {
            let timeout = Task {
                do { try await Task.sleep(until: end, clock: .continuous) } catch { return }
                cancelPending()
            }
            defer { timeout.cancel() }
            var result = OverviewImageDelivery()
            for edge in [CoverAnalysisPreview.preferredEdge, CoverAnalysisPreview.fallbackEdge] {
                guard !Task.isCancelled, .now < end else { return .init(failed: true) }
                result = await withCheckedContinuation { continuation in
                    let token = UUID()
                    pending = (token, continuation)
                    let key = SharedPhotoImageKey(assetID: photo.id, targetSize: CGSize(width: edge, height: edge),
                                                  fillsTarget: false, forCoverAnalysis: true)
                    scheduler.request(key, network: false, priority: .prefetch, token: token) { [weak self] delivery in
                        guard delivery.isFinal, self?.pending?.id == token else { return }
                        self?.finish(delivery)
                    }
                }
                guard !Task.isCancelled, .now < end else { return .init(failed: true) }
                if result.assetUnavailable || (result.image != nil && !result.failed) { break }
            }
            return result
        } onCancel: {
            Task { @MainActor in self.cancelPending() }
        }
    }

    private func cancelPending() {
        guard let pending else { return }
        scheduler.cancel(pending.id)
        finish(.init(failed: true))
    }

    private func finish(_ delivery: OverviewImageDelivery) {
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(returning: delivery)
    }
}

/// Serializes local Vision work and shares an in-flight visit selection across its consumers.
@MainActor final class ScenicCoverSelector {
    typealias Analyze = @MainActor (PhotoAssetRecord) async throws -> ScenicCoverAnalysis?
    private struct Job {
        let id: UUID
        let places: [TravelPlace]
        let revision: String
        let fallback: PhotoPreviewMetadata?
        let journeyWindow: JourneyCoverWindow?
        let priorityVisitID: String?
        let usesCityPoster: Bool
        let excluded: Set<String>
        var journey: Bool { journeyWindow != nil }
        let currentCover: PhotoAssetRecord?
        var visitID: String? {
            guard usesCityPoster, !journey, places.count == 1, priorityVisitID == places[0].id else { return nil }
            return priorityVisitID
        }
    }
    private struct Cached {
        let value: PhotoPreviewMetadata?
        let expires: Date
    }
    private let store: any ScenicCoverStoring
    private var hasFinishedVisitInBatch = false
    private final class PreviewBudget {
        var remaining: Duration = .seconds(12)
    }
    private let analyze: @MainActor (PhotoAssetRecord, PreviewBudget?) async throws -> ScenicCoverAnalysis?
    private var jobs: [Job] = []
    private var running: [UUID: (job: Job, task: Task<Void, Never>)] = [:]
    private typealias Reply = CheckedContinuation<PhotoPreviewMetadata?, Error>
    private var subscribers: [UUID: [UUID: Reply]] = [:]
    private var memo: [String: Cached] = [:]
    private var notifications = Set<AnyCancellable>()
    private var epoch = UUID()

    init(store: any ScenicCoverStoring, analyze: Analyze? = nil) {
        self.store = store
        if let analyze { self.analyze = { photo, _ in try await analyze(photo) } }
        else {
            let engine = ScenicVisionEngine()
            self.analyze = { photo, budget in
                let request = CoverThumbnailRequest(scheduler: .shared)
                let started = ContinuousClock.now
                let delivery = await request.value(for: photo, deadline: budget.map { started.advanced(by: $0.remaining) })
                budget?.remaining -= started.duration(to: .now)
                try Task.checkCancellation()
                guard let image = delivery.image, !delivery.failed,
                      let preview = CoverVisionImage(thumbnail: image) else { return nil }
                return try await engine.analyze(preview)
            }
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }.store(in: &notifications)
    }

    func select(for places: [TravelPlace], revision: String, fallback: PhotoPreviewMetadata?,
                journeyWindow: JourneyCoverWindow? = nil, currentCover: PhotoAssetRecord? = nil,
                priorityVisitID: String? = nil, usesCityPoster: Bool = false,
                excluding excluded: Set<String> = []) async throws -> PhotoPreviewMetadata? {
        let incumbent = journeyWindow?.incumbent(currentCover, excluding: excluded)
        let safeFallback = journeyWindow.map { PhotoPreviewMetadata(incumbent ?? $0.latest) } ?? fallback
        let id = UUID()
        let job = Job(id: id, places: places, revision: revision, fallback: safeFallback,
                      journeyWindow: journeyWindow, priorityVisitID: priorityVisitID, usesCityPoster: usesCityPoster,
                      excluded: excluded, currentCover: incumbent)
        if let visit = job.visitID, let database = store as? SQLiteTravelIndexStore {
            // A ready visit must not queue behind Vision on an unrelated city.
            let token = epoch
            try Task.checkCancellation()
            let saved = try? await database.savedVisitCovers(for: [visit], excluding: excluded)[visit]
            try Task.checkCancellation()
            guard token == epoch else { throw CancellationError() }
            if let saved { return saved }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let visit = job.visitID,
                   let existing = (running.values.map(\.job) + jobs).first(where: {
                       $0.visitID == visit && $0.revision == revision && $0.excluded == excluded &&
                       $0.fallback?.assetID == safeFallback?.assetID && subscribers[$0.id] != nil
                   }) {
                    subscribers[existing.id]?[id] = continuation
                    return
                }
                subscribers[id] = [id: continuation]
                jobs.append(job)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func invalidate() {
        epoch = UUID(); memo = [:]
        hasFinishedVisitInBatch = false
        for entry in running.values { entry.task.cancel() }
        jobs.removeAll()
        let pending = subscribers
        subscribers.removeAll()
        for replies in pending.values {
            for reply in replies.values { reply.resume(throwing: CancellationError()) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let jobID = subscribers.first(where: { $0.value[id] != nil })?.key,
              let reply = subscribers[jobID]?.removeValue(forKey: id) else { return }
        reply.resume(throwing: CancellationError())
        guard subscribers[jobID]?.isEmpty == true else { return }
        subscribers.removeValue(forKey: jobID)
        if let entry = running[jobID] { entry.task.cancel() }
        else {
            jobs.removeAll { $0.id == jobID }
            pump()
        }
    }

    private func pump() {
        // Independent visits can wait for previews while the shared Vision actor
        // scores another card. A collection may include any of those visits.
        // Start with two cards for a prompt first result. Once it is ready,
        // two cards can fetch previews alongside the one being scored.
        let limit = hasFinishedVisitInBatch ? 3 : 2
        while running.count < limit, let next = jobs.first {
            if !running.isEmpty {
                guard let visit = next.visitID,
                      running.values.allSatisfy({ $0.job.visitID != nil && $0.job.visitID != visit }) else { return }
            }
            let job = jobs.removeFirst()
            let token = epoch
            running[job.id] = (job, Task { await run(job, epoch: token) })
        }
    }

    private func run(_ job: Job, epoch token: UUID) async {
        let result: Result<PhotoPreviewMetadata?, Error>
        do {
            let selection = try await process(job, epoch: token)
            try Task.checkCancellation()
            result = .success(selection)
        } catch { result = .failure(error) }
        if let replies = subscribers.removeValue(forKey: job.id) {
            for reply in replies.values { reply.resume(with: result) }
        }
        running.removeValue(forKey: job.id)
        if running.isEmpty && jobs.isEmpty { hasFinishedVisitInBatch = false }
        else if token == epoch, job.visitID != nil, case .success(.some) = result { hasFinishedVisitInBatch = true }
        pump()
    }

    private func process(_ job: Job, epoch token: UUID) async throws -> PhotoPreviewMetadata? {
        // Include all members, not just the representative visit. Length prefixes
        // avoid ambiguous concatenations; memo is bounded and never synced.
        let purpose = job.journeyWindow.map {
            "journey/\($0.latest.id)/\($0.latest.creationDate.timeIntervalSince1970)/\(job.currentCover?.id ?? "")"
        } ?? "\(job.usesCityPoster ? "city" : "scenic")/\(job.priorityVisitID ?? "")"
        let key = purpose + "|" + job.revision + "|" + job.places.map(\.id).sorted().map { "\($0.utf8.count):\($0)" }.joined()
        let database = job.visitID == nil ? nil : store as? SQLiteTravelIndexStore
        let generation = await database?.visitCoverGeneration
        try Task.checkCancellation()
        if database == nil, job.excluded.isEmpty, let cached = memo[key], cached.expires > Date() { return cached.value }
        var photos = try await store.scenicCoverCandidates(for: job.places, journeyWindow: job.journeyWindow,
                                                          priorityVisitID: job.priorityVisitID, excluding: job.excluded)
        if let current = job.currentCover, !photos.contains(where: { $0.id == current.id }) {
            photos = [current] + Array(photos.prefix(ScenicCoverPolicy.candidateLimit - 1))
        }
        func winner(_ analyses: [String: ScenicCoverAnalysis], sceneStrengths: [String: Float]) -> PhotoAssetRecord? {
            if job.journey {
                return JourneyCoverPolicy.best(in: photos, analyses: analyses, incumbent: job.currentCover?.id)
            }
            if job.usesCityPoster { return CityCoverPolicy.best(in: photos, analyses: analyses, sceneStrengths: sceneStrengths) }
            return ScenicCoverPolicy.best(in: photos, analyses: analyses)
        }
        let primaries = photos
        let usesBackups = job.usesCityPoster && !job.journey
        let budget = usesBackups ? PreviewBudget() : nil
        var analyses: [String: ScenicCoverAnalysis] = [:]
        var filled = Set<String>()
        var modelFailed = false

        // Each pair belongs to one primary's time/location slot. Visit every slot
        // in the current round before giving any missing slot its next alternative.
        func evaluate(_ round: [(slot: String, photo: PhotoAssetRecord)]) async throws {
            guard !round.isEmpty else { return }
            let cached = try await store.coverAnalyses(for: round.map { $0.photo.id }, revision: job.revision)
            for (slot, photo) in round {
                guard let score = cached[photo.id], !job.journey || score.hasAestheticScore else { continue }
                analyses[photo.id] = score
                filled.insert(slot)
            }
            for (slot, photo) in round where !filled.contains(slot) {
                try Task.checkCancellation()
                guard token == epoch else { throw CancellationError() }
                if let budget, budget.remaining <= .zero { break }
                let result: ScenicCoverAnalysis?
                do { result = try await analyze(photo, budget) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    OverviewPerformance.event("Cover analysis unavailable")
                    modelFailed = true
                    break
                }
                guard let result, !job.journey || result.hasAestheticScore else { continue }
                try Task.checkCancellation()
                guard token == epoch else { throw CancellationError() }
                try await store.saveCoverAnalysis(result, assetID: photo.id, revision: job.revision)
                analyses[photo.id] = result
                filled.insert(slot)
                await Task.yield()
            }
        }

        try await evaluate(primaries.map { ($0.id, $0) })
        let missing = Set(primaries.map(\.id)).subtracting(filled)
        if usesBackups, !missing.isEmpty, !modelFailed {
            let backups = try await store.scenicCoverBackups(for: primaries, missing: missing, excluding: job.excluded)
            for depth in 0..<2 {
                let round: [(String, PhotoAssetRecord)] = primaries.compactMap { primary in
                    guard !filled.contains(primary.id), let options = backups[primary.id], depth < options.count else { return nil }
                    return (primary.id, options[depth])
                }
                photos.append(contentsOf: round.map { $0.1 })
                try await evaluate(round)
                if modelFailed { break }
            }
        }
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
        let sceneStrengths: [String: Float]
        if usesBackups, job.places.count == 1, job.priorityVisitID == job.places.first?.id {
            sceneStrengths = try await store.sceneStrengths(for: photos.filter { analyses[$0.id] != nil }, excluding: job.excluded)
            try Task.checkCancellation()
            guard token == epoch else { throw CancellationError() }
        } else {
            sceneStrengths = [:]
        }
        let best = winner(analyses, sceneStrengths: sceneStrengths).map(PhotoPreviewMetadata.init) ?? job.fallback
        let expires = missing.isEmpty && !modelFailed ? Date.distantFuture : Date().addingTimeInterval(60)
        if let database, let visit = job.visitID, let generation, let best {
            // A cache-write failure can delay the next visit, but the completed
            // choice is still usable by consumers of the current generation.
            try? await database.saveVisitCover(best.assetID, for: visit, revision: job.revision,
                                               generation: generation, expires: expires, excluding: job.excluded)
            try Task.checkCancellation()
            return best
        }
        if memo.count >= 64 { memo = [:] }
        if job.excluded.isEmpty {
            // Even a successful backup can be superseded when an unreadable primary becomes local.
            memo[key] = Cached(value: best, expires: expires)
        }
        return best
    }
}
