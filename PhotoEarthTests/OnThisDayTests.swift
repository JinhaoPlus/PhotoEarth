import Foundation
import Testing
@testable import PhotoEarth

struct OnThisDayTests {
    @Test func localDatesIncludeThisYearAndNeverMoveLeapDayIntoMarch() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
            try #require(cal.date(from: DateComponents(year: y, month: m, day: d)))
        }
        #expect(cal.anniversaryDate(month: 2, day: 29, year: 2025) == nil)
        #expect(cal.anniversaryDate(month: 2, day: 29) == (try date(2000, 2, 29)))
        #expect(AnniversaryDay.years(from: 2026, through: 2026) == [2026])
        let ranges = try AnniversaryDay.matchingDays(on: date(2024, 2, 29), since: date(2016, 1, 1), calendar: cal)
        #expect(ranges.map(\.lowerBound) == [try date(2024, 2, 29), try date(2020, 2, 29), try date(2016, 2, 29)])
        let dst = try AnniversaryDay.matchingDays(on: date(2026, 3, 9), since: date(2025, 1, 1), calendar: cal)
        let day = try #require(dst.last)
        #expect(day.upperBound.timeIntervalSince(day.lowerBound) == 23 * 3600)
        #expect(!day.contains(day.upperBound))
    }

    @Test func sqlitePreviewAndPagesExcludeRevokedAndNeighboringPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SQLiteTravelIndexStore(databaseURL: url.appendingPathComponent("index.sqlite"))
        let fixture = SampleTravelIndex.makeMapReviewFixture()
        try await store.save(fixture)
        let ordered = fixture.photos.sorted { $0.creationDate > $1.creationDate }
        let range = ordered[90].creationDate..<ordered[8].creationDate
        let excluded: Set<String> = [ordered[9].id, ordered[58].id]
        let expected = ordered.filter { range.contains($0.creationDate) && !excluded.contains($0.id) }.sorted(by: SlideshowOrdering.recordComesFirst)
        let reader = try await store.photoReadSnapshot()
        let visits = try await reader.anniversaryVisitIDs(in: range, excluding: excluded)
        #expect(Set(visits) == Set(expected.compactMap(\.placeID)))
        let removed = try await reader.anniversaryVisitIDs(in: range, excluding: Set(ordered.map(\.id)))
        #expect(removed.isEmpty)
        let preview = try await reader.anniversaryPage(in: range, excluding: excluded, offset: 0, limit: 5)
        #expect(preview.records == Array(expected.prefix(5)))
        #expect(preview.nextOffset == 5)
        let first = try await reader.anniversaryPage(in: range, excluding: excluded, offset: 0)
        let offset = try #require(first.nextOffset)
        let second = try await reader.anniversaryPage(in: range, excluding: excluded, offset: offset)
        #expect(first.records + second.records == expected)
        #expect(second.nextOffset == nil)
    }

    @Test func titlesShowTheFirstThreeDistinctKnownLocations() {
        func place(_ id: String, _ city: String, _ country: String?) -> TravelPlace {
            TravelPlace(id: id, name: city, country: country, coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                        startDate: .distantPast, endDate: .distantPast, photoCount: 1, coverAssetID: nil)
        }
        let places = [place("a", "Paris", "France"), place("b", "Paris", "France"), place("c", "", nil),
                      place("d", "Paris", "USA"), place("e", "", "Japan"), place("f", "London", "UK")]
        let shelf = AnniversaryShelf(id: 2026, range: nil, visitIDs: places.map(\.id))
        #expect(shelf.locationLabels(in: PhotoWallPlaces(places)) == [places[0], places[3], places[4]].map(PlaceDisplayLabel.init(place:)))
    }

    @MainActor @Test func foldedShelvesStreamEveryMatchingItemInYearAndCaptureOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let source = SampleTravelIndex.make()
        let calendar = Calendar(identifier: .gregorian)
        let rows = [2025, 2024, 2023].map { year in
            let day = calendar.anniversaryDate(month: 11, day: 23, year: year)!
            return AnniversaryShelf(id: year, range: day..<calendar.date(byAdding: .day, value: 1, to: day)!, nextOffset: 0)
        }
        var photos: [PhotoAssetRecord] = []
        for (i, count) in [52, 0, 3].enumerated() {
            for n in 0..<count {
                let place = source.index.places[n % source.index.places.count]
                photos.append(PhotoAssetRecord(id: "fixture-\(i)-\(n)", coordinate: place.coordinate,
                                               creationDate: rows[i].range!.lowerBound.addingTimeInterval(TimeInterval(n)),
                                               pixelWidth: 1200, pixelHeight: 800, isFavorite: false,
                                               mediaKind: n == 4 ? .video : .photo, placeID: place.id))
            }
        }
        let stored = TravelClusterer().makeIndex(records: photos)
        try await store.save(stored)
        let reader = try await store.photoReadSnapshot()
        let months = rows.compactMap { calendar.dateInterval(of: .month, for: $0.range!.lowerBound) }
        let marks = try await reader.anniversaryCalendarDays(months: months, excluding: [])
        #expect(marks == [23])
        let excludedMarks = try await reader.anniversaryCalendarDays(months: months, excluding: Set(photos.map(\.id)))
        #expect(excludedMarks.isEmpty)
        let session = AnniversaryBrowser(model: AppModel(), reader: reader, shelves: rows)
        for i in rows.indices { try await session.load(i, preview: true) }
        #expect(session.shelves.map { $0.records.count } == [5, 0, 3])
        let show = try await session.snapshot()
        var sequence = SlideshowPageSequence(places: show.places ?? [])
        #expect(sequence.segments.map { $0.visits[0].year } == [2025, 2023])
        var played: [PhotoAssetRecord] = []
        while let request = sequence.begin() {
            let page = try show.page(request, limit: 8)
            played += page.records
            sequence.finish(request, next: page.next)
        }
        #expect(played.map(\.id) == photos.map(\.id))
        #expect(Set(played) == Set(stored.photos))
    }
}
