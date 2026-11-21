import Foundation
import Testing
@testable import PhotoEarth

@MainActor
struct PhotoViewportSnapshotTests {
    @Test func currentSnapshotRequiresBothViewportAndProjectionVisibility() throws {
        let viewport = EarthViewport(
            center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 10
        )
        let snapshot = PhotoViewportSnapshot(
            viewport: viewport,
            isCurrent: { true },
            containsCoordinate: { $0.latitude >= 0 }
        )
        let candidates = [
            photo("visible-first", latitude: 1, longitude: 1),
            photo("outside-viewport", latitude: 20),
            photo("outside-projection", latitude: -1),
            photo("visible-last", latitude: 2, longitude: 2),
        ]

        let visible = try #require(snapshot.visibleCandidates(from: candidates))

        #expect(visible.map(\.id) == ["visible-first", "visible-last"])
    }

    @Test func expiredSnapshotReturnsNilWithoutEvaluatingProjection() {
        var projectionCalls = 0
        let snapshot = PhotoViewportSnapshot(
            viewport: viewport,
            isCurrent: { false },
            containsCoordinate: { _ in
                projectionCalls += 1
                return true
            }
        )

        #expect(snapshot.visibleCandidates(from: [photo("otherwise-visible")]) == nil)
        #expect(snapshot.visibleCandidates(from: []) == nil)
        #expect(projectionCalls == 0)
    }

    @Test func rejectedPrefixDoesNotRefillFromBeyondTheCandidateBudget() throws {
        var projectedLongitudes: [Double] = []
        let snapshot = PhotoViewportSnapshot(
            viewport: viewport,
            isCurrent: { true },
            containsCoordinate: { coordinate in
                projectedLongitudes.append(coordinate.longitude)
                return coordinate.longitude > 0
            }
        )
        let rejectedPrefix = (0..<MemoryPhotoSelection.candidateLimit).map {
            photo("rejected-\($0)", longitude: -1)
        }
        let matchingTail = (0...MemoryPhotoSelection.resultLimit).map {
            photo("out-of-budget-\($0)", longitude: 1)
        }

        let visible = try #require(snapshot.visibleCandidates(from: rejectedPrefix + matchingTail))

        // A valid snapshot with no visible budgeted candidates is an empty
        // result; it must remain distinct from the nil invalidation result.
        #expect(visible.isEmpty)
        #expect(projectedLongitudes.count == MemoryPhotoSelection.candidateLimit)
        #expect(projectedLongitudes.allSatisfy { $0 == -1 })
    }

    @Test func lastBudgetedCandidateIsEligibleAndTheFollowingCandidateIsNot() throws {
        var projectionCalls = 0
        let snapshot = PhotoViewportSnapshot(
            viewport: viewport,
            isCurrent: { true },
            containsCoordinate: { coordinate in
                projectionCalls += 1
                return coordinate.longitude > 0
            }
        )
        let rejected = (0..<(MemoryPhotoSelection.candidateLimit - 1)).map {
            photo("rejected-\($0)", longitude: -1)
        }
        let candidates = rejected + [
            photo("last-budgeted", longitude: 1),
            photo("first-out-of-budget", longitude: 2),
        ]

        let visible = try #require(snapshot.visibleCandidates(from: candidates))

        #expect(visible.map(\.id) == ["last-budgeted"])
        #expect(projectionCalls == MemoryPhotoSelection.candidateLimit)
    }

    @Test func exactWallProjectionCacheIsBoundedAndBelongsToOneSnapshot() {
        var calls = 0
        let coordinate = GeoCoordinate(latitude: 0, longitude: 1)
        let adjacent = GeoCoordinate(latitude: 0, longitude: Double(1).nextUp)
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: {
            calls += 1
            return $0.longitude <= 1
        })
        #expect(snapshot.containsForPhotoWall(coordinate))
        #expect(snapshot.containsForPhotoWall(coordinate))
        #expect(!snapshot.containsForPhotoWall(adjacent))
        #expect(calls == 2, "Adjacent doubles cannot share an approximate geographic grid key")
        for number in 0..<2_000 {
            _ = snapshot.containsForPhotoWall(GeoCoordinate(latitude: 0, longitude: Double(number) / 1_000))
        }
        #expect(snapshot.cachedWallProjectionCount == 1_024)
        let other = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in false })
        #expect(!other.containsForPhotoWall(coordinate))
        #expect(other.cachedWallProjectionCount == 1)
    }

    @Test func countHonorsIndependentPauseReasonsAndResumesWithoutLosingMatches() async throws {
        let gate = PhotoWallCountScheduling()
        gate.setPaused(true, for: .detail)
        gate.setPaused(true, for: .page)
        var reads = 0
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true })
        let task = Task { @MainActor in
            try await PhotoWallTotalSelection.count(snapshot: snapshot, scheduling: gate) { offset in
                reads += 1
                return PhotoQueryPage(records: [photo("photo-\(offset)")], nextOffset: offset == 0 ? 1 : nil)
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(reads == 0)
        gate.setPaused(false, for: .page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reads == 0, "A completed page cannot resume counting under an open detail")
        gate.setPaused(false, for: .detail)
        #expect(try await task.value == 2)
        #expect(reads == 2)
    }

    @Test func slowNativeProjectionYieldsBeforeAnEntireCandidateBatch() async throws {
        var current = true
        var projected = 0
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { current }, containsCoordinate: { _ in
            projected += 1
            if projected == 1 { Task { @MainActor in current = false } }
            // Synthetic per-coordinate work exercises elapsed-time scheduling;
            // this is not a MapKit or Apple TV performance measurement.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(1))
            while ContinuousClock.now < deadline {}
            return true
        })
        let candidates = (0..<512).map { photo("slow-\($0)", longitude: Double($0) / 1_000) }
        await #expect(throws: PhotoWallSelectionError.self) {
            try await PhotoWallTotalSelection.count(snapshot: snapshot) { _ in
                PhotoQueryPage(records: candidates, nextOffset: nil)
            }
        }
        #expect(projected > 0 && projected < 512,
                "The queued MainActor invalidation must run inside a SQL batch")
    }

    @Test func pausedCountCancelsPromptlyWithoutReadingTheDatabase() async throws {
        let gate = PhotoWallCountScheduling()
        gate.setPaused(true, for: .detail)
        var reads = 0
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true })
        let task = Task { @MainActor in
            try await PhotoWallTotalSelection.count(snapshot: snapshot, scheduling: gate) { _ in
                reads += 1
                return PhotoQueryPage(records: [], nextOffset: nil)
            }
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 0)
    }

    private var viewport: EarthViewport {
        EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 10)
    }

    private func photo(
        _ id: String, latitude: Double = 0, longitude: Double = 0
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: id,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            isFavorite: false
        )
    }
}
