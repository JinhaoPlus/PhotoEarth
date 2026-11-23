import Foundation
import SQLite3
import Testing
@testable import PhotoEarth

@Suite(.serialized)
@MainActor
struct TransitFilteringTests {
    private func photo(_ id: String, longitude: Double = 0, time: Double = 0, favorite: Bool = false,
                       altitude: Double? = nil, horizontal: Double? = nil, vertical: Double? = nil) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: GeoCoordinate(latitude: 0, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: 1_700_000_000 + time),
                         pixelWidth: 1600, pixelHeight: 1000, isFavorite: favorite,
                         altitudeMeters: altitude, horizontalAccuracyMeters: horizontal, verticalAccuracyMeters: vertical)
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    }

    @Test func sparseVisitsProtectFavoritesAndLongerSpans() {
        let classifier = TransitPhotoClassifier()
        let start = Date(timeIntervalSince1970: 0)
        #expect(classifier.isSparseVisit(count: 1, start: start, end: start, hasFavorite: false))
        #expect(classifier.isSparseVisit(count: 2, start: start, end: start.addingTimeInterval(1800), hasFavorite: false))
        #expect(!classifier.isSparseVisit(count: 2, start: start, end: start.addingTimeInterval(1801), hasFavorite: false))
        #expect(!classifier.isSparseVisit(count: 3, start: start, end: start, hasFavorite: false))
        #expect(!classifier.isSparseVisit(count: 1, start: start, end: start, hasFavorite: true))
    }

    @Test func fastMiddlePhotosNeedTwoCredibleLegsAndAltitudeNeverActsAlone() {
        let classifier = TransitPhotoClassifier()
        let a = photo("a"), b = photo("b", longitude: 5, time: 3600), c = photo("c", longitude: 10, time: 7200)
        #expect(classifier.reason(previous: a, current: b, next: c) == .fastTransit)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 3600, altitude: 10_000, vertical: 20), next: c) == .highAltitudeFastTransit)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 3600, favorite: true), next: c) == nil)
        #expect(classifier.reason(previous: a, current: b, next: photo("c", time: 7200)) == nil) // GPS out-and-back
        #expect(classifier.reason(previous: a, current: b, next: photo("c", longitude: 5.1, time: 7200)) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", time: 3600, altitude: 10_000, vertical: 20), next: photo("c", time: 7200)) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 3600, horizontal: 2000), next: c) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 3600, altitude: 10_000, vertical: -1), next: c) == .fastTransit)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 0), next: c) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 5, time: 10), next: c) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 50, time: 3600), next: c) == nil)
        #expect(classifier.reason(previous: a, current: photo("b", longitude: 50, time: 7 * 3600), next: photo("c", longitude: 100, time: 14 * 3600)) == nil)
        #expect(classifier.reason(previous: photo("a", longitude: 179), current: photo("b", longitude: -176, time: 3600), next: photo("c", longitude: -171, time: 7200)) == .fastTransit)
    }

    @Test func allReadPathsFilterAndToggleRestoresOriginalMembership() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        let records = [photo("stay-1"), photo("stay-2", time: 60), photo("stay-3", time: 120),
                       photo("pass", longitude: 1, time: 3600), photo("favorite", longitude: 2, time: 7200, favorite: true)]
        let original = TravelClusterer().makeIndex(records: records)
        try await store.save(original)
        let filtered = try #require(try await store.load())
        #expect(filtered.locatedPhotoCount == 5 && filtered.visiblePhotoCount == 4 && filtered.hiddenTransitPhotoCount == 1)
        #expect(filtered.places.count == 2)
        let allIDs = original.index.places.map(\.id)
        let wall = try await store.photoPage(for: allIDs, offset: 0, limit: 48)
        #expect(!wall.records.contains { $0.id == "pass" })
        let day = records[0].creationDate..<records[4].creationDate.addingTimeInterval(1)
        #expect(wall.records.count == 4)
        #expect(try await store.anniversaryPage(in: day, excluding: [], offset: 0).records == wall.records.sorted(by: SlideshowOrdering.recordComesFirst))
        let hiddenPlace = try #require(original.photos.first { $0.id == "pass" }?.placeID)
        #expect(try await store.assetIDs(for: hiddenPlace, offset: 0, limit: 48).isEmpty)
        #expect(try await store.latestAssetID(for: hiddenPlace) == nil)
        #expect(try await store.latestPhotoPreviews(for: [hiddenPlace]).isEmpty)
        let session = try await store.photoReadSnapshot().slideshowSnapshot(for: nil, excluding: [])
        #expect(!session.visitIDs().contains(hiddenPlace))
        let viewport = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 1), angularRadius: 30)
        #expect(!(try await store.photos(in: viewport, limit: 144)).contains { $0.id == "pass" })
        #expect(!(try await store.photoWallCandidates(in: viewport, offset: 0).records).contains { $0.id == "pass" })
        #expect(!(try await store.photoWallCountingCandidates(in: viewport, offset: 0).records).contains { $0.id == "pass" })
        let pinned = try await store.photoReadSnapshot()
        let restored = try #require(try await store.setTransitFiltering(false))
        #expect(restored.places == original.index.places && restored.hiddenTransitPhotoCount == 0)
        #expect(try await store.photoPage(for: allIDs, offset: 0, limit: 48).records.count == 5)
        #expect(try await pinned.photoPage(for: allIDs, offset: 0, limit: 48).records.count == 4)
        #expect(try await store.setTransitFiltering(true)?.places.count == 2)
    }

    @Test func streamingActivationAndFavoriteOnlyEditsReclassifyWithoutLosingAltitude() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        let first = photo("single", altitude: 4500, horizontal: 10, vertical: 20)
        let run = try await store.beginMetadataScan(copyCurrent: false)
        _ = try await store.stageMetadata(.init(records: [first]), run: run)
        let hidden = try await store.activateMetadata(run: run, sourcePhotoCount: 1, token: Data(), fullCheck: true,
                                                     authorization: "authorized", configuration: .init(), progress: { _, _ in })
        #expect(hidden.places.isEmpty && hidden.hiddenTransitPhotoCount == 1 && hidden.locatedPhotoCount == 1)
        let secondRun = try await store.beginMetadataScan(copyCurrent: true)
        let favorite = photo("single", favorite: true, altitude: 4500, horizontal: 10, vertical: 20)
        #expect(try await !store.stageMetadata(.init(records: [favorite]), run: secondRun))
        let shown = try #require(try await store.commitDisplayChanges(run: secondRun, token: Data(), sourcePhotoCount: 1, authorization: "authorized"))
        #expect(shown.places.count == 1 && shown.hiddenTransitPhotoCount == 0)
        let loaded = try await store.photoPage(for: shown.places.map(\.id), offset: 0, limit: 48).records.first
        #expect(loaded?.altitudeMeters == 4500 && loaded?.horizontalAccuracyMeters == 10 && loaded?.verticalAccuracyMeters == 20)
        let thirdRun = try await store.beginMetadataScan(copyCurrent: true)
        _ = try await store.stageMetadata(.init(records: [first]), run: thirdRun)
        #expect(try await store.commitDisplayChanges(run: thirdRun, token: Data(), sourcePhotoCount: 1, authorization: "authorized")?.hiddenTransitPhotoCount == 1)
    }

    @Test func highSpeedFilteringKeepsEndpointsAndUpdatesPartialVisitSummary() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        // Deliberately one visit with many photos: speed filtering must not depend on sparse visits.
        let source = (0..<5).map { photo("flight-\($0)", longitude: Double($0) * 5, time: Double($0) * 3600) }
        let place = TravelPlace(id: "flight", name: "", country: nil, coordinate: source[0].coordinate,
                                startDate: source[0].creationDate, endDate: source[4].creationDate, photoCount: 5, coverAssetID: source[2].id)
        let records = source.map { record in var record = record; record.placeID = place.id; return record }
        try await store.save(TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(),
            sourcePhotoCount: 5, locatedPhotoCount: 5, places: [place], journeys: []), photos: records))
        let index = try #require(try await store.load())
        #expect(index.hiddenTransitPhotoCount == 3)
        #expect(index.places.first?.photoCount == 2 && index.places.first?.coverAssetID == "flight-4")
        #expect(try await store.photoPage(for: [place.id], offset: 0, limit: 48).records.map(\.id) == ["flight-4", "flight-0"])
    }

    @Test func fiftyThousandRowsStayPagedAndDeterministic() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        let records = (0..<50_000).map { photo("p-\($0)", time: Double($0)) } + [photo("pass", longitude: 5, time: 60_000)]
        try await store.save(TravelClusterer().makeIndex(records: records))
        let first = try #require(try await store.load())
        #expect(first.visiblePhotoCount == 50_000 && first.hiddenTransitPhotoCount == 1)
        let page = try await store.photoPage(for: first.places.map(\.id), offset: 0, limit: 1000)
        #expect(page.records.count == 48 && page.nextOffset == 48)
        let next = try await store.photoPage(for: first.places.map(\.id), offset: 48, limit: 48)
        #expect(Set(page.records.map(\.id)).isDisjoint(with: next.records.map(\.id)))
        let reopened = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        #expect(try await reopened.load() == first)
    }

    @Test func equalHiddenCountsStillRefreshTheGlobeAfterFavoriteChanges() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        let originals = [photo("a", favorite: true), photo("b", longitude: 10, time: 100_000)]
        try await store.save(TravelClusterer().makeIndex(records: originals))
        let before = try #require(try await store.load())
        let overview = OverviewContentModel(latestCovers: { _ in [:] })
        overview.receive(before)
        #expect(overview.recent.map(\.id) == before.places.map(\.id))
        let run = try await store.beginMetadataScan(copyCurrent: true)
        _ = try await store.stageMetadata(.init(records: [photo("a"), photo("b", longitude: 10, time: 100_000, favorite: true)]), run: run)
        let after = try #require(try await store.commitDisplayChanges(run: run, token: Data(), sourcePhotoCount: 2, authorization: "authorized"))
        #expect(before.hiddenTransitPhotoCount == after.hiddenTransitPhotoCount)
        #expect(before.generatedAt == after.generatedAt && before.contentRevision != after.contentRevision)
        overview.receive(after)
        #expect(overview.recent.map(\.id) == after.places.map(\.id))
        #expect(before.places.map(\.id) != after.places.map(\.id))
        let restored = try #require(try await store.setTransitFiltering(false))
        overview.receive(restored)
        #expect(overview.recent.count == 2)
        let active = try #require(try await store.setTransitFiltering(true))
        overview.receive(active)
        #expect(overview.recent.count == 1)
    }

    @Test func unchangedMetadataCheckKeepsClassificationAndContentRevision() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        try await store.save(TravelClusterer().makeIndex(records: [photo("single")]))
        let before = try #require(try await store.load())
        let run = try await store.beginMetadataScan(copyCurrent: true)
        let after = try #require(try await store.commitDisplayChanges(run: run, token: Data(), sourcePhotoCount: 1, authorization: "authorized"))
        #expect(after == before)
    }

    @Test func versionFiveUpgradePreservesRawIndexAndLabels() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let source = TravelClusterer().makeIndex(records: [photo("old")])
        var index = source.index
        index.places[0].name = "Existing city"
        index.places[0].country = "Existing country"
        let snapshot = TravelIndexSnapshot(index: index, photos: source.photos)
        try await store.save(snapshot)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE metadata SET value='5' WHERE key='schema_version'; DROP TABLE transit_hidden; DROP TABLE transit_place_summaries; DROP TABLE transit_state;", nil, nil, nil) == SQLITE_OK)
        for table in ["photos", "scan_photos"] {
            for column in ["altitude", "horizontal_accuracy", "vertical_accuracy"] {
                #expect(sqlite3_exec(db, "ALTER TABLE \(table) DROP COLUMN \(column)", nil, nil, nil) == SQLITE_OK)
            }
        }
        let upgraded = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        #expect(try await upgraded.load()?.hiddenTransitPhotoCount == 1)
        let raw = try #require(try await upgraded.setTransitFiltering(false))
        #expect(raw.schemaVersion == 6 && raw.places.first?.name == "Existing city")
        #expect(try await upgraded.photoPage(for: raw.places.map(\.id), offset: 0, limit: 48).records.first?.id == "old")
    }
}
