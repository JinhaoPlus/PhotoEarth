import Foundation
import Testing
@testable import PhotoEarth

struct VisitCoverPersistenceTests {
    private func photo(_ id: String, longitude: Double, time: Double) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: .init(latitude: 15, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: time), pixelWidth: 1800,
                         pixelHeight: 1200, isFavorite: false)
    }

    private func fixture() -> TravelIndexSnapshot {
        TravelClusterer().makeIndex(records: [
            photo("a", longitude: 10, time: 100), photo("b", longitude: 10, time: 200),
            photo("z", longitude: 90, time: 1_000)
        ])
    }

    private func record(_ asset: String, in snapshot: TravelIndexSnapshot, store: SQLiteTravelIndexStore,
                        expires: Date = .distantFuture) async throws -> String {
        let visit = try #require(snapshot.photos.first { $0.id == asset }?.placeID)
        try await store.saveVisitCover(asset, for: visit, revision: String(snapshot.index.generatedAt.timeIntervalSince1970),
                                       generation: store.visitCoverGeneration, expires: expires, excluding: [])
        return visit
    }

    @Test func savedDecisionsSurviveRestartAndDisplayedDecisionsRespectScopeAndExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let snapshot = fixture()
        try await store.save(snapshot)
        let first = try await record("a", in: snapshot, store: store)
        let second = try await record("z", in: snapshot, store: store)
        let reopened = SQLiteTravelIndexStore(databaseURL: url)
        let both = [first, second]
        let winners = try await reopened.savedVisitCovers(for: both, excluding: [])
        #expect(winners.mapValues(\.assetID) == [first: "a", second: "z"])

        // An exclusion on a challenger also changes eligibility for a fresh selection.
        #expect(try await reopened.savedVisitCovers(for: both, excluding: ["b"]).keys.sorted() == [second])
        _ = try await record("b", in: snapshot, store: reopened, expires: .distantPast)
        #expect(try await reopened.savedVisitCovers(for: [first], excluding: []).isEmpty)
        let held = [first: "a", second: "z"]
        let stillDisplayed = try await reopened.savedVisitCovers(for: [first], keeping: held, excluding: [])
        #expect(stillDisplayed.mapValues(\.assetID) == [first: "a"])
        #expect(try await reopened.savedVisitCovers(for: [first], keeping: held, excluding: ["a"]).isEmpty)
        #expect(try await reopened.savedVisitCovers(for: [first], keeping: [first: "z"], excluding: []).isEmpty)

        // Both visits are sparse and hidden when the transit filter is enabled.
        _ = try await reopened.setTransitFiltering(true)
        #expect(try await reopened.savedVisitCovers(for: both, keeping: held, excluding: []).isEmpty)
    }

    @Test func metadataIdenticalPhotoEditInvalidatesOnlyItsVisitAndFencesInFlightWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let snapshot = fixture()
        try await store.save(snapshot)
        let first = try await record("a", in: snapshot, store: store)
        let second = try await record("z", in: snapshot, store: store)
        let revision = String(snapshot.index.generatedAt.timeIntervalSince1970)
        let oldGeneration = await store.visitCoverGeneration
        let assessment = ScenicCoverAnalysis(scenery: 0.7, aesthetics: 0.2, isUtility: false, largestFace: 0)
        try await store.saveCoverAnalysis(assessment, assetID: "b", revision: revision)
        let run = try await store.beginMetadataScan(copyCurrent: true)
        // Updated pixels may have the same PhotoKit metadata, even on a cold launch.
        let edited = try #require(snapshot.photos.first { $0.id == "b" })
        #expect(try await !store.stageMetadata(.init(records: [edited]), run: run))
        _ = try await store.commitDisplayChanges(run: run, token: Data([1]), sourcePhotoCount: 3, authorization: "test")
        try await store.saveVisitCover("a", for: first, revision: revision, generation: oldGeneration,
                                       expires: .distantFuture, excluding: [])
        let visible = try await store.savedVisitCovers(for: [first, second], excluding: [])
        #expect(visible.mapValues(\.assetID) == [second: "z"])
        #expect(try await store.coverAnalyses(for: ["b"], revision: revision).isEmpty)
    }

    @Test func structuralDeltaKeepsUnrelatedVisitsAndExpelsMovedOrDeletedMembers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let snapshot = fixture()
        try await store.save(snapshot)
        let first = try await record("a", in: snapshot, store: store)
        let second = try await record("z", in: snapshot, store: store)
        let run = try await store.beginMetadataScan(copyCurrent: true)
        let added = photo("new", longitude: 10, time: 250)
        #expect(try await store.stageMetadata(.init(records: [added], removedIDs: ["b"]), run: run))
        let index = try await store.activateMetadata(run: run, sourcePhotoCount: 3, token: Data([2]), fullCheck: false,
                                                     authorization: "test", configuration: .init(), progress: { _, _ in })
        let saved = try await store.savedVisitCovers(for: index.places.map(\.id), excluding: [])
        #expect(saved.mapValues(\.assetID) == [second: "z"])
        #expect(try await store.savedVisitCovers(for: [first], keeping: [first: "b"], excluding: []).isEmpty)
        let held = try await store.savedVisitCovers(for: [first], keeping: [first: "a"], excluding: [])
        #expect(held[first]?.assetID == "a")
        let full = try await store.beginMetadataScan(copyCurrent: false)
        _ = try await store.stageMetadata(.init(records: [added]), run: full)
        _ = try await store.activateMetadata(run: full, sourcePhotoCount: 1, token: Data([3]), fullCheck: true,
                                               authorization: "test", configuration: .init(), progress: { _, _ in })
        #expect(try await store.savedVisitCovers(for: [first, second], keeping: [first: "a", second: "z"], excluding: []).isEmpty)
    }
}
