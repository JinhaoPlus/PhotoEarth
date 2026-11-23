import Foundation
import Testing
import TVServices
@testable import PhotoEarth

struct JourneyShelfTests {
    @Test func nativeShelfRequiresRealJourneyArtThenStartsWithTheLargeGlobeAndPreservesOrder() throws {
        let opaqueImage = try #require(URL(string: "file:///synthetic-globe.jpg"))
        let rows = (0...JourneyShelfSnapshot.limit).map { TVTopShelfSectionedItem(identifier: "item-\($0)") }
        let hidden: [([TVTopShelfSectionedItem], Set<String>)] = [
            ([], []), ([], ["item-0"]), (rows, []), (rows, ["stale"]), (rows, [rows.last!.identifier])
        ]
        for (items, routes) in hidden {
            #expect(JourneyShelfLayout.content(globeTitle: "Globe", globeImage: opaqueImage, journeys: items, readablePosterRoutes: routes) == nil)
        }
        for count in [1, 6, rows.count] {
            let shelf = try #require(JourneyShelfLayout.content(globeTitle: "Globe", globeImage: opaqueImage,
                                                                journeys: Array(rows.prefix(count)), readablePosterRoutes: ["item-0"]))
            let section = try #require(shelf.sections.first)
            #expect(shelf.sections.count == 1 && section.title == "PHOTO EARTH")
            let globe = try #require(section.items.first)
            #expect(globe.imageShape == .hdtv && globe.displayAction?.url == JourneyShelfDestination.globeURL)
            #expect(globe.imageURL(for: .screenScale2x) == opaqueImage)
            #expect(section.items.dropFirst().map(\.identifier) == rows.prefix(min(count, JourneyShelfSnapshot.limit)).map(\.identifier))
            #expect(section.items.dropFirst().allSatisfy { $0.imageShape == .poster })
        }
    }

#if DEBUG
    @MainActor @Test func publicGlobeLinkCanWaitForStartupAndReturnToUnauthorisedWelcome() async throws {
        let library = PreparationFixtureLibrary(records: [], initiallyRequiresAuthorization: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(photoLibrary: library, indexStore: SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite")),
                             preferencesStore: MemoryPreferenceStore(), clusterer: TravelClusterer())
        model.requestTopShelfURL(JourneyShelfDestination.globeURL)
        #expect(await model.takeTopShelfAction() == nil)
        await model.start()
        #expect(model.phase == .welcome)
        guard case .globe = await model.takeTopShelfAction() else { Issue.record("Expected a public globe"); return }
        #expect(model.isExploringPublicGlobe)
        #expect(await library.authorizationStatus() == .notDetermined)
        #expect(model.index == nil)
        model.closePublicGlobe()
        #expect(!model.isExploringPublicGlobe && model.phase == .welcome)
        #expect(await library.authorizationStatus() == .notDetermined)
    }
#endif

    @Test func shelfMatchesTheHomeDockAndOpensTheSameCityCollection() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        func visit(_ id: String, name: String, city: String, day: Double, latitude: Double = 35, count: Int = 5) -> TravelPlace {
            let end = date.addingTimeInterval(day * 86_400)
            return TravelPlace(id: id, name: name, country: "Japan", offlinePlaceID: city,
                               coordinate: .init(latitude: latitude, longitude: 130),
                               startDate: end, endDate: end, photoCount: count, coverAssetID: nil)
        }

        let tokyo = visit("01", name: "Tokyo", city: "tokyo", day: 8)
        let tokyoEarlier = visit("03", name: "Tokyo", city: "tokyo", day: 7)
        let kyoto = visit("02", name: "Kyoto", city: "kyoto", day: 8)
        let tokyoShortStop = visit("short", name: "Tokyo", city: "tokyo", day: 9, count: 4)
        let quickStop = visit("quick", name: "Osaka", city: "osaka", day: 10, count: 4)
        let secondQuickStop = visit("quick-2", name: "Osaka", city: "osaka", day: 11, count: 4)
        let source = [tokyoShortStop, quickStop, secondQuickStop, tokyoEarlier, kyoto, tokyo] + (4...8).map {
            visit("0\($0)", name: "City \($0)", city: "city-\($0)", day: Double(9 - $0))
        }
        let journey = TravelJourney(id: "combined", title: "", startDate: date, endDate: tokyo.endDate,
                                    placeIDs: source.map(\.id))
        func index(_ places: [TravelPlace], journeys: [TravelJourney]) -> TravelIndex {
            TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: date,
                        sourcePhotoCount: 16, locatedPhotoCount: 16, places: places, journeys: journeys)
        }
        let shelf = JourneyShelfSelection.recent(in: index(source, journeys: [journey]), minimumVisitItems: 5)
        #expect(shelf == JourneyShelfSelection.recent(in: index(source.reversed(), journeys: []), minimumVisitItems: 5))
        #expect(shelf.prefix(PlaceCollection.homeRecentLimit).map(\.collection.title) == ["Tokyo", "Kyoto", "City 4", "City 5", "City 6"])
        #expect(shelf.dropFirst(PlaceCollection.homeRecentLimit).map(\.collection.title) == ["City 7", "City 8"])
        let first = try #require(shelf.first)
        let wall = first.collection
        let home = PlaceCollection.city(containing: tokyo, in: source)
        #expect(first.representative == tokyo)
        #expect(wall.subtitle == home.subtitle)
        #expect(try wall.matchingPlaceIDs(in: source) == home.matchingPlaceIDs(in: source))
        #expect(wall.placeIDs == [tokyoShortStop.id, tokyo.id, tokyoEarlier.id])
        #expect(JourneyShelfLink.route(try #require(JourneyShelfLink.url(wall.id))) == wall.id)

        let moved = visit(tokyoEarlier.id, name: "Tokyo", city: "tokyo", day: 7, latitude: 36)
        let updated = source.map { $0.id == moved.id ? moved : $0 }
        #expect(JourneyShelfSelection.recent(in: index(updated, journeys: []), minimumVisitItems: 5).first?.collection.id != wall.id)
        #expect(JourneyShelfSelection.recent(in: index(source, journeys: []), minimumVisitItems: 1).prefix(2).map(\.representative.id) == [secondQuickStop.id, tokyoShortStop.id])
        #expect(!PlaceCollection.recent(source, minimumVisitItems: 5).map(\.id).contains(quickStop.id))
    }
}
