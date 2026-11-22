import Foundation
import Testing
@testable import PhotoEarth

struct PlaceCollectionTests {
    private func place(_ id: String, city: String, country: String?, date: Double,
                       coordinate: GeoCoordinate = GeoCoordinate(latitude: 0, longitude: 0)) -> TravelPlace {
        TravelPlace(id: id, name: city, country: country, coordinate: coordinate,
                    startDate: Date(timeIntervalSince1970: date), endDate: Date(timeIntervalSince1970: date),
                    photoCount: 2, coverAssetID: nil)
    }

    @Test func countryAndCityGroupsRetainAllClustersAndSeparateNamesAcrossCountries() throws {
        let places = [place("a", city: "巴黎", country: "法国", date: 10),
                      place("b", city: "巴黎", country: "法国", date: 30),
                      place("c", city: "巴黎", country: "美国", date: 20),
                      place("d", city: "地点 1", country: nil, date: 40),
                      place("e", city: "地点 1", country: nil, date: 50)]
        let countries = PlaceCollection.countries(places)
        #expect(countries == PlaceCollection.countries(places.reversed()))
        #expect(countries.count == 3)
        #expect(Set(countries.flatMap(\.placeIDs)) == Set(places.map(\.id)))
        let france = try #require(countries.first { $0.title == "法国" })
        #expect(france.cities.count == 1)
        #expect(france.cities[0].placeIDs == ["b", "a"])
        #expect(france.photoCount == 4)
        #expect(countries.last?.id == "country:unresolved")
        #expect(countries.last?.cities.count == 2)
    }

    @Test func recentArrivalTiesHaveStableOrder() {
        let places = [place("b", city: "B", country: "X", date: 20),
                      place("a", city: "A", country: "X", date: 20),
                      place("c", city: "C", country: "Y", date: 30)]
        #expect(PlaceCollection.recent(places).map(\.id) == ["c", "a", "b"])
    }

    @Test func slideshowRecognizesLegacyRevisitsWithoutCombiningUnrelatedCities() {
        let first = place("paris-1", city: "Paris", country: "France", date: 10)
        var second = place("paris-2", city: "Paris", country: "France", date: 20)
        let texas = place("paris-tx", city: "Paris", country: "United States", date: 30)
        let unknownA = place("unknown-a", city: "", country: "France", date: 40)
        let unknownB = place("unknown-b", city: "", country: "France", date: 50)
        func chapter(_ visit: TravelPlace) -> EarthSlideshowChapter.ID { EarthSlideshowChapter(visit: visit).id }
        #expect(chapter(first) == chapter(second))
        #expect(chapter(first) != chapter(texas))
        #expect(chapter(unknownA) != chapter(unknownB))

        second.offlinePlaceID = "catalog-paris"
        var translated = second
        translated.name = "巴黎"
        #expect(chapter(second) == chapter(translated))
    }

    @Test func countriesAndCitiesFollowTheirNewestPhotoWithStableTies() throws {
        let places = [
            place("paris-old", city: "Paris", country: "France", date: 10),
            place("banff", city: "Banff", country: "Canada", date: 20),
            place("lyon", city: "Lyon", country: "France", date: 30),
            place("tokyo", city: "Tokyo", country: "Japan", date: 40),
            place("paris-new", city: "Paris", country: "France", date: 50),
            place("pending", city: "未知地点", country: nil, date: 60),
        ]

        let countries = PlaceCollection.countries(places)
        #expect(countries.map(\.title) == ["France", "Japan", "Canada", AppLocalization.unresolvedPlace])
        let france = try #require(countries.first)
        #expect(france.latestPlace?.id == "paris-new")
        #expect(france.cities.map(\.title) == ["Paris", "Lyon"])
        #expect(france.cities.first?.placeIDs == ["paris-new", "paris-old"])

        let countryTies = PlaceCollection.countries([
            place("z-place", city: "Z City", country: "Zulu", date: 100),
            place("a-place", city: "A City", country: "Alpha", date: 100),
        ])
        #expect(countryTies.map(\.id) == ["country:name:Alpha", "country:name:Zulu"])

        let cityTies = try #require(PlaceCollection.countries([
            place("z-place", city: "Z City", country: "France", date: 100),
            place("a-place", city: "A City", country: "France", date: 100),
        ]).first)
        #expect(cityTies.cities.map(\.title) == ["A City", "Z City"])
    }

    @Test func recentVisitsAreSectionedByTheCalendarMonthOfTheirEndDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh-Hans-CN")
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }
        func visit(_ id: String, start: Date, end: Date) -> TravelPlace {
            TravelPlace(id: id, name: id, country: "中国", coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                        startDate: start, endDate: end, photoCount: 3, coverAssetID: nil)
        }
        let visits = PlaceCollection.recent([
            visit("new", start: try date(2026, 9, 11), end: try date(2026, 9, 13)),
            visit("spanning", start: try date(2026, 8, 29), end: try date(2026, 9, 2)),
            visit("old", start: try date(2026, 8, 25), end: try date(2026, 8, 30)),
        ])

        let months = PlaceCollection.recentMonths(inRecencyOrder: visits, calendar: calendar)
        let septemberStart = try date(2026, 9, 1)
        let septemberEnd = try date(2026, 9, 30)
        let augustStart = try date(2026, 8, 1)
        let augustEnd = try date(2026, 8, 31)

        #expect(months.count == 2)
        #expect(months[0].visits.map(\.id) == ["new", "spanning"])
        #expect(months[0].startDate == septemberStart)
        #expect(months[0].endDate == septemberEnd)
        #expect(months[1].visits.map(\.id) == ["old"])
        #expect(months[1].startDate == augustStart)
        #expect(months[1].endDate == augustEnd)
    }

    @Test func homeCitySelectionPinsEveryVisitWithoutNearbyCities() throws {
        let places = [
            place("paris-new", city: "Paris", country: "France", date: 30),
            place("paris-old", city: "Paris", country: "France", date: 10),
            place("paris-texas", city: "Paris", country: "United States", date: 20),
            place("lyon", city: "Lyon", country: "France", date: 40),
        ]
        let city = PlaceCollection.city(containing: places[1], in: places)
        #expect(city.title == "Paris")
        #expect(city.subtitle == "France")
        #expect(city.placeIDs == ["paris-new", "paris-old"])
        #expect(city.photoCount == 4)
        #expect(city.representsSingleCity)
        let france = try #require(PlaceCollection.countries(places).first { $0.title == "France" })
        #expect(!france.representsSingleCity)
    }

    @Test func homeKeepsOnlyTheNewestCardForEachResolvedCity() {
        let places = [
            place("paris-old", city: "Paris", country: "France", date: 10),
            place("paris-new", city: "Paris", country: "France", date: 40),
            place("paris-texas", city: "Paris", country: "United States", date: 30),
            place("unknown-a", city: "未知地点", country: nil, date: 50),
            place("unknown-b", city: "未知地点", country: nil, date: 20),
        ]

        let representatives = PlaceCollection.homeCityRepresentatives(places)

        #expect(representatives.map(\.id) == ["unknown-a", "paris-new", "paris-texas", "unknown-b"])
        #expect(!representatives.contains { $0.id == "paris-old" })
    }

    @Test func selectionsUseStableCountryIdentityAndRejectChangedCityMembership() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let old = [place("reused", city: "同名城", country: "甲国", date: 10)]
        let country = try #require(PlaceCollection.countries(old).first)
        let city = try #require(country.cities.first)
        let visit = try #require(PlaceCollection.recent(old).first)
        let reused = place("reused", city: "同名城", country: "乙国", date: 20,
                           coordinate: GeoCoordinate(latitude: 40, longitude: 100))
        let fresh = [
            reused,
            place("new-a", city: "同名城", country: "甲国", date: 30,
                  coordinate: GeoCoordinate(latitude: 10, longitude: 10)),
            place("new-b", city: "第二城", country: "甲国", date: 40,
                  coordinate: GeoCoordinate(latitude: 20, longitude: 20)),
            place("unknown-a", city: "未知地点", country: nil, date: 50,
                  coordinate: GeoCoordinate(latitude: 30, longitude: 30)),
            place("unknown-b", city: "未知地点", country: nil, date: 60,
                  coordinate: GeoCoordinate(latitude: 35, longitude: 35)),
        ]
        let records = fresh.flatMap { place in
            (0..<55).map { number in
                PhotoAssetRecord(id: "\(place.id)-\(number)", coordinate: place.coordinate,
                                 creationDate: Date(timeIntervalSince1970: Double(number)),
                                 pixelWidth: 1000, pixelHeight: 1000, isFavorite: false, placeID: place.id)
            }
        }
        try await store.save(TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
                             generatedAt: Date(), sourcePhotoCount: records.count, locatedPhotoCount: records.count,
                             places: fresh, journeys: []), photos: records))
        let reader = try await store.photoReadSnapshot()
        let summaries = try await reader.placeSummariesForReading()
        #expect(Set(try country.matchingPlaceIDs(in: summaries)) == ["new-a", "new-b"])
        #expect(throws: PhotoWallSelectionError.self) { try city.matchingPlaceIDs(in: summaries) }
        #expect(throws: PhotoWallSelectionError.self) { try visit.matchingPlaceIDs(in: summaries) }
        let freshCountry = try #require(PlaceCollection.countries(summaries).first { $0.title == "甲国" })
        let freshCity = try #require(freshCountry.cities.first { $0.title == "同名城" })
        for (selection, expected) in [(freshCountry, Set(["new-a", "new-b"])), (freshCity, Set(["new-a"]))] {
            let ids = try selection.matchingPlaceIDs(in: summaries)
            var offset = 0, loaded: [PhotoAssetRecord] = []
            repeat {
                let page = try await reader.photoPage(for: ids, offset: offset, limit: 48)
                loaded += page.records
                guard let next = page.nextOffset else { break }
                offset = next
            } while offset < 1000
            #expect(Set(loaded.compactMap(\.placeID)) == expected)
            #expect(loaded.count == expected.count * 55)
            #expect(Set(loaded.map(\.id)).count == loaded.count)
        }
        let unresolved = try #require(PlaceCollection.countries(fresh).last)
        #expect(unresolved.cities.count == 2)
        #expect(Set(try unresolved.matchingPlaceIDs(in: summaries)) == ["unknown-a", "unknown-b"])
    }

    @Test func partialLabelsNeverMergeUnrelatedAnonymousCities() throws {
        let countries = PlaceCollection.countries([
            place("a", city: "未知地点", country: "甲国", date: 1),
            place("b", city: "未知地点", country: "甲国", date: 2),
            place("c", city: "同名城", country: nil, date: 3),
            place("d", city: "同名城", country: nil, date: 4)
        ])
        #expect(countries.flatMap(\.cities).count == 4)
        #expect(countries.count == 1)
        let unresolved = try #require(countries.first)
        #expect(unresolved.id == "country:unresolved")
        #expect(unresolved.title == AppLocalization.unresolvedPlace)
        #expect(unresolved.cities.first { $0.placeIDs == ["b"] }?.title == AppLocalization.unknownPlace(near: "甲国"))
        #expect(unresolved.cities.first { $0.placeIDs == ["b"] }?.subtitle == AppLocalization.unresolvedPlace)
    }

    @Test func countryOnlyVisitsStayInAllPhotosWithoutCreatingCities() throws {
        let countryOnly = TravelPlace(id: "country-only", name: "", country: "Japan", regionCode: "JP",
                                      coordinate: .init(latitude: 36, longitude: 138),
                                      startDate: .distantPast, endDate: .now, photoCount: 3, coverAssetID: nil)
        let city = TravelPlace(id: "city", name: "Tokyo", country: "Japan", regionCode: "JP",
                               offlinePlaceID: "catalog:tokyo", coordinate: .init(latitude: 35.6, longitude: 139.7),
                               startDate: .distantPast, endDate: .distantPast, photoCount: 5, coverAssetID: nil)
        let countries = PlaceCollection.countries([countryOnly, city])
        #expect(countries.count == 1)
        let japan = try #require(countries.first)
        #expect(japan.id == "country:region:JP")
        #expect(japan.photoCount == 8)
        #expect(japan.subtitle == AppLocalization.cityCount(1))
        #expect(japan.cities.map(\.placeIDs) == [["city"]])
        #expect(Set(try japan.matchingPlaceIDs(in: [countryOnly, city])) == ["country-only", "city"])
        #expect(PlaceCollection.countries([countryOnly]).first?.cities.isEmpty == true)
    }

    @Test func countryPaginationIsBoundedStableAndExcludesOtherCountriesAtFiftyThousandPhotos() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let places = [place("a", city: "A", country: "X", date: 20),
                      place("b", city: "B", country: "X", date: 30),
                      place("c", city: "C", country: "Y", date: 40)]
        let photos = (0..<50_000).map { number in
            PhotoAssetRecord(id: String(format: "photo-%05d", number), coordinate: places[0].coordinate,
                             creationDate: Date(timeIntervalSince1970: Double(number / 4)),
                             pixelWidth: 4000, pixelHeight: 3000, isFavorite: false,
                             placeID: places[number % 3].id)
        }
        try await store.save(TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
                         generatedAt: Date(), sourcePhotoCount: photos.count, locatedPhotoCount: photos.count,
                         places: places, journeys: []), photos: photos))
        let expected = photos.filter { $0.placeID != "c" }.sorted {
            $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate
        }
        let first = try await store.photoPage(for: ["b", "a", "a"], offset: 0, limit: 50_000)
        #expect(first.records.count == 48)
        #expect(first.nextOffset == 48)
        let second = try await store.photoPage(for: ["a", "b"], offset: 48, limit: 48)
        #expect(first.records + second.records == Array(expected.prefix(96)))
        let last = try await store.photoPage(for: ["a", "b"], offset: expected.count - 2, limit: 48)
        #expect(last.records == Array(expected.suffix(2)))
        #expect(last.nextOffset == nil)
        let empty = try await store.photoPage(for: [], offset: 0, limit: 48)
        #expect(empty.records.isEmpty && empty.nextOffset == nil)
        let missing = try await store.photoPage(for: ["missing"], offset: 0, limit: 48)
        #expect(missing.records.isEmpty && missing.nextOffset == nil)
    }
}
