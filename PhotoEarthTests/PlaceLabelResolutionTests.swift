import Foundation
import Testing
@testable import PhotoEarth

@MainActor
struct PlaceLabelResolutionTests {
    private func place(_ number: Int) -> TravelPlace {
        TravelPlace(id: "test-place-\(number)", name: "地点 \(number)", country: nil,
                    coordinate: GeoCoordinate(latitude: 10, longitude: Double(number)),
                    startDate: Date(timeIntervalSince1970: Double(number)),
                    endDate: Date(timeIntervalSince1970: Double(number)), photoCount: 1, coverAssetID: nil)
    }
    private var resolved: PlaceDisplayLabel { PlaceDisplayLabel(city: "测试城市", country: "测试国家") }

    @Test func placeholdersAndPartialResultsRemainUnresolved() {
        for city in ["", "  ", "地点 07", "未知地点", "地名待完善"] {
            #expect(!PlaceDisplayLabel(city: city, country: "国家").isComplete)
        }
        #expect(!PlaceDisplayLabel(city: "城市", country: " ").isComplete)
        #expect(PlaceDisplayLabel(city: "城市", country: "国家").isComplete)
    }

    @Test func unresolvedCityDisplaysTrustedCountryContextWithoutTreatingItAsResolved() {
        let countryOnly = PlaceDisplayLabel(city: "", country: "日本")
        #expect(countryOnly.displayCity == AppLocalization.unknownPlace(near: "日本"))
        #expect(countryOnly.displaySubtitle == AppLocalization.unresolvedPlace)
        #expect(!countryOnly.isComplete)

        let anonymous = PlaceDisplayLabel(city: "", country: nil)
        #expect(anonymous.displayCity == AppLocalization.unknownPlace(near: nil))
        #expect(!anonymous.displayCity.contains("@"))

        let regionOnly = PlaceDisplayLabel(city: "", country: nil, regionCode: "JP")
        let localizedCountry = AppLocalization.locale.localizedString(forRegionCode: "JP")
        #expect(regionOnly.displayCity == AppLocalization.unknownPlace(near: localizedCountry))
    }

    @Test func wallPrioritizesFocusedPlaceAndNeverResolvesWholeLoadedLibrary() {
        let records = (0..<50_000).map { number in
            PhotoAssetRecord(id: "photo-\(number)", coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                             creationDate: Date(), pixelWidth: 100, pixelHeight: 100, isFavorite: false,
                             placeID: "place-\(number / 2)")
        }
        let ids = PhotoPlaceLabelWindow.placeIDs(in: records, focusedPhotoID: "photo-40001")
        #expect(ids.first == "place-20000")
        #expect(ids.count <= 15)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { (19998...20007).contains(Int($0.dropFirst(6))!) })
        #expect(PhotoPlaceLabelWindow.placeIDs(in: [], focusedPhotoID: nil).isEmpty)
    }

    @Test func concurrentScenesShareOneLookupAndDifferentPlacesAreSerialized() async throws {
        var calls = 0
        var active = 0
        var maxActive = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in
            calls += 1; active += 1; maxActive = max(maxActive, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            return result
        }
        async let first = resolver.label(for: place(1))
        async let duplicate = resolver.label(for: place(1))
        async let second = resolver.label(for: place(2))
        let values = await [first, duplicate, second]
        #expect(values.allSatisfy { $0 == result })
        #expect(calls == 2)
        #expect(maxActive == 1)
        #expect(await resolver.label(for: place(1)) == result)
        #expect(calls == 2)
    }

    @Test func oneCanceledSceneDoesNotCancelAnotherScenesSamePlace() async throws {
        var calls = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(80))
            return result
        }
        let first = Task { await resolver.label(for: place(1)) }
        let second = Task { await resolver.label(for: place(1)) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        #expect(await first.value == nil)
        #expect(await second.value == result)
        #expect(calls == 1)
    }

    @Test func cancelingQueuedPlaceSkipsItsLookup() async throws {
        var calls = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(80))
            return result
        }
        let first = Task { await resolver.label(for: place(1)) }
        try await Task.sleep(for: .milliseconds(10))
        let queued = Task { await resolver.label(for: place(2)) }
        try await Task.sleep(for: .milliseconds(10))
        queued.cancel()
        #expect(await first.value == result)
        #expect(await queued.value == nil)
        #expect(calls == 1)
    }

    @Test func databaseReadFailureCanBeRetriedButACompletedMissIsCached() async {
        var attempts = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadUnknown) }
            return result
        }
        #expect(await resolver.resolution(for: place(1)) == .transientUnavailable(nil))
        #expect(await resolver.label(for: place(1)) == result)
        var misses = 0
        let missing = PlaceLabelResolver { _ in misses += 1; return nil }
        #expect(await missing.resolution(for: place(1)) == .stableUnavailable(nil))
        #expect(await missing.label(for: place(1)) == nil)
        #expect(misses == 1)
    }

    @Test func partialResultsBecomeStableWithoutRepeatedLookups() async {
        var calls = 0
        let resolver = PlaceLabelResolver { _ in
            calls += 1
            return PlaceDisplayLabel(city: "", country: "测试国家")
        }
        let first = await resolver.resolution(for: place(1))
        #expect(first == .stableUnavailable(PlaceDisplayLabel(city: "", country: "测试国家")))
        #expect(await resolver.label(for: place(1))?.isComplete == false)
        #expect(calls == 1)
    }

    @Test func injectedLookupRunsAtACityCenter() async {
        var calls = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in calls += 1; return result }
        let sydney = TravelPlace(id: "sydney", name: "地点 1", country: nil,
                                coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093),
                                startDate: Date(), endDate: Date(), photoCount: 1, coverAssetID: nil)
        #expect(await resolver.label(for: sydney) == result)
        #expect(calls == 1)
    }

    @Test func visibleRequestsCannotStarveWholeLibrary() async throws {
        var order: [Int] = []
        let result = resolved
        let resolver = PlaceLabelResolver { coordinate in
            order.append(Int(coordinate.longitude))
            // Block only the first call to populate both priority queues.
            if order.count == 1 { try await Task.sleep(for: .milliseconds(40)) }
            return result
        }
        let first = Task { await resolver.label(for: place(0)) }
        try await Task.sleep(for: .milliseconds(10))
        let library = Task { await resolver.label(for: place(90), priority: .library) }
        let visible = (1...8).map { number in Task { await resolver.label(for: place(number)) } }
        _ = await first.value; _ = await library.value
        for task in visible { _ = await task.value }
        #expect(order.count == 10)
        #expect(try #require(order.firstIndex(of: 90)) <= 3)
    }

    @Test func openingPlaceOutsideFirstFifteenPersistsAndNextLaunchNeedsNoLookup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        try await store.save(snapshot(count: 40))
        var calls = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in calls += 1; return result }
        let model = makeModel(store: store, resolver: resolver)
        await model.start()
        await model.resolvePlaceLabels(for: [place(30).id, place(30).id])
        #expect(model.index?.place(id: place(30).id)?.name == result.city)
        #expect(model.index?.place(id: place(0).id)?.country == nil)
        let disk = try await store.load()
        #expect(disk?.place(id: place(30).id)?.country == result.country)
        let reopened = makeModel(store: store, resolver: resolver)
        await reopened.start()
        await reopened.resolvePlaceLabels(for: [place(30).id])
        #expect(calls == 1)
    }

    @Test func expandingOverviewPastFifteenDoesNotSpendLookupBudgetOnCachedPlaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        try await store.save(snapshot(count: 80))
        var calls = 0
        let result = resolved
        let resolver = PlaceLabelResolver { _ in calls += 1; return result }
        let model = makeModel(store: store, resolver: resolver)
        await model.start()
        await model.resolvePlaceLabels(for: (0..<15).map { place($0).id })
        #expect(calls == 15)
        await model.resolvePlaceLabels(for: (0..<25).map { place($0).id })
        #expect(calls == 25)
        #expect(model.index?.place(id: place(24).id)?.country == result.country)
        #expect(model.index?.place(id: place(25).id)?.country == nil)
        // Even oversized callers can only start 15 unresolved places per batch.
        resolver.reset()
        let oversized = makeModel(store: store, resolver: resolver)
        await oversized.start()
        await oversized.resolvePlaceLabels(for: (0..<80).map { place($0).id })
        #expect(calls == 40)
        #expect(oversized.index?.place(id: place(39).id)?.country == result.country)
        #expect(oversized.index?.place(id: place(40).id)?.country == nil)
    }

    @Test func resultsPublishIndividuallyBeforeRestOfBatchFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        try await store.save(snapshot(count: 3))
        var calls = 0
        let result = resolved
        var resumeSecond: CheckedContinuation<Void, Never>?
        let resolver = PlaceLabelResolver { _ in
            calls += 1
            if calls > 1 { await withCheckedContinuation { resumeSecond = $0 } }
            return result
        }
        let model = makeModel(store: store, resolver: resolver)
        await model.start()
        let batch = Task { await model.resolvePlaceLabels(for: [place(0).id, place(1).id]) }
        for _ in 0..<200 {
            if resumeSecond != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(resumeSecond)
        #expect(model.index?.place(id: place(0).id)?.country == result.country)
        #expect(model.index?.place(id: place(1).id)?.country == nil)
        let disk = try await store.load()
        #expect(disk?.place(id: place(0).id)?.country == result.country)
        continuation.resume()
        await batch.value
    }

    @Test func replacingIndexPreventsOldLookupFromWritingIntoNewData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        try await store.save(snapshot(count: 2))
        let result = resolved
        let resolver = PlaceLabelResolver { _ in
            try? await Task.sleep(for: .milliseconds(150)) // Simulate late native completion.
            return result
        }
        let model = makeModel(store: store, resolver: resolver)
        await model.start()
        let lookup = Task { await model.resolvePlaceLabels(for: [place(0).id]) }
        try await Task.sleep(for: .milliseconds(20))
        model.useSampleData()
        await lookup.value
        #expect(model.isUsingSampleData)
        #expect(model.placeLabelStates.isEmpty)
        let disk = try await store.load()
        #expect(disk?.place(id: place(0).id)?.country == nil)
    }

    private func snapshot(count: Int) -> TravelIndexSnapshot {
        let places = (0..<count).map(place)
        let photos = places.map { place in
            PhotoAssetRecord(id: "photo-\(place.id)", coordinate: place.coordinate, creationDate: place.startDate,
                             pixelWidth: 100, pixelHeight: 100, isFavorite: false, placeID: place.id)
        }
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
                                   generatedAt: Date(), sourcePhotoCount: count, locatedPhotoCount: count,
                                   places: places, journeys: []), photos: photos)
    }

    private func makeModel(store: SQLiteTravelIndexStore, resolver: PlaceLabelResolver) -> AppModel {
        AppModel(photoLibrary: NoScanLibrary(), indexStore: store, preferencesStore: MemoryPreferenceStore(),
                 clusterer: TravelClusterer(), placeLabelResolver: resolver)
    }
}

private nonisolated struct NoScanLibrary: PhotoLibraryProviding {
    func authorizationStatus() async -> PhotoLibraryAccess { .authorized }
    func requestAuthorization() async -> PhotoLibraryAccess { .denied }
    func scanLocatedPhotos() async throws -> PhotoLibraryScan { throw CancellationError() }
}
