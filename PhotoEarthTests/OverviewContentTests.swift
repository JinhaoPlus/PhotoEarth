import Foundation
import Observation
import Testing
import UIKit
@testable import PhotoEarth

@MainActor struct OverviewContentTests {
    @Test func changingJourneyMinimumRefreshesTheSameIndexAndPersistsLocally() throws {
        let name = "journey-minimum-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func makeModel() -> AppModel {
            AppModel(photoLibrary: PreparationFixtureLibrary(records: []),
                     indexStore: SQLiteTravelIndexStore(databaseURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(name).sqlite")),
                     preferencesStore: MemoryPreferenceStore(), clusterer: TravelClusterer(), journeyDefaults: defaults)
        }
        let app = makeModel()
        #expect(app.minimumJourneyItems == 5)
        app.useSampleData()
        let originalIndex = app.index
        #expect(!app.overview.recent.isEmpty)

        app.setMinimumJourneyItems(1_500)
        #expect(app.minimumJourneyItems == 1_000)
        #expect(app.overview.recent.isEmpty && app.overview.hasVisitsBelowMinimum)
        #expect(app.index == originalIndex)
        #expect(makeModel().minimumJourneyItems == 1_000)

        app.setMinimumJourneyItems(0)
        #expect(app.minimumJourneyItems == 1)
        #expect(!app.overview.recent.isEmpty)
        #expect(app.index == originalIndex)
    }

    @Test func canceledCoverCannotClearTheReplacementRequestOnReturn() async {
        var replies: [CheckedContinuation<PhotoPreviewMetadata?, Never>] = []
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false),
            latestCovers: { places in
                Dictionary(uniqueKeysWithValues: places.map {
                    ($0.id, PhotoPreviewMetadata(assetID: "latest-\($0.id)", pixelWidth: 1600, pixelHeight: 1000))
                })
            }, scenicCover: { _, _ in await withCheckedContinuation { replies.append($0) } })
        defer { model.setActive(false) }
        model.receive(index(count: 30)); model.setActive(true)
        await wait { model.recent.first?.coverPrepared == true }
        let item = model.recent[0]
        model.visibilityChanged(item.id, visible: true)
        for _ in 0..<100 where replies.count < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(replies.count == 1)
        model.setActive(false); model.setActive(true)
        for _ in 0..<100 where replies.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(replies.count == 2)
        guard replies.count == 2 else { for reply in replies { reply.resume(returning: nil) }; return }
        replies[0].resume(returning: .init(assetID: "obsolete", pixelWidth: 1600, pixelHeight: 1000))
        for _ in 0..<10 { await Task.yield() }
        model.focusChanged("place-\(item.id)")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(replies.count == 2, "The old completion must not make a second replacement request possible")
        #expect(item.latestAssetID != "obsolete")
        replies[1].resume(returning: .init(assetID: "new-scenery", pixelWidth: 1600, pixelHeight: 1000))
        for reply in replies.dropFirst(2) { reply.resume(returning: nil) }
        await wait { item.latestAssetID == "new-scenery" }
    }

    @Test func coverWaitsForScoringAndThenDisplaysTheSelectionOrLatestFallback() async throws {
        var scenicCalls = 0
        let backend = OverviewTestRequester()
        let model = OverviewContentModel(images: .init(requester: backend, automaticScheduling: false),
            latestCovers: { places in
                Dictionary(uniqueKeysWithValues: places.map {
                    ($0.id, PhotoPreviewMetadata(assetID: "latest-\($0.id)", pixelWidth: 1600, pixelHeight: 1000))
                })
            }, scenicCover: { place, fallback in
                scenicCalls += 1
                return place.id == "fixture-0" ? PhotoPreviewMetadata(assetID: "scenic-\(place.id)") : fallback
            })
        defer { model.setActive(false) }
        model.receive(index(count: 30)); model.setActive(true)
        await wait { model.recent.first?.coverPrepared == true }
        let item = model.recent[0]
        #expect(item.latestAssetID == nil)
        let rows = model.shelves.map { $0.items.map(\.id) }
        let revision = model.structureRevision
        model.visibilityChanged(item.id, visible: true)
        model.focusChanged("place-\(item.id)")
        #expect(item.thumbnail == nil)
        #expect(backend.requests.isEmpty)
        for _ in 0..<100 where !item.scenicPrepared { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(item.latestAssetID == "scenic-\(item.id)")
        #expect(backend.requests.map(\.key.assetID) == ["scenic-\(item.id)"])
        #expect(backend.requests.first?.key.usesOriginal == true)
        #expect(scenicCalls == 1, "Offscreen prepared cards must not initiate image analysis")
        #expect(model.shelves.map { $0.items.map(\.id) } == rows)
        #expect(model.structureRevision == revision)
        #expect(model.restoredFocusID == "place-\(item.id)")
        let request = try #require(backend.requests.first)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        backend.deliver(request, .init(image: image))
        let cover = try #require(item.thumbnail)
        model.visibilityChanged(item.id, visible: false)
        #expect(item.thumbnail === cover)
        model.visibilityChanged(item.id, visible: true)
        model.focusChanged("place-fixture-12")
        #expect(model.loadedCount == 25)
        #expect(item.thumbnail === cover, "A still-visible card must keep its image when focus extends the shelves")
        #expect(item.thumbnail?.image === image)
        let fallback = model.recent[1]
        model.visibilityChanged(fallback.id, visible: true)
        #expect(fallback.thumbnail == nil)
        for _ in 0..<100 where !fallback.scenicPrepared { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(backend.requests.map(\.key.assetID) == ["scenic-\(item.id)", "latest-\(fallback.id)"])
    }

    @Test func savedWinnerLoadsBeforeColdNeighborsAndStaysVisibleUntilRemoved() async throws {
        let latest = Covers()
        let backend = OverviewTestRequester()
        var stored = "first-final"
        var heldBatches: [[String: String]] = []
        let model = OverviewContentModel(images: .init(requester: backend, automaticScheduling: false),
            latestCovers: latest.load, savedCovers: { places, held in
                heldBatches.append(held)
                guard let first = places.first(where: { $0.id == "fixture-0" }) else { return [:] }
                return [first.id: .init(assetID: held[first.id] ?? stored)]
            }, scenicCover: { _, fallback in fallback })
        defer { model.setActive(false); latest.finishAll() }
        model.receive(index(count: 10))
        model.setActive(true)
        let first = model.recent[0]
        model.visibilityChanged(first.id, visible: true)
        await wait { latest.calls.count == 1 }
        #expect(!latest.calls[0].contains { $0.id == first.id })
        #expect(first.latestAssetID == "first-final")
        #expect(backend.requests.map(\.key.assetID) == ["first-final"])

        stored = "second-final"
        model.receive(index(count: 10, revision: 2))
        await wait { latest.calls.count == 2 }
        #expect(heldBatches.last?[first.id] == "first-final")
        #expect(first.latestAssetID == "first-final")
        model.invalidateImages(changed: ["some-neighbor"], removed: [])
        #expect(first.latestAssetID == "first-final")
        model.invalidateImages(changed: [], removed: ["first-final"])
        #expect(first.latestAssetID == nil)
        await wait { first.latestAssetID == "second-final" }
        #expect(heldBatches.last?[first.id] == nil)
    }

    @Test func cachedShelfCoverSurvivesLeavingTheRequestWindowAndUnrelatedLibraryChanges() async throws {
        let backend = OverviewTestRequester()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        backend.onRequest = { request, backend in backend.deliver(request, .init(image: image)) }
        var heldForValidation: [String: String] = [:]
        let model = OverviewContentModel(images: .init(requester: backend, automaticScheduling: false),
            latestCovers: { _ in [:] }, savedCovers: { places, held in
                heldForValidation.merge(held) { _, latest in latest }
                return Dictionary(uniqueKeysWithValues: places.map { ($0.id, PhotoPreviewMetadata(assetID: "cover-" + $0.id)) })
            }, scenicCover: { _, fallback in fallback })
        defer { model.setActive(false) }
        model.receive(index(count: 40))
        model.setActive(true)
        let item = model.shelves[0].items[0]
        model.visibilityChanged(item.id, visible: true)
        await wait { item.thumbnail?.image === image }
        let cover = try #require(item.thumbnail)
        model.visibilityChanged(item.id, visible: false)
        model.focusChanged("place-fixture-14")
        model.focusChanged("place-fixture-24")
        #expect(item.thumbnail?.image === image)
        model.invalidateImages(changed: ["unrelated"], removed: [])
        model.scrollChanged(moving: true)
        model.visibilityChanged(item.id, visible: true)
        #expect(item.thumbnail === cover)
        #expect(item.thumbnail?.image === image)
        #expect(backend.requests.filter { $0.key == cover.key }.count == 1)

        model.visibilityChanged(item.id, visible: false)
        model.receive(index(count: 40, revision: 2))
        await wait { heldForValidation[item.id] == cover.key.assetID }
        model.images.memoryWarning()
        #expect(cover.image == nil)
        model.visibilityChanged(item.id, visible: true)
        let reloaded = try #require(item.thumbnail)
        #expect(reloaded.image === image)
        #expect(backend.requests.filter { $0.key == cover.key }.count == 2)
        model.invalidateImages(changed: [], removed: [cover.key.assetID])
        #expect(reloaded.image == nil && item.thumbnail == nil)
    }

    @Test func openingRowPreparesOnlyItsFinalCoversBeforeFocusArrives() async {
        var evaluated: [String] = []
        var replies: [String: CheckedContinuation<PhotoPreviewMetadata?, Never>] = [:]
        let backend = OverviewTestRequester()
        let model = OverviewContentModel(images: .init(requester: backend, automaticScheduling: false),
            latestCovers: { places in
                Dictionary(uniqueKeysWithValues: places.map { ($0.id, PhotoPreviewMetadata(assetID: "latest-" + $0.id)) })
            }, savedCovers: { _, _ in [:] }, scenicCover: { place, _ in
                evaluated.append(place.id)
                return await withCheckedContinuation { replies[place.id] = $0 }
            })
        defer {
            model.setActive(false)
            for reply in replies.values { reply.resume(returning: nil) }
        }
        model.receive(index(count: 30))
        model.setActive(true)
        await wait { evaluated.count == PlaceCollection.homeRecentLimit }
        #expect(Set(evaluated) == Set(model.recent.map(\.id)))
        #expect(backend.requests.isEmpty)
        let first = model.recent[0]
        model.visibilityChanged(first.id, visible: true)
        replies.removeValue(forKey: first.id)?.resume(returning: .init(assetID: "complete-selection"))
        await wait { first.latestAssetID == "complete-selection" }
        #expect(backend.requests.map(\.key.assetID) == ["complete-selection"])
    }

    @Test func pageTopHandoffRejectsStaleShelfFocusUntilGeometryAndFocusAgree() {
        var handoff = OverviewFocusHandoff()
        let hero = OverviewFocusHandoff.entryID
        let previous = "place-fixture-15"
        handoff.restore(previous)
        #expect(handoff.accept(hero, atTop: true) == nil)
        #expect(handoff.handlesBack(hasFocus: true, belowTop: true))
        handoff.returnToTop()
        #expect(handoff.accept(previous, atTop: false) == nil)
        #expect(handoff.accept(hero, atTop: false) == nil)
        #expect(handoff.accept(previous, atTop: true) == nil)
        #expect(handoff.accept(hero, atTop: true) == hero)
        #expect(!handoff.handlesBack(hasFocus: true, belowTop: false))
        handoff.deactivate()
        handoff.restore(previous)
        #expect(handoff.accept(previous, atTop: false) == previous)
    }

    @Test func stillVisibleCardsOutrankNewlyAdjacentRowsDuringExpansion() {
        let retained = OverviewImageWindow.residentIndices(nearby: 15..<30, visible: [7, 8, 9, 15], focused: 24)
        #expect(Array(retained.prefix(5)) == [24, 7, 8, 9, 15])
        #expect(retained.count == 15)
        #expect(Set(retained).count == retained.count)
    }

    @Test func lateCoverDimensionsNeverRegroupHomeTiles() async {
        let covers = Covers()
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: covers.load)
        defer { model.setActive(false); covers.finishAll() }
        model.receive(index(count: 30)); model.setActive(true)
        await wait { covers.calls.count == 1 }
        let before = model.shelves.map { $0.items.map(\.id) }
        let revision = model.structureRevision
        model.visibilityChanged(model.shelves[0].items[0].id, visible: true)
        covers.finish(0, width: 800, height: 1_200)
        await wait { model.recent[0].coverPrepared }
        #expect(model.shelves.map { $0.items.map(\.id) } == before)
        #expect(model.structureRevision == revision)
        model.setActive(false); model.setActive(true)
        #expect(model.shelves.map { $0.items.map(\.id) } == before)
        #expect(model.structureRevision == revision)
    }

    @Test func yearGroupsKeepOneHeadingAcrossPaginationAndShortRowsKeepTheirScrollTarget() {
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: { _ in [:] })
        var snapshot = index(count: 30)
        let calendar = Calendar(identifier: .gregorian)
        snapshot.places = snapshot.places.enumerated().map { offset, place in
            let year = offset < 5 ? 2026 : offset < 13 ? 2025 : offset < 23 ? 2024 : 2023
            let date = calendar.date(from: DateComponents(year: year, month: 6, day: 30 - offset))!
            return TravelPlace(id: place.id, name: place.name, country: nil, coordinate: place.coordinate,
                               startDate: date, endDate: date, photoCount: 1, coverAssetID: place.coverAssetID)
        }
        model.receive(snapshot)
        #expect(model.shelves.filter(\.showsYearHeading).map(\.year) == [2025, 2024])
        #expect(model.shelves.map { $0.items.count } == [5, 3, 2])
        model.expand()
        #expect(model.shelves.filter(\.showsYearHeading).map(\.year) == [2025, 2024, 2023])
        #expect(model.shelves.map { $0.items.count } == [5, 3, 5, 5, 2])
        #expect(model.shelves.flatMap(\.items).map(\.id) == Array(snapshot.places.dropFirst(5).prefix(20)).map(\.id))
        for shelf in model.shelves {
            #expect(shelf.items.allSatisfy { calendar.component(.year, from: $0.place.endDate) == shelf.year })
            for item in shelf.items { #expect(model.scrollTarget("place-\(item.id)") == shelf.id) }
        }
        #expect(model.scrollTarget("place-fixture-18") == "places-shelf-4")
        let window = OverviewImageWindow.residentIndices(shelfRanges: [0..<5, 5..<10, 10..<13, 13..<18, 18..<23, 23..<25], focusedShelfIndex: 4)
        #expect(window == 13..<25, "The image window follows actual year rows rather than dividing the photo position by five")

        model.setActive(true)
        defer { model.setActive(false) }
        var updated = index(count: 30, revision: 2)
        updated.places = snapshot.places
        let old = updated.places[10]
        let changedDate = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        updated.places[10] = TravelPlace(id: old.id, name: old.name, country: old.country, coordinate: old.coordinate,
                                        startDate: old.startDate, endDate: changedDate, photoCount: old.photoCount, coverAssetID: old.coverAssetID)
        model.receive(updated)
        #expect(model.shelves.filter(\.showsYearHeading).map(\.year) == [2025, 2024, 2023],
                "Date edits keep the current grouping until the deferred browsing reorder")
        model.setActive(false); model.setActive(true)
        #expect(model.recent.first?.id == old.id)
        let headings = model.shelves.filter(\.showsYearHeading).map(\.year)
        #expect(headings.count == Set(headings).count)
    }

    @Test func coverQueryFailureKeepsNavigationAvailableWithoutRetryingOnEveryFocus() async {
        let failures = CoverFailures()
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: failures.load)
        defer { model.setActive(false) }
        model.receive(index(count: 20)); model.setActive(true)
        await wait { model.recent[0].coverFailed }
        for _ in 0..<20 { model.focusChanged("place-fixture-0"); model.focusChanged("place-fixture-1") }
        await Task.yield()
        #expect(failures.calls == 1)
        #expect(model.validFocusID("place-fixture-1") == "place-fixture-1")
        model.receive(index(count: 20, revision: 2))
        await wait { failures.calls == 2 }
    }

    @Test func coverBatchesAndFocusDoNotRebuildRowsOrWaitForLabels() async {
        let covers = Covers()
        let labels = Labels()
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false),
                                         latestCovers: covers.load, resolveLabels: labels.load)
        defer { model.setActive(false); covers.finishAll(); labels.finishAll() }
        model.receive(index(count: 50))
        model.setActive(true)
        await wait { covers.calls.count == 1 }
        #expect(covers.calls[0].count == 15)
        let firstRow = model.recent
        let revision = model.structureRevision
        for _ in 0..<100 { model.focusChanged("place-fixture-0"); model.focusChanged("place-fixture-1") }
        #expect(model.structureRevision == revision)
        #expect(model.recent[0] === firstRow[0])
        model.expand()
        covers.finishAll()
        await wait { covers.calls.count == 2 }
        #expect(covers.calls[1].count == 10)
        await wait { labels.calls.count == 1 }
        #expect(labels.calls.count == 1, "A slow geocoder must not block the next cover batch")
        #expect(model.loadedCount == 25)
    }

    @Test func lateCoverBatchCannotWriteIntoANewIndexWithTheSameCounts() async {
        let covers = Covers()
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: covers.load)
        defer { model.setActive(false); covers.finishAll() }
        let old = index(count: 10)
        model.receive(old); model.setActive(true)
        await wait { covers.calls.count == 1 }
        model.setActive(false)
        var next = index(count: 10, revision: 2)
        next.places[0].name = "New fixture"
        model.receive(next); model.setActive(true)
        await wait { covers.calls.count == 2 }
        covers.finish(0, prefix: "old-")
        await Task.yield()
        #expect(model.recent[0].latestAssetID == nil)
        covers.finish(1, prefix: "new-")
        await wait { model.recent[0].latestAssetID != nil }
        #expect(model.recent[0].latestAssetID == "new-fixture-0")
    }

    @Test func namesUpdateOnlyTheCardAndUnloadedLabelsAreRetainedForLaterExpansion() {
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: { _ in [:] })
        let snapshot = index(count: 30)
        model.receive(snapshot)
        let revision = model.structureRevision
        let card = model.recent[0]
        var first = snapshot.places[0]; first.name = "Resolved first"
        model.updateLabel(first)
        #expect(card === model.recent[0] && card.place.name == "Resolved first")
        var unloaded = snapshot.places[20]; unloaded.name = "Resolved later"
        model.updateLabel(unloaded)
        #expect(model.structureRevision == revision)
        model.expand()
        #expect(model.shelves.flatMap(\.items).first { $0.id == unloaded.id }?.place.name == "Resolved later")
    }

    @Test func homeDeduplicatesCitiesAndCollapsesDelayedMatchingLabels() {
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: { _ in [:] })
        var snapshot = index(count: 18)
        snapshot.places[0].name = "Paris"
        snapshot.places[0].country = "France"
        snapshot.places[1].name = "Paris"
        snapshot.places[1].country = "France"
        model.receive(snapshot)

        #expect(model.loadedCount == 15)
        #expect(Array(model.recent.map(\.id).prefix(2)) == ["fixture-0", "fixture-2"])
        #expect(!model.recent.contains { $0.id == "fixture-1" })

        var third = snapshot.places[2]
        third.name = "Paris"
        third.country = "France"
        model.focusChanged("place-fixture-2")
        let revision = model.structureRevision
        model.updateLabel(third)

        #expect(model.structureRevision == revision + 1)
        #expect(model.loadedCount == 15)
        #expect(!model.recent.contains { $0.id == "fixture-2" })
        #expect(model.recent.first?.id == "fixture-0")
        #expect(model.restoredFocusID == "place-fixture-0")
    }

    @Test func structuralReorderWaitsUntilReturnButRemovedPlaceLosesAccessImmediately() {
        let model = OverviewContentModel(images: .init(requester: OverviewTestRequester(), automaticScheduling: false), latestCovers: { _ in [:] })
        let original = index(count: 20)
        model.receive(original); model.setActive(true)
        model.focusChanged("place-fixture-3")
        var updated = index(count: 20, revision: 2)
        updated.places.removeAll { $0.id == "fixture-0" }
        let p = updated.places.removeLast()
        updated.places.append(TravelPlace(id: p.id, name: p.name, country: p.country, coordinate: p.coordinate,
                                         startDate: p.startDate, endDate: Date(timeIntervalSinceReferenceDate: 10_000), photoCount: p.photoCount, coverAssetID: p.coverAssetID))
        model.receive(updated)
        #expect(model.validFocusID("place-fixture-0") == "enter-globe")
        #expect(model.recent.first?.id == "fixture-1")
        #expect(model.restoredFocusID == "place-fixture-3")
        model.setActive(false); model.setActive(true)
        #expect(model.recent.first?.id == "fixture-19")
        #expect(model.validFocusID(model.restoredFocusID) == "place-fixture-3")
        model.setActive(false)
    }

    @Test func progressChangesAreScopedAndCompletionIsImmediate() async {
        let state = PreparationPresentationState()
        var progress = LibraryPreparationProgress(); progress.phase = .checking
        state.update(progress)
        for count in 1...100 { progress.checkedPhotos = count; state.update(progress) }
        #expect(state.progress.checkedPhotos == 0)
        for _ in 0..<60 where state.progress.checkedPhotos != 100 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.progress.checkedPhotos == 100)
        progress.phase = .complete; state.update(progress)
        #expect(state.progress.phase == .complete)
    }

    @Test func sqliteLatestCoverBatchUsesStableOrderingAndBoundsTheRequestedPlaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let fixture = SampleTravelIndex.make()
        try await store.save(fixture)
        let ids = fixture.index.places.map(\.id)
        let result = try await store.latestAssetIDs(for: ids)
        let previews = try await store.latestPhotoPreviews(for: ids)
        for id in ids {
            let expected = fixture.photos.filter { $0.placeID == id }.sorted {
                $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate
            }.first?.id
            #expect(result[id] == expected)
            if let photo = fixture.photos.first(where: { $0.id == expected }) {
                #expect(previews[id] == PhotoPreviewMetadata(photo))
            }
        }
        let bounded = try await store.latestAssetIDs(for: Array(repeating: "absent", count: 15) + ids)
        #expect(bounded.isEmpty)
        let reader = try await store.photoReadSnapshot()
        #expect(try await reader.latestAssetIDs(for: ids) == result)
        #expect(try await reader.placeSummariesForReading().count == fixture.index.places.count,
                "Cover lookup must not end a caller's existing WAL read transaction")
    }

    private func index(count: Int, revision: Double = 1) -> TravelIndex {
        .init(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSinceReferenceDate: revision),
              sourcePhotoCount: count, locatedPhotoCount: count, places: (0..<count).map { i in
                  TravelPlace(id: "fixture-\(i)", name: "Fixture \(i)", country: nil,
                              coordinate: GeoCoordinate(latitude: 20, longitude: Double(i)),
                              startDate: Date(timeIntervalSinceReferenceDate: 1_000 - Double(i)),
                              endDate: Date(timeIntervalSinceReferenceDate: 1_000 - Double(i)), photoCount: 1, coverAssetID: "cover-\(i)")
              }, journeys: [])
    }

    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }

    @MainActor private final class Covers {
        var calls: [[TravelPlace]] = []
        var pending: [Int: CheckedContinuation<[String: PhotoPreviewMetadata], Never>] = [:]
        func load(_ places: [TravelPlace]) async -> [String: PhotoPreviewMetadata] {
            let number = calls.count; calls.append(places)
            return await withCheckedContinuation { pending[number] = $0 }
        }
        func finish(_ number: Int, prefix: String = "image-", width: Int = 0, height: Int = 0) {
            pending.removeValue(forKey: number)?.resume(returning: Dictionary(uniqueKeysWithValues: calls[number].map { ($0.id, PhotoPreviewMetadata(assetID: prefix + $0.id, pixelWidth: width, pixelHeight: height)) }))
        }
        func finishAll() { for key in Array(pending.keys) { finish(key) } }
    }
    @MainActor private final class CoverFailures {
        var calls = 0
        func load(_ places: [TravelPlace]) async throws -> [String: PhotoPreviewMetadata] {
            calls += 1
            throw TravelIndexStoreError.database("Fixture unavailable")
        }
    }
    @MainActor private final class Labels {
        var calls: [[String]] = []
        var pending: [CheckedContinuation<Void, Never>] = []
        func load(_ ids: [String]) async { calls.append(ids); await withCheckedContinuation { pending.append($0) } }
        func finishAll() { for item in pending { item.resume() }; pending = [] }
    }
}
