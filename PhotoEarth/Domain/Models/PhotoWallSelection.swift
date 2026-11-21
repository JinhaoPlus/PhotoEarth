import Foundation
import os

nonisolated enum PhotoWallSelectionError: LocalizedError {
    case unavailableViewport, changedViewport, changedCollection

    var errorDescription: String? {
        switch self {
        case .unavailableViewport: AppLocalization.string("error.wall.viewport_unavailable", defaultValue: "This map view is not ready. Return to the globe and try again.")
        case .changedViewport: AppLocalization.string("error.wall.viewport_changed", defaultValue: "The map view changed. Return to the globe and select the area again.")
        case .changedCollection: AppLocalization.string("error.wall.collection_changed", defaultValue: "This place was updated. Return to the place list and open it again.")
        }
    }
}

/// Consumes raw, stably ordered spatial candidates. The offset counts examined
/// candidates, including offscreen rows; never discard an unconsumed match at
/// a page boundary or reuse the memory strip's small representative sample.
nonisolated enum PhotoWallPageSelection {
    static let pageSize = 48
    static let candidateLimit = 512

    @MainActor static func page(from candidates: PhotoQueryPage, offset: Int, limit: Int,
                               snapshot: PhotoViewportSnapshot) async throws -> PhotoQueryPage {
        try Task.checkCancellation()
        guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        guard limit > 0 else { return PhotoQueryPage(records: [], nextOffset: nil) }
        var records: [PhotoAssetRecord] = []
        var examined = 0
        let interval = PhotoWallPerformance.begin("WallPageSelection")
        defer { PhotoWallPerformance.end("WallPageSelection", interval, records: examined) }
        var slice = PhotoWallProjectionSlice()
        slice.restart()
        defer { slice.finish() }
        for photo in candidates.records.prefix(candidateLimit) {
            try Task.checkCancellation()
            try await slice.yieldIfNeeded(snapshot: snapshot)
            examined += 1
            if snapshot.containsForPhotoWall(photo.coordinate) {
                records.append(photo)
                if records.count == min(limit, pageSize) { break }
            }
        }
        guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        let hasMore = examined < candidates.records.count || candidates.nextOffset != nil
        return PhotoQueryPage(records: records, nextOffset: hasMore ? max(0, offset) + examined : nil)
    }
}

/// Counts every photo accepted by the frozen native map projection without
/// retaining the whole wall in memory. Callers can seed this with the first
/// displayed page, then continue from that page's candidate offset.
nonisolated enum PhotoWallTotalSelection {
    @MainActor static func count(
        startingAt initialOffset: Int = 0,
        initialCount: Int = 0,
        snapshot: PhotoViewportSnapshot,
        excluding excludedAssetIDs: Set<String> = [],
        scheduling: PhotoWallCountScheduling? = nil,
        candidatesAt: (Int) async throws -> PhotoQueryPage
    ) async throws -> Int {
        var offset = max(0, initialOffset)
        var total = max(0, initialCount)
        let interval = PhotoWallPerformance.begin("WallExactCount")
        defer { PhotoWallPerformance.end("WallExactCount", interval, records: total) }
        var slice = PhotoWallProjectionSlice()
        defer { slice.finish() }

        while true {
            try Task.checkCancellation()
            guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
            try await scheduling?.waitUntilReady()
            let page = try await candidatesAt(offset)
            try await scheduling?.waitUntilReady()
            guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
            slice.restart()
            for photo in page.records.prefix(PhotoWallPageSelection.candidateLimit) {
                try Task.checkCancellation()
                try await slice.yieldIfNeeded(snapshot: snapshot, scheduling: scheduling)
                if !excludedAssetIDs.contains(photo.id), snapshot.containsForPhotoWall(photo.coordinate) {
                    total += 1
                }
            }
            slice.finish()
            guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
            guard let nextOffset = page.nextOffset else { return total }
            guard nextOffset > offset else { throw PhotoWallSelectionError.unavailableViewport }
            offset = nextOffset
            await Task.yield()
        }
    }
}

/// Exact counting is background UI work. A detail view or a page request can
/// pause it without discarding its SQL cursor or any accumulated exact count.
@MainActor
final class PhotoWallCountScheduling {
    enum PauseReason: Hashable { case detail, page, mapReview }
    private var pauseReasons: Set<PauseReason> = []
    private var resumeAfter = ContinuousClock.now

    func setPaused(_ paused: Bool, for reason: PauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
    }

    func deferForInteraction() {
        resumeAfter = ContinuousClock.now.advanced(by: .milliseconds(180))
    }

    func waitUntilReady() async throws {
        while !pauseReasons.isEmpty || ContinuousClock.now < resumeAfter {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(24))
        }
        try Task.checkCancellation()
    }
}

/// The database budget remains 512 records; native projection yields on elapsed
/// time as well, since a record count does not bound MapKit's main-thread cost.
@MainActor
private struct PhotoWallProjectionSlice {
    private var began = ContinuousClock.now
    private var interval: OSSignpostIntervalState?

    mutating func restart() {
        finish()
        began = .now
        interval = PhotoWallPerformance.begin("WallProjectionSlice")
    }

    mutating func finish() {
        PhotoWallPerformance.end("WallProjectionSlice", interval)
        interval = nil
    }

    mutating func yieldIfNeeded(snapshot: PhotoViewportSnapshot,
                                scheduling: PhotoWallCountScheduling? = nil) async throws {
        guard began.duration(to: .now) >= .milliseconds(3) else { return }
        guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        finish()
        await Task.yield()
        try await scheduling?.waitUntilReady()
        try Task.checkCancellation()
        guard snapshot.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
        restart()
    }
}

/// Instruments-only stages and aggregate counts. No asset IDs, geographic
/// coordinates, place names, or error payloads enter these signposts.
nonisolated enum PhotoWallPerformance {
    private static let signposter = OSSignposter(subsystem: "com.doupi.PhotoEarth", category: "PhotoWall")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?, records: Int? = nil) {
        guard let state else { return }
        if let records {
            signposter.endInterval(name, state, "records=\(records, privacy: .public)")
        } else {
            signposter.endInterval(name, state)
        }
    }
}
