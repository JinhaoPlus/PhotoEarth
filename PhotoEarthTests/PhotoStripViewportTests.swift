import Foundation
import Testing
@testable import PhotoEarth

struct PhotoStripViewportTests {
    @Test @MainActor func screenFilteringPrecedesFinalSelectionAndNeverFillsFromOutside() async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let viewport = EarthViewport(center: .init(latitude: 0, longitude: 0), angularRadius: 40)
        let offscreen = (0..<40).map { photo("off-\($0)", longitude: 1) }
        let onscreen = (0..<3).map { photo("on-\($0)", longitude: -10) }
        var requestedLimit = 0
        model.activate(initialCenter: viewport.center) { _, limit in
            requestedLimit = limit
            return offscreen + onscreen
        }
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: viewport, isCurrent: { true }, containsCoordinate: { $0.longitude < 0 }
        ))
        #expect(!model.photoBatchReady && model.visiblePhotos.isEmpty)
        try await waitUntil { model.photoBatchReady }
        #expect(requestedLimit == MemoryPhotoSelection.candidateLimit)
        #expect(Set(model.visiblePhotos.map(\.id)) == Set(onscreen.map(\.id)))
        #expect(model.visiblePhotos.count == 3)
    }

    @Test @MainActor func nearbyCacheReuseRechecksTheNewScreenAndMovementNeverRestoresOldPhotos() async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let viewport = EarthViewport(center: .init(latitude: 0, longitude: 0), angularRadius: 40)
        let a = photo("still-visible", longitude: 0)
        let b = photo("left-the-screen", longitude: 1)
        var queryCount = 0
        model.activate(initialCenter: viewport.center) { _, _ in
            queryCount += 1
            return [a, b]
        }
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true }
        ))
        try await waitUntil { model.photoBatchReady }
        #expect(model.visiblePhotos.count == 2)

        let nearby = EarthViewport(center: .init(latitude: 0, longitude: 0.1), angularRadius: 40)
        #expect(!nearby.differsMeaningfully(from: viewport))
        model.transitionCamera(to: nearby.center, distance: model.camera.distance, animated: false)
        #expect(!model.isManipulating, "A synchronous camera move is already stationary")
        #expect(!model.photoBatchReady && model.visiblePhotos.isEmpty,
                "Stationary must not imply the old batch is current")
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: nearby, isCurrent: { true }, containsCoordinate: { $0.longitude < 0.5 }
        ))
        #expect(!model.photoBatchReady && model.visiblePhotos.isEmpty)
        try await waitUntil { model.photoBatchReady }
        #expect(queryCount == 1, "A nearby view can reuse metadata but must revalidate its screen bounds")
        #expect(model.visiblePhotos.map(\.id) == [a.id])

        model.receiveViewport(PhotoViewportSnapshot(
            viewport: nearby, isCurrent: { true }, containsCoordinate: { _ in false }
        ))
        try await waitUntil { model.photoBatchReady }
        #expect(queryCount == 1)
        #expect(model.visiblePhotos.isEmpty, "An empty view must never fall back to the previous batch")
        model.pauseDirectManipulation()
        #expect(!model.photoBatchReady)
    }

    @Test(arguments: [false, true]) @MainActor
    func lateResultsCannotPublishAfterTheCameraOrNativeProjectionChanges(nativeProjectionOnly: Bool) async throws {
        let model = GlobeExperienceModel()
        let gate = PhotoCandidateGate()
        defer { model.deactivate() }
        let viewport = EarthViewport(center: .init(latitude: 0, longitude: 0), angularRadius: 40)
        var projectionIsCurrent = true
        model.activate(initialCenter: viewport.center) { _, _ in await gate.query() }
        model.receiveViewport(PhotoViewportSnapshot(
            viewport: viewport, isCurrent: { projectionIsCurrent }, containsCoordinate: { _ in true }
        ))
        try await waitUntil { await gate.isWaiting }
        let previousRevision = model.settleRevision
        if nativeProjectionOnly {
            projectionIsCurrent = false
        } else {
            model.transitionCamera(to: .init(latitude: 0, longitude: 20),
                                   distance: model.camera.distance, animated: false)
        }
        await gate.complete(with: [photo("expired", longitude: 0)])
        try await Task.sleep(for: .milliseconds(80))
        #expect(!model.photoBatchReady && model.visiblePhotos.isEmpty)
        if nativeProjectionOnly {
            #expect(model.settleRevision == previousRevision + 1,
                    "A native projection change must request a fresh snapshot")
        }
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<160 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Photo batch did not complete within the bounded debounce window")
    }

    private func photo(_ id: String, longitude: Double) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: .init(latitude: 0, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: 1_000),
                         pixelWidth: 4_000, pixelHeight: 3_000, isFavorite: false)
    }
}

private actor PhotoCandidateGate {
    private var continuation: CheckedContinuation<[PhotoAssetRecord], Never>?
    var isWaiting: Bool { continuation != nil }

    func query() async -> [PhotoAssetRecord] {
        await withCheckedContinuation { continuation = $0 }
    }

    func complete(with photos: [PhotoAssetRecord]) {
        continuation?.resume(returning: photos)
        continuation = nil
    }
}
