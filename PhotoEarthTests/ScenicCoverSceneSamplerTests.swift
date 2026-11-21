import Foundation
import Testing
@testable import PhotoEarth

@MainActor
struct ScenicCoverSceneSamplerTests {
    private func photo(_ id: String, _ time: Double, longitude: Double = 0,
                       accuracy: Double? = nil, kind: PhotoMediaKind = .photo) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: .init(latitude: 0, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: time), pixelWidth: 1200, pixelHeight: 900,
                         isFavorite: false, mediaKind: kind, placeID: "visit", horizontalAccuracyMeters: accuracy)
    }

    @Test func rapidShootingCountsOnceEvenWhenItContinuesForMinutes() {
        let burst = (0..<360).map { photo("burst-\($0)", Double($0)) }
        let standalone = photo("different-scene", 180, longitude: 0.005)
        let sampler = ScenicCoverSceneSampler(photos: burst + [standalone])
        #expect(sampler.strength(for: burst[0].id) == 0)
        #expect(sampler.strength(for: standalone.id) == 0)
        #expect(sampler.primaries(from: [standalone]) == [standalone])
    }

    @Test func pauseAndCredibleMovementContributeCappedIndependentEventsAcrossTheDateLine() {
        let first = photo("first", 0, longitude: 179.9999, accuracy: 4)
        let uncertain = photo("uncertain", 20, longitude: -179.9996, accuracy: 100)
        let moved = photo("moved", 40, longitude: -179.9996, accuracy: 4)
        let paused = photo("paused", 200, longitude: -179.9996, kind: .video)
        let examples = [first, uncertain, moved, paused]
        #expect(ScenicCoverSceneSampler(photos: [first, uncertain]).strength(for: first.id) == 0)
        let sampler = ScenicCoverSceneSampler(photos: examples.reversed())
        #expect(sampler.strength(for: first.id) == 0.4)
        #expect(sampler.strength(for: paused.id) == 0.4)
        #expect(sampler.primaries(from: []).allSatisfy { $0.mediaKind != .video })
        let subsequent = (2..<15).map { photo("repeat-\($0)", Double($0 * 130), longitude: 179.9999) }
        #expect(ScenicCoverSceneSampler(photos: examples + subsequent).strength(for: first.id) == 1)
    }

    @Test func densityProtectsTemporalCoverageAndCannotConsumeTwoTailSlotsAtOnce() {
        let dispersed = (0..<24).map { photo("single-\($0)", Double($0 * 150), longitude: Double($0) * 0.01) }
        let squeeze = [photo("in-between", 2775, longitude: 10), photo("evidence", 2800, longitude: 10.0006, kind: .video)]
        let additional = [photo("palace", 4000, longitude: 20), photo("other-angle", 4125, longitude: 20.0001)]
        let sampler = ScenicCoverSceneSampler(photos: dispersed + squeeze + additional)
        let selected = sampler.primaries(from: dispersed)
        #expect(Array(selected.prefix(18)) == Array(dispersed.prefix(18)))
        #expect(selected.count == 24)
        #expect(Set(selected.map(\.id)).count == 24)
        #expect(selected.contains { $0.id == "palace" || $0.id == "other-angle" })
        #expect(sampler.strength(for: "in-between") > 0)
        let times = selected.map(\.creationDate).sorted()
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 120 })
        let noOtherAddition = ScenicCoverSceneSampler(photos: dispersed + squeeze)
        #expect(noOtherAddition.primaries(from: dispersed) == dispersed)
    }

    @Test func sqliteReusesOnlyEligibleSceneEvidenceAndInvalidatesItAfterReplacingTheVisit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let single = photo("single", 0), many = photo("many", 500, longitude: 2)
        let video = photo("video", 650, longitude: 2, kind: .video)
        let records = [single, many, video]
        let place = TravelPlace(id: "visit", name: "City", country: nil, coordinate: single.coordinate,
                                startDate: single.creationDate, endDate: video.creationDate, photoCount: 3, coverAssetID: nil)
        func snapshot(_ rows: [PhotoAssetRecord]) -> TravelIndexSnapshot {
            .init(index: .init(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 1000),
                               sourcePhotoCount: rows.count, locatedPhotoCount: rows.count, places: [place], journeys: []),
                  photos: rows)
        }
        try await store.save(snapshot(records))
        let dispersed = try await store.scenicCoverCandidates(for: [place])
        let city = try await store.scenicCoverCandidates(for: [place], priorityVisitID: place.id)
        #expect(city == ScenicCoverSceneSampler(photos: records).primaries(from: dispersed))
        #expect(!city.contains { $0.mediaKind == .video })
        #expect(try await store.sceneStrengths(for: city, excluding: []) == [single.id: 0, many.id: 0.2])
        #expect(try await store.sceneStrengths(for: [many], excluding: [video.id]) == [many.id: 0])
        #expect(try await store.sceneStrengths(for: [many], excluding: []) == [many.id: 0.2])
        try await store.save(snapshot([single, many]))
        #expect(try await store.sceneStrengths(for: [many], excluding: []) == [many.id: 0])
    }
}
