import Combine
import Foundation
import UIKit

nonisolated enum PhotoImagePriority: Int, Comparable, Sendable {
    case detail, focus, visible, prefetch
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct SharedPhotoImageKey: Hashable, Sendable {
    enum Tier: CaseIterable { case thumbnail, preview, detail }
    let assetID: String
    let width: Int
    let height: Int
    let fillsTarget: Bool
    let usesOriginal: Bool
    let forCoverAnalysis: Bool

    init(assetID: String, targetSize: CGSize, fillsTarget: Bool, usesOriginal: Bool = false,
         forCoverAnalysis: Bool = false) {
        self.assetID = assetID
        width = Int(targetSize.width.isFinite ? min(max(targetSize.width.rounded(.up), 1), 3_840) : 1)
        height = Int(targetSize.height.isFinite ? min(max(targetSize.height.rounded(.up), 1), 3_840) : 1)
        self.fillsTarget = fillsTarget
        self.usesOriginal = usesOriginal
        self.forCoverAnalysis = forCoverAnalysis
    }
    var targetSize: CGSize { CGSize(width: width, height: height) }
    var longEdge: Int { max(width, height) }
    var tier: Tier { longEdge > 1_600 ? .detail : longEdge > 640 ? .preview : .thumbnail }
    // Wide-color buffers can occupy eight bytes per pixel. PhotoKit receives
    // an asset-shaped target; fill may require a square bounded by the long edge.
    var reservation: Int {
        // Fast PhotoKit resizing can return the next larger cached derivative
        // even for a 320 px request. Analysis caps its delivered pixels at 512.
        if forCoverAnalysis { return CoverAnalysisPreview.preferredEdge * CoverAnalysisPreview.preferredEdge * 8 }
        return (fillsTarget ? longEdge * longEdge : width * height) * 8
    }
}

@MainActor protocol SharedPhotoImageRequesting: AnyObject {
    func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void)
    func cancel(_ token: UUID)
    func invalidate(_ ids: Set<String>?)
}

/// All image surfaces, including the home queue, pass their actual PhotoKit and
/// ImageIO work through this one scheduler. Cache limits are decoded references
/// owned here; they are not a claim about MapKit, PhotoKit or process memory.
@MainActor final class SharedPhotoImageScheduler {
    static let shared = SharedPhotoImageScheduler(observesLifecycle: true)

    nonisolated struct Configuration: Sendable {
        var localLimit = 4
        var networkLimit = 2
        var localTimeout: TimeInterval = 2
        var networkTimeout: TimeInterval = 30
        var networkDwell: TimeInterval = 0.25
        var thumbnailBytes = 24 * 1_024 * 1_024
        var previewBytes = 64 * 1_024 * 1_024
        var detailBytes = 64 * 1_024 * 1_024
        var totalBytes = 240 * 1_024 * 1_024
        var maximumCachedImages = 64
    }
    struct Metrics {
        var peakLocal = 0
        var peakNetwork = 0
        var peakAccountedBytes = 0
        var cacheHits = 0
        var deduplicated = 0
        var cancellations = 0
        var timeouts = 0
    }
    private struct StageKey: Hashable { let image: SharedPhotoImageKey; let network: Bool }
    private struct Consumer {
        var priority: PhotoImagePriority
        let completion: @MainActor @Sendable (OverviewImageDelivery) -> Void
    }
    private struct Job {
        let key: StageKey
        var consumers: [UUID: Consumer]
        let order: UInt64
        let queuedAt: Date
        var eligibleAt: Date
        var token: UUID?
        var deadline: Date?
        var startedAt: Date?
        var activeTime: TimeInterval = 0
        var priority: PhotoImagePriority { consumers.values.map(\.priority).min() ?? .prefetch }
    }
    private struct Cached {
        let image: UIImage
        let cost: Int
        var lastUse: UInt64
    }
    private let requester: any SharedPhotoImageRequesting
    private let configuration: Configuration
    private let now: () -> Date
    private let automaticScheduling: Bool
    private var jobs: [StageKey: Job] = [:]
    private var subscriptions: [UUID: StageKey] = [:]
    private var cache: [SharedPhotoImageKey: Cached] = [:]
    private var serial: UInt64 = 0
    private var pumping = false
    private var needsPump = false
    private var wake: Task<Void, Never>?
    private var notifications: [AnyCancellable] = []
    private(set) var metrics = Metrics()

    init(requester: (any SharedPhotoImageRequesting)? = nil, configuration: Configuration = .init(),
         now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) },
         automaticScheduling: Bool = true, observesLifecycle: Bool = false) {
        self.requester = requester ?? SharedPhotoKitRequester()
        self.configuration = configuration
        self.now = now
        self.automaticScheduling = automaticScheduling
        if observesLifecycle {
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.invalidate(nil) } }.store(in: &notifications)
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.memoryWarning() } }.store(in: &notifications)
        }
    }

    var activeLocalCount: Int { jobs.values.filter { $0.token != nil && !$0.key.network }.count }
    var activeNetworkCount: Int { jobs.values.filter { $0.token != nil && $0.key.network }.count }
    var subscriptionCount: Int { subscriptions.count }
    var cachedImageCount: Int { cache.count }
    var accountedBytes: Int { cache.values.reduce(0) { $0 + $1.cost } + jobs.values.filter { $0.token != nil }.reduce(0) { $0 + $1.key.image.reservation } }

    /// A wall preview may become the first detail frame, without waiting for an
    /// asset lookup or requesting another preview. Full-size retention is separate.
    func cachedPreview(for assetID: String, maximumLongEdge: Int = 1_600, fullFrameOnly: Bool = false) -> UIImage? {
        guard let key = cache.keys.filter({
            $0.assetID == assetID && $0.tier != .detail && $0.longEdge <= maximumLongEdge &&
                (!fullFrameOnly || !$0.fillsTarget || $0.usesOriginal)
        })
            .max(by: { cache[$0]!.cost < cache[$1]!.cost }) else { return nil }
        serial &+= 1; cache[key]?.lastUse = serial
        return cache[key]?.image
    }

    func request(_ key: SharedPhotoImageKey, network: Bool, priority: PhotoImagePriority,
                 token: UUID, completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        cancel(token)
        if var value = cache[key] {
            serial &+= 1; value.lastUse = serial; cache[key] = value
            metrics.cacheHits += 1
            completion(.init(image: value.image))
            return
        }
        guard !network || (!key.forCoverAnalysis && priority != .prefetch) else {
            completion(.init(needsNetwork: true)); return
        }
        let stage = StageKey(image: key, network: network)
        let consumer = Consumer(priority: priority, completion: completion)
        subscriptions[token] = stage
        if var job = jobs[stage] {
            job.consumers[token] = consumer
            if priority <= .focus { job.eligibleAt = now() }
            jobs[stage] = job
            metrics.deduplicated += 1
        } else {
            serial &+= 1
            let date = now()
            jobs[stage] = Job(key: stage, consumers: [token: consumer], order: serial, queuedAt: date,
                              eligibleAt: network && priority > .focus ? date.addingTimeInterval(configuration.networkDwell) : date)
        }
        tick()
    }

    func updatePriority(_ priority: PhotoImagePriority, token: UUID) {
        guard let key = subscriptions[token], var job = jobs[key], var consumer = job.consumers[token] else { return }
        consumer.priority = priority; job.consumers[token] = consumer
        if priority <= .focus { job.eligibleAt = now() }
        jobs[key] = job
        tick()
    }

    func cancel(_ token: UUID) {
        guard let key = subscriptions.removeValue(forKey: token), var job = jobs[key] else { return }
        job.consumers.removeValue(forKey: token)
        if job.consumers.isEmpty {
            jobs.removeValue(forKey: key)
            if let active = job.token { requester.cancel(active); metrics.cancellations += 1 }
        } else { jobs[key] = job }
        tick()
    }

    func tick() {
        guard !pumping else { needsPump = true; return }
        pumping = true
        needsPump = false
        let date = now()
        for job in Array(jobs.values) where job.deadline.map({ $0 <= date }) == true {
            guard let token = job.token else { continue }
            requester.cancel(token)
            metrics.timeouts += 1
            finish(job.key, token: token, result: .init(failed: job.key.network))
        }
        // Detail/focus may displace a lower-priority cloud transfer. Its current
        // subscribers remain queued and cancellation only ends the native handle.
        let ordered = jobs.values.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.order < $1.order }
        for queued in ordered where queued.token == nil && queued.eligibleAt <= date {
            guard var job = jobs[queued.key], job.token == nil else { continue }
            // Another surface may have completed the local stage while this
            // cloud consumer was waiting. Reuse it before charging more work.
            if let cached = cache[job.key.image] {
                jobs.removeValue(forKey: job.key)
                for id in job.consumers.keys { subscriptions.removeValue(forKey: id) }
                metrics.cacheHits += 1
                for consumer in job.consumers.values { consumer.completion(.init(image: cached.image)) }
                continue
            }
            // Never run local and cloud stages concurrently for one exact image.
            guard !jobs.values.contains(where: { $0.key.image == job.key.image && $0.token != nil }) else { continue }
            if job.key.network && job.key.image.usesOriginal,
               jobs.values.contains(where: { $0.token != nil && $0.key.network == job.key.network && $0.key.image.usesOriginal }) {
                continue
            }
            // Speculative local preparation leaves half the local slots free
            // for cards that actually became visible.
            if job.priority == .prefetch,
               jobs.values.filter({ $0.token != nil && $0.priority == .prefetch }).count >= 2 { continue }
            let limit = job.key.network ? configuration.networkLimit : configuration.localLimit
            var count = job.key.network ? activeNetworkCount : activeLocalCount
            if count >= limit, job.priority <= .focus,
               let victim = jobs.values.filter({ $0.token != nil && $0.key.network == job.key.network && $0.priority > job.priority })
                .max(by: { $0.priority < $1.priority }) {
                pause(victim); count -= 1
            }
            guard count < limit else { continue }
            trim(toFit: job.key.image.reservation)
            guard accountedBytes + job.key.image.reservation <= configuration.totalBytes else { continue }
            let token = UUID()
            job.token = token
            job.startedAt = date
            let timeout = job.key.network ? configuration.networkTimeout : configuration.localTimeout
            job.deadline = date.addingTimeInterval(max(0.01, timeout - job.activeTime))
            jobs[job.key] = job
            metrics.peakLocal = max(metrics.peakLocal, activeLocalCount)
            metrics.peakNetwork = max(metrics.peakNetwork, activeNetworkCount)
            metrics.peakAccountedBytes = max(metrics.peakAccountedBytes, accountedBytes)
            OverviewPerformance.event(job.key.network ? "Shared cloud image start" : "Shared local image start")
            let activeKey = job.key
            requester.request(activeKey.image, network: activeKey.network, token: token) { [weak self] result in
                self?.receive(result, key: activeKey, token: token)
            }
        }
        pumping = false
        scheduleWake()
    }

    private func receive(_ result: OverviewImageDelivery, key: StageKey, token: UUID) {
        guard let job = jobs[key], job.token == token else { return }
        var accepted = result
        if key.image.forCoverAnalysis, let image = accepted.image,
           image.cgImage.map({ max($0.width, $0.height) >= CoverAnalysisPreview.minimumEdge }) != true {
            accepted.image = nil
        }
        if let image = result.image, Self.cost(image) > key.image.reservation {
            accepted.image = nil; accepted.failed = true; accepted.isFinal = true
        }
        if accepted.isFinal {
            finish(key, token: token, result: accepted)
        } else {
            for (id, consumer) in job.consumers where subscriptions[id] == key { consumer.completion(accepted) }
        }
        tick()
    }

    private func finish(_ key: StageKey, token: UUID, result: OverviewImageDelivery) {
        guard let job = jobs[key], job.token == token else { return }
        jobs.removeValue(forKey: key)
        for id in job.consumers.keys { subscriptions.removeValue(forKey: id) }
        if let image = result.image, !result.failed {
            serial &+= 1
            cache[key.image] = Cached(image: image, cost: Self.cost(image), lastUse: serial)
            trim(toFit: 0)
        }
        for consumer in job.consumers.values { consumer.completion(result) }
    }

    private func pause(_ job: Job) {
        guard let token = job.token else { return }
        requester.cancel(token); metrics.cancellations += 1
        var queued = job; queued.token = nil; queued.deadline = nil
        if let started = queued.startedAt { queued.activeTime += max(0, now().timeIntervalSince(started)) }
        queued.startedAt = nil
        jobs[job.key] = queued
    }

    /// Home invalidates its own subscriptions separately. Dropping the shared
    /// cache must not cancel another page that already handled the same notice.
    func invalidateCache(_ ids: Set<String>?) {
        cache = cache.filter { ids != nil && !ids!.contains($0.key.assetID) }
        requester.invalidate(ids)
    }

    func invalidate(_ ids: Set<String>?) {
        let affected = jobs.values.filter { ids == nil || ids!.contains($0.key.image.assetID) }
        // Suspend pumping while adapters receive cancellation. The ensuing view
        // reloads start after the synchronous metadata notice is published.
        let wasPumping = pumping; pumping = true
        for job in affected {
            if let token = job.token { requester.cancel(token) }
            jobs.removeValue(forKey: job.key)
            for id in job.consumers.keys { subscriptions.removeValue(forKey: id) }
        }
        cache = cache.filter { ids != nil && !ids!.contains($0.key.assetID) }
        requester.invalidate(ids)
        for job in affected { for consumer in job.consumers.values { consumer.completion(.init(assetUnavailable: true, failed: true)) } }
        pumping = wasPumping
        tick()
    }

    func memoryWarning() {
        cache = [:]
        for job in Array(jobs.values) where job.priority == .prefetch {
            for token in job.consumers.keys { cancel(token) }
        }
    }

    private func trim(toFit addition: Int) {
        let limits: [SharedPhotoImageKey.Tier: Int] = [.thumbnail: configuration.thumbnailBytes,
            .preview: configuration.previewBytes, .detail: configuration.detailBytes]
        for tier in SharedPhotoImageKey.Tier.allCases {
            var bytes = cache.filter { $0.key.tier == tier }.values.reduce(0) { $0 + $1.cost }
            let entries = cache.filter { $0.key.tier == tier }.sorted { $0.value.lastUse < $1.value.lastUse }
            // Only one recently viewed full-size image can remain after a switch.
            var count = entries.count
            for (key, value) in entries where bytes > limits[tier, default: 0] || (tier == .detail && count > 1) {
                cache.removeValue(forKey: key); bytes -= value.cost; count -= 1
            }
        }
        for (key, _) in cache.sorted(by: { $0.value.lastUse < $1.value.lastUse })
            where accountedBytes + addition > configuration.totalBytes || cache.count > configuration.maximumCachedImages {
            cache.removeValue(forKey: key)
        }
    }

    private func scheduleWake() {
        wake?.cancel(); wake = nil
        guard automaticScheduling, !jobs.isEmpty else { return }
        let date = now()
        let deadlines = jobs.values.compactMap(\.deadline) + jobs.values.filter { $0.token == nil && $0.eligibleAt > date }.map(\.eligibleAt)
        // Synchronous test backends may finish during pumping and enqueue the
        // next stage. A short wake also handles this without recursion.
        let next = needsPump ? date.addingTimeInterval(0.01) : deadlines.min()
        guard let next else { return }
        wake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSince(date)))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private static func cost(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 8)
    }

    isolated deinit {
        wake?.cancel()
        for job in jobs.values { if let token = job.token { requester.cancel(token) } }
    }
}
