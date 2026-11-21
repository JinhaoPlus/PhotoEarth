import Foundation
import Testing
@testable import PhotoEarth

struct PhotoWallPaginationTests {
    @Test func denseExcludedFiftyThousandPhotoPageHasAHardCandidateBudget() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let coordinate = GeoCoordinate(latitude: 9, longitude: 9)
        let photos = (0..<50_000).map { photo($0, coordinate: coordinate) }
        try await store.save(snapshot(photos))

        // All 50,000 rows pass the SQL bounding box, but none pass the spherical
        // viewport. A page must yield its continuation instead of draining them.
        let viewport = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 10)
        #expect(!viewport.contains(coordinate))
        let page = try await store.photoPage(in: viewport, offset: 0, limit: 48)
        #expect(page.records.isEmpty)
        #expect(page.nextOffset == SQLiteTravelIndexStore.photoPageCandidateBudget)

        // The same actor can immediately serve a new, useful query. Even an
        // oversized requested page cannot decode more than the candidate budget.
        let included = EarthViewport(center: coordinate, angularRadius: 10)
        let next = try await store.photoPage(in: included, offset: 0, limit: Int.max)
        #expect(next.records.count == SQLiteTravelIndexStore.photoPageCandidateBudget)
        #expect(next.nextOffset == SQLiteTravelIndexStore.photoPageCandidateBudget)
        #expect(next.records.allSatisfy { included.contains($0.coordinate) })
    }

    @Test(arguments: [false, true])
    func emptyAndShortPagesPreserveStableOrderingAndEveryMatchingPhoto(crossesDateLine: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let viewport = EarthViewport(
            center: GeoCoordinate(latitude: 0, longitude: crossesDateLine ? 179 : 0),
            angularRadius: 10
        )
        let excluded = GeoCoordinate(latitude: 9, longitude: crossesDateLine ? -172 : 9)
        let photos = (0..<1_900).map { index in
            // The first page is entirely excluded. A later long excluded run
            // produces short/empty pages between two groups of real matches.
            let isIncluded = (600..<800).contains(index) && index.isMultiple(of: 2) || index == 1_800
            let longitude = crossesDateLine ? (index.isMultiple(of: 4) ? 179.0 : -179.0) : 0
            return photo(
                index,
                coordinate: isIncluded ? GeoCoordinate(latitude: 0, longitude: longitude) : excluded
            )
        }
        try await store.save(snapshot(photos))
        let expected = photos.filter { viewport.contains($0.coordinate) }.sorted(by: newestFirst)

        var offset = 0
        var loaded: [PhotoAssetRecord] = []
        var emptyPages = 0
        var shortContinuingPages = 0
        var reachedEnd = false
        for _ in 0..<100 {
            let page = try await store.photoPage(in: viewport, offset: offset, limit: 17)
            #expect(page.records.count <= 17)
            loaded.append(contentsOf: page.records)
            if page.records.isEmpty { emptyPages += 1 }
            guard let next = page.nextOffset else {
                reachedEnd = true
                break
            }
            if !page.records.isEmpty && page.records.count < 17 { shortContinuingPages += 1 }
            #expect(next > offset)
            #expect(next - offset <= SQLiteTravelIndexStore.photoPageCandidateBudget)
            offset = next
        }
        #expect(reachedEnd)
        #expect(emptyPages >= 2)
        #expect(shortContinuingPages >= 1)
        #expect(loaded == expected)
        #expect(Set(loaded.map(\.id)).count == loaded.count)
    }

    @Test func exactCandidateBudgetAndExactRecordLimitRecognizeTheEnd() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let coordinate = GeoCoordinate(latitude: 9, longitude: 9)
        let photos = (0..<SQLiteTravelIndexStore.photoPageCandidateBudget).map {
            photo($0, coordinate: coordinate)
        }
        try await store.save(snapshot(photos))
        let excluded = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 10)
        let empty = try await store.photoPage(in: excluded, offset: 0, limit: 48)
        #expect(empty.records.isEmpty)
        #expect(empty.nextOffset == nil)

        let included = EarthViewport(center: coordinate, angularRadius: 10)
        let full = try await store.photoPage(in: included, offset: -10, limit: photos.count)
        #expect(full.records == photos.sorted(by: newestFirst))
        #expect(full.nextOffset == nil)
    }

    @Test func cancelledPageThrowsCancellationAndTheStoreRemainsUsable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let coordinate = GeoCoordinate(latitude: 0, longitude: 0)
        try await store.save(snapshot((0..<10).map { photo($0, coordinate: coordinate) }))
        let viewport = EarthViewport(center: coordinate, angularRadius: 10)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.photoPage(in: viewport, offset: 0, limit: 48)
        }
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled page must not return a displayable result.")
        } catch is CancellationError {
            // A cancelled request is distinct from a corrupt or broken index.
        }
        let next = try await store.photoPage(in: viewport, offset: 0, limit: 48)
        #expect(next.records.count == 10)
        #expect(next.nextOffset == nil)
    }

    @Test func continuousCountAndPartialPagesKeepIndependentStableCursors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 179)
        let source = (0..<2_103).map { number in
            photo(number, coordinate: GeoCoordinate(latitude: 0, longitude: number.isMultiple(of: 2) ? 179 : -179))
        }
        try await store.save(snapshot(source))
        let reader = try await store.photoReadSnapshot()
        let viewport = EarthViewport(center: center, angularRadius: 10)
        let firstBatch = try await reader.photoWallCandidates(in: viewport, offset: 0)
        #expect(firstBatch.records == Array(source.prefix(512)))
        // A strict screen page consumed just 49 candidates, in the middle of a
        // same-time group. The other 463 records stay available to the wall.
        let suffix = try await reader.photoWallCandidates(in: viewport, offset: 49)
        #expect(suffix.records == Array(source[49..<512]))
        var counted = Array(firstBatch.records.prefix(49))
        var offset = 49
        repeat {
            let batch = try await reader.photoWallCountingCandidates(in: viewport, offset: offset)
            #expect(batch.records.count <= 512)
            counted.append(contentsOf: batch.records)
            // Paging back through an unconsumed batch must not reset or steal
            // the count cursor's pending lookahead row.
            let wallPage = try await reader.photoWallCandidates(in: viewport, offset: 97)
            #expect(wallPage.records.first?.id == source[97].id)
            guard let next = batch.nextOffset else { break }
            #expect(next > offset)
            offset = next
        } while offset < source.count + 1
        #expect(counted == source)
        #expect(Set(counted.map(\.id)).count == source.count)
        await reader.finishPhotoWallCounting()
    }

    @Test func pinnedCountSurvivesAnIndexReplacementAndExplicitRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let source = (0..<1_027).map { photo($0, coordinate: center) }
        try await store.save(snapshot(source))
        let reader = try await store.photoReadSnapshot()
        let viewport = EarthViewport(center: center, angularRadius: 10)
        let first = try await reader.photoWallCountingCandidates(in: viewport, offset: 0)
        try await store.save(snapshot([photo(9_999, coordinate: center)]))
        let second = try await reader.photoWallCountingCandidates(in: viewport, offset: 512)
        let last = try await reader.photoWallCountingCandidates(in: viewport, offset: 1_024)
        #expect(first.records + second.records + last.records == source)
        #expect(last.nextOffset == nil)
        _ = try await reader.photoWallCountingCandidates(in: viewport, offset: 0)
        await reader.finishPhotoWallCounting()
        let restarted = try await reader.photoWallCountingCandidates(in: viewport, offset: 513)
        #expect(restarted.records == Array(source[513..<1_025]))
        await reader.finishPhotoWallCounting()
    }

    @Test @MainActor func collectionCountTracksRemovedPhotosBeforeTheLastPage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let photos = (0..<100).map { photo($0, coordinate: center) }
        let outside = PhotoAssetRecord(id: "outside-collection", coordinate: center, creationDate: photos[0].creationDate,
                                       pixelWidth: 1_200, pixelHeight: 800, isFavorite: false, placeID: "other-visit")
        let otherVisit = TravelPlace(id: "other-visit", name: "Other", country: nil, coordinate: center,
                                     startDate: outside.creationDate, endDate: outside.creationDate,
                                     photoCount: 1, coverAssetID: outside.id)
        let base = snapshot(photos).index
        let index = TravelIndex(schemaVersion: base.schemaVersion, generatedAt: base.generatedAt,
                                sourcePhotoCount: photos.count + 1, locatedPhotoCount: photos.count + 1,
                                places: base.places + [otherVisit], journeys: [])
        try await store.save(TravelIndexSnapshot(index: index, photos: photos + [outside]))
        let app = AppModel(photoLibrary: PreparationFixtureLibrary(records: photos), indexStore: store,
                           preferencesStore: LocalPreferenceStore(), clusterer: TravelClusterer())
        let collection = try #require(PlaceCollection.recent(index.places).first { $0.id == photos[0].placeID })
        let session = CollectionPhotoWallSession()
        defer { session.cancel() }

        session.loadMore(app: app, collection: collection)
        try await waitUntil { !session.isLoading }
        #expect(session.records == Array(photos.prefix(48)))
        #expect(session.totalPhotoCount == 100)
        let nextPage = try #require(session.nextOffset)

        // Removing a photo outside the first page must affect the total too.
        session.exclude([photos[0].id, photos[85].id, outside.id, "not-in-this-snapshot"], app: app)
        #expect(session.records == Array(photos[1..<48]))
        try await waitUntil { session.totalPhotoCount != nil }
        #expect(session.totalPhotoCount == 98)
        #expect(session.nextOffset == nextPage)

        session.loadMore(app: app, collection: collection)
        try await waitUntil { !session.isLoading }
        #expect(session.records == photos[1..<96].filter { $0.id != photos[85].id })
        #expect(session.totalPhotoCount == 98)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func selectedCityIsAppliedBeforeRepresentativeSampling() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let newer = (0..<1_000).map { number in
            let value = photo(number, coordinate: center)
            return PhotoAssetRecord(id: value.id, coordinate: center, creationDate: value.creationDate,
                                    pixelWidth: 1_200, pixelHeight: 800, isFavorite: true, placeID: "other-city")
        }
        let older = (1_000..<1_008).map { photo($0, coordinate: center) }
        var fixture = snapshot(newer + older)
        let date = Date(timeIntervalSince1970: 1_700_100_000)
        let other = TravelPlace(id: "other-city", name: "Other", country: nil, coordinate: center,
                                startDate: date, endDate: date, photoCount: newer.count, coverAssetID: newer[0].id)
        fixture = TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
                                      generatedAt: date, sourcePhotoCount: newer.count + older.count,
                                      locatedPhotoCount: newer.count + older.count,
                                      places: fixture.index.places + [other], journeys: []), photos: newer + older)
        try await store.save(fixture)
        let viewport = EarthViewport(center: center, angularRadius: 10)
        let city = try await store.photos(in: viewport, limit: 144, placeIDs: ["synthetic-place"])
        #expect(Set(city.map(\.id)) == Set(older.map(\.id)))
        #expect(city.allSatisfy { $0.placeID == "synthetic-place" })
        #expect(try await store.photos(in: viewport, limit: 144, placeIDs: []).isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-wall-pages-\(UUID().uuidString)")
    }

    private func newestFirst(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Bool {
        if lhs.creationDate == rhs.creationDate { return lhs.id < rhs.id }
        return lhs.creationDate > rhs.creationDate
    }

    private func photo(_ index: Int, coordinate: GeoCoordinate) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: String(format: "synthetic-%06d", index),
            coordinate: coordinate,
            // Ties intentionally exercise id ASC within creation_date DESC.
            creationDate: Date(timeIntervalSince1970: 1_700_100_000 - Double(index / 8)),
            pixelWidth: 1_200,
            pixelHeight: 800,
            isFavorite: false,
            placeID: "synthetic-place"
        )
    }

    private func snapshot(_ photos: [PhotoAssetRecord]) -> TravelIndexSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_100_000)
        let place = TravelPlace(
            id: "synthetic-place", name: "Synthetic", country: nil,
            coordinate: photos[0].coordinate, startDate: date, endDate: date,
            photoCount: photos.count, coverAssetID: photos[0].id
        )
        return TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: date, sourcePhotoCount: photos.count, locatedPhotoCount: photos.count,
                places: [place], journeys: []
            ),
            photos: photos
        )
    }
}
