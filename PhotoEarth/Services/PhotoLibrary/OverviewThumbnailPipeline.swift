import Foundation
import Observation
import OSLog
import UIKit

nonisolated struct OverviewImageKey: Hashable, Sendable {
    enum Size: Int, Sendable { case dock, card }
    let assetID: String
    let size: Size
    let usesOriginal: Bool

    init(assetID: String, size: Size, usesOriginal: Bool = false) {
        self.assetID = assetID
        self.size = size
        self.usesOriginal = usesOriginal
    }
    func requestKey(reduced: Bool = false) -> SharedPhotoImageKey {
        let edge: CGFloat = reduced ? 320 : 640
        let height = size == .dock ? edge * 3 / 5 : edge
        return .init(assetID: assetID, targetSize: CGSize(width: edge, height: height),
                     fillsTarget: size == .dock, usesOriginal: usesOriginal)
    }
}

nonisolated struct OverviewImageDelivery: Sendable {
    var image: UIImage?
    var isFinal = true
    var needsNetwork = false
    var assetUnavailable = false
    var failed = false
}

@MainActor protocol OverviewImageRequesting: AnyObject {
    func prepare(_ keys: [OverviewImageKey], preheat: [OverviewImageKey])
    func setPriority(_ priority: PhotoImagePriority, token: UUID)
    /// Caller creates the token before starting, including synchronous delivery.
    func request(_ key: OverviewImageKey, network: Bool, reduced: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void)
    func cancel(_ token: UUID)
    func invalidate(_ ids: Set<String>?)
}

extension OverviewImageRequesting {
    func setPriority(_ priority: PhotoImagePriority, token: UUID) {}
}

@Observable @MainActor final class OverviewThumbnail {
    enum Status { case waiting, local, cloud, ready, unavailable }
    private(set) var image: UIImage?
    private(set) var status: Status = .waiting
    let key: OverviewImageKey
    @ObservationIgnored fileprivate var cost = 0
    @ObservationIgnored fileprivate var lastUse: UInt64 = 0
    @ObservationIgnored fileprivate var localFinished = false
    @ObservationIgnored fileprivate var complete = false
    @ObservationIgnored fileprivate var unavailable = false
    @ObservationIgnored fileprivate var cloudConfirmed = false
    @ObservationIgnored fileprivate var retryAt: Date?
    @ObservationIgnored fileprivate var retries = 0
    @ObservationIgnored fileprivate var networkTime: TimeInterval = 0
    @ObservationIgnored fileprivate var reduced = false
    fileprivate init(_ key: OverviewImageKey) { self.key = key }
    fileprivate func show(_ image: UIImage?, cost: Int) { self.image = image; self.cost = cost }
    fileprivate func setStatus(_ value: Status) { if status != value { status = value } }
}

/// A single home owner merges card consumers by key. Entries are shared by all
/// cards displaying the same asset/size, and observable image changes stay local.
@MainActor final class OverviewThumbnailPipeline {
    nonisolated struct Configuration: Sendable {
        var localLimit = 4
        var networkLimit = 2
        var memoryLimit = 48 * 1_024 * 1_024
        var cacheLimit = 40
        var settleDelay: TimeInterval = 0.25
        var localTimeout: TimeInterval = 2
        var networkTimeout: TimeInterval = 30
        var retryDelay: TimeInterval = 60
        var preemptionDelay: TimeInterval = 1
    }
    struct Metrics {
        var localRequests = 0
        var networkRequests = 0
        var cacheHits = 0
        var cancellations = 0
        var timeouts = 0
        var peakLocal = 0
        var peakNetwork = 0
        var peakAccountedBytes = 0
    }
    private struct Job {
        let token: UUID
        let key: OverviewImageKey
        let network: Bool
        let started: Date
        let deadline: Date
        let reservation: Int
    }
    private let requester: any OverviewImageRequesting
    private let configuration: Configuration
    private let now: () -> Date
    private let automaticScheduling: Bool
    private var entries: [OverviewImageKey: OverviewThumbnail] = [:]
    private var jobs: [OverviewImageKey: Job] = [:]
    private var demand: [OverviewImageKey: Int] = [:]
    private var focusedRowOrder: [OverviewImageKey: Int] = [:]
    private var settleAt = Date.distantFuture
    private var lastPreemption = Date.distantPast
    private var timer: Task<Void, Never>?
    private var serial: UInt64 = 0
    private var pumping = false
    private var memoryConstrained = false
    private var isMoving = false
    private(set) var metrics = Metrics()

    init(requester: (any OverviewImageRequesting)? = nil, configuration: Configuration = .init(),
         now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) },
         automaticScheduling: Bool = true) {
        self.requester = requester ?? OverviewPhotoKitRequester()
        self.configuration = configuration
        self.now = now
        self.automaticScheduling = automaticScheduling
    }

    var accountedBytes: Int {
        entries.values.reduce(0) { $0 + $1.cost } + jobs.values.reduce(0) { $0 + $1.reservation }
    }
    var activeRequestCount: Int { jobs.count }
    var retainedImageCount: Int { entries.values.filter { $0.image != nil }.count }
    private var budget: Int { memoryConstrained ? configuration.memoryLimit / 2 : configuration.memoryLimit }

    func thumbnail(for key: OverviewImageKey) -> OverviewThumbnail {
        if let entry = entries[key] { return entry }
        let entry = OverviewThumbnail(key)
        entries[key] = entry
        return entry
    }

    /// Priority 0 = focus, 1 = actually visible, 2 = nearby local-only.
    func update(_ values: [OverviewImageKey: Int], preheat: [OverviewImageKey] = [], moving: Bool,
                focusedRowOrder: [OverviewImageKey: Int] = [:]) {
        self.focusedRowOrder = focusedRowOrder
        let candidates = memoryConstrained ? values.filter { $0.value < 2 } : values
        let next = Dictionary(uniqueKeysWithValues: candidates.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            if $0.key.assetID != $1.key.assetID { return $0.key.assetID < $1.key.assetID }
            return $0.key.size.rawValue < $1.key.size.rawValue
        }.prefix(15).map { ($0.key, $0.value) })
        let changed = demand != next
        if changed || isMoving != moving { settleAt = now().addingTimeInterval(configuration.settleDelay) }
        isMoving = moving
        let old = demand
        demand = next
        for (key, _) in next {
            let entry = thumbnail(for: key)
            serial &+= 1; entry.lastUse = serial
            if old[key] == nil, entry.complete, entry.image != nil {
                metrics.cacheHits += 1
                OverviewPerformance.event("Thumbnail cache hit")
            }
        }
        for job in Array(jobs.values) where next[job.key] == nil
            || ((job.network || job.key.usesOriginal) && next[job.key, default: 2] >= 2) {
            stop(job)
        }
        for job in jobs.values {
            requester.setPriority(Self.priority(next[job.key, default: 2]), token: job.token)
        }
        requester.prepare(Array(next.keys), preheat: memoryConstrained ? [] : Array(preheat.prefix(5)))
        trim()
        tick()
    }

    func tick() {
        guard !pumping else { return }
        pumping = true
        let date = now()
        for job in Array(jobs.values) where job.deadline <= date {
            stop(job)
            metrics.timeouts += 1
            guard let entry = entries[job.key] else { continue }
            if job.network { fail(entry, at: date) }
            else { entry.localFinished = true }
            OverviewPerformance.event("Thumbnail timeout")
        }
        for key in demand.keys {
            guard let entry = entries[key], let retry = entry.retryAt, retry <= date, entry.retries < 1 else { continue }
            entry.retryAt = nil; entry.retries += 1; entry.networkTime = 0
            entry.unavailable = false
        }
        let ordered = demand.keys.sorted {
            if demand[$0] != demand[$1] { return demand[$0, default: 2] < demand[$1, default: 2] }
            let left = focusedRowOrder[$0, default: .max], right = focusedRowOrder[$1, default: .max]
            if left != right { return left < right }
            return entries[$0]!.lastUse < entries[$1]!.lastUse
        }
        if !isMoving, date >= settleAt,
           let focus = ordered.first(where: { demand[$0] == 0 && eligible($0, network: true) }),
           jobs.values.filter(\.network).count >= configuration.networkLimit,
           date.timeIntervalSince(lastPreemption) >= configuration.preemptionDelay,
           let victim = jobs.values.filter({ $0.network && demand[$0.key, default: 2] > 0 })
            .max(by: { $0.started < $1.started }) {
            stop(victim)
            lastPreemption = date
            OverviewPerformance.event("Thumbnail focus preemption")
            start(focus, network: true, at: date)
        }
        for key in ordered where jobs[key] == nil {
            if eligible(key, network: false), jobs.values.filter({ !$0.network }).count < configuration.localLimit {
                start(key, network: false, at: date)
            }
            if !isMoving, date >= settleAt, eligible(key, network: true),
               jobs.values.filter(\.network).count < configuration.networkLimit {
                start(key, network: true, at: date)
            }
        }
        trim()
        metrics.peakAccountedBytes = max(metrics.peakAccountedBytes, accountedBytes)
        pumping = false
        scheduleWake()
    }

    private func eligible(_ key: OverviewImageKey, network: Bool) -> Bool {
        guard let entry = entries[key], demand[key] != nil, jobs[key] == nil,
              !entry.complete, !entry.unavailable, entry.retryAt == nil else { return false }
        if key.usesOriginal, demand[key, default: 2] >= 2 { return false }
        return network ? entry.localFinished && demand[key, default: 2] < 2 : !entry.localFinished
    }

    private func start(_ key: OverviewImageKey, network: Bool, at date: Date) {
        guard let entry = entries[key] else { return }
        if network, entry.networkTime >= configuration.networkTimeout { fail(entry, at: date); return }
        let reservation = key.requestKey(reduced: entry.reduced).reservation
        evict(toFit: reservation, keeping: key)
        guard accountedBytes + reservation <= budget else { return }
        let job = Job(token: UUID(), key: key, network: network, started: date,
                      deadline: date.addingTimeInterval(network ? configuration.networkTimeout - entry.networkTime : configuration.localTimeout),
                      reservation: reservation)
        jobs[key] = job
        entry.setStatus(network && entry.cloudConfirmed ? .cloud : .local)
        if network { metrics.networkRequests += 1 } else { metrics.localRequests += 1 }
        metrics.peakLocal = max(metrics.peakLocal, jobs.values.filter { !$0.network }.count)
        metrics.peakNetwork = max(metrics.peakNetwork, jobs.values.filter(\.network).count)
        metrics.peakAccountedBytes = max(metrics.peakAccountedBytes, accountedBytes)
        OverviewPerformance.event(network ? "Cloud thumbnail start" : "Local thumbnail start")
        requester.setPriority(Self.priority(demand[key, default: 2]), token: job.token)
        requester.request(key, network: network, reduced: entry.reduced, token: job.token) { [weak self] delivery in
            self?.receive(delivery, job: job)
        }
    }

    private func receive(_ delivery: OverviewImageDelivery, job: Job) {
        guard jobs[job.key]?.token == job.token, let entry = entries[job.key], demand[job.key] != nil else { return }
        // Final pixels replace the in-flight reservation. A progressive preview
        // still needs room alongside the pending final image.
        if delivery.isFinal { finish(job) }
        entry.cloudConfirmed = entry.cloudConfirmed || delivery.needsNetwork
        if job.network, entry.cloudConfirmed { entry.setStatus(.cloud) }
        var accepted = delivery.image == nil
        if let image = delivery.image {
            let cost = Self.imageCost(image)
            let pixelLimit = job.reservation
            if cost <= pixelLimit {
                let increment = max(0, cost - entry.cost)
                evict(toFit: increment, keeping: job.key)
                if accountedBytes + increment <= budget {
                    let replacesImage = cost > entry.cost || delivery.isFinal
                    if replacesImage, entry.image !== image { entry.show(image, cost: cost) }
                    accepted = true
                    OverviewPerformance.event("Thumbnail delivered")
                }
            }
        }
        guard delivery.isFinal else { return }
        if delivery.assetUnavailable {
            if !delivery.failed { entry.show(nil, cost: 0) }
            entry.unavailable = true; entry.setStatus(.unavailable)
        } else if delivery.image != nil && !delivery.failed && accepted {
            entry.complete = true; entry.setStatus(.ready)
        } else if !accepted && !entry.reduced {
            entry.reduced = true; entry.localFinished = false
        } else if job.network {
            fail(entry, at: now())
        } else {
            entry.localFinished = true
            entry.setStatus(.waiting)
        }
        tick()
    }

    private func fail(_ entry: OverviewThumbnail, at date: Date) {
        entry.setStatus(.unavailable)
        entry.retryAt = date.addingTimeInterval(configuration.retryDelay)
        if entry.retries >= 1 { entry.unavailable = true }
    }

    private func finish(_ job: Job) {
        guard jobs[job.key]?.token == job.token else { return }
        jobs.removeValue(forKey: job.key)
        if job.network { entries[job.key]?.networkTime += max(0, now().timeIntervalSince(job.started)) }
    }

    private func stop(_ job: Job) {
        finish(job)
        requester.cancel(job.token)
        metrics.cancellations += 1
        if let entry = entries[job.key], !entry.complete { entry.setStatus(.waiting) }
    }

    func invalidate(_ ids: Set<String>?, removed: Set<String> = []) {
        for key in Array(entries.keys) where ids == nil || ids!.contains(key.assetID) {
            if let job = jobs[key] { stop(job) }
            guard let entry = entries[key] else { continue }
            // An update to a still-readable asset starts a refresh. Its visible
            // pixels stay on screen until the replacement arrives.
            let withdrawn = ids == nil || removed.contains(key.assetID)
            if withdrawn || demand[key, default: 2] >= 2 { entry.show(nil, cost: 0) }
            entry.complete = false; entry.localFinished = false; entry.cloudConfirmed = false
            entry.retryAt = nil; entry.retries = 0; entry.networkTime = 0
            entry.unavailable = withdrawn
            entry.setStatus(entry.unavailable ? .unavailable : .waiting)
        }
        requester.invalidate(ids)
        if ids == nil { demand = [:]; entries = [:]; timer?.cancel() }
        else { tick() }
    }

    func memoryWarning() {
        memoryConstrained = true
        update(demand.filter { $0.value < 2 }, moving: isMoving)
        for entry in entries.values where demand[entry.key] == nil { entry.show(nil, cost: 0); entry.complete = false }
        // Do not compete with visible images using speculative reservations.
        for job in Array(jobs.values).sorted(by: { demand[$0.key, default: 2] > demand[$1.key, default: 2] }) where accountedBytes > budget {
            stop(job)
        }
        for entry in entries.values.sorted(by: { demand[$0.key, default: 2] > demand[$1.key, default: 2] }) where accountedBytes > budget {
            entry.show(nil, cost: 0); entry.complete = false; entry.localFinished = false; entry.reduced = true
        }
        trim()
        tick()
    }

    private func evict(toFit addition: Int, keeping key: OverviewImageKey? = nil) {
        for entry in coldEntries where accountedBytes + addition > budget && entry.key != key {
            entry.show(nil, cost: 0); entry.complete = false; entry.localFinished = false
        }
    }

    private var coldEntries: [OverviewThumbnail] {
        entries.values.filter { demand[$0.key] == nil }.sorted { lhs, rhs in
            if lhs.key.size != rhs.key.size { return lhs.key.size == .card }
            return lhs.lastUse < rhs.lastUse
        }
    }

    private func trim() {
        evict(toFit: 0)
        var images = retainedImageCount
        for entry in coldEntries {
            if entry.image == nil || images > configuration.cacheLimit {
                if entry.image != nil { images -= 1 }
                entry.show(nil, cost: 0)
                entries.removeValue(forKey: entry.key)
            }
        }
    }

    private func scheduleWake() {
        timer?.cancel(); timer = nil
        guard automaticScheduling, !demand.isEmpty else { return }
        let date = now()
        var deadlines = jobs.values.map(\.deadline)
        if !isMoving, settleAt > date { deadlines.append(settleAt) }
        for key in demand.keys {
            if let entry = entries[key], entry.retries < 1, let retry = entry.retryAt { deadlines.append(retry) }
        }
        if demand.contains(where: { $0.value == 0 && eligible($0.key, network: true) }), lastPreemption.addingTimeInterval(configuration.preemptionDelay) > date {
            deadlines.append(lastPreemption.addingTimeInterval(configuration.preemptionDelay))
        }
        guard let next = deadlines.min() else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSince(date)))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private static func priority(_ value: Int) -> PhotoImagePriority {
        value == 0 ? .focus : value == 1 ? .visible : .prefetch
    }

    private static func imageCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage { return cg.bytesPerRow * cg.height }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 8)
    }

    isolated deinit {
        timer?.cancel()
        for job in jobs.values { requester.cancel(job.token) }
    }
}

nonisolated enum OverviewPerformance {
    private static let logger = Logger(subsystem: "com.doupi.PhotoEarth", category: "HomeScrolling")
    private static let signposter = OSSignposter(subsystem: "com.doupi.PhotoEarth", category: "HomeScrolling")
    static func event(_ name: StaticString) { signposter.emitEvent(name) }
    static func begin(_ name: StaticString) -> OSSignpostIntervalState { signposter.beginInterval(name) }
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) { signposter.endInterval(name, state) }
    static func failure(_ error: NSError) {
        logger.debug("Thumbnail failure domain=\(error.domain, privacy: .public) code=\(error.code)")
    }
}
