import Foundation
import SQLite3
import Testing
@testable import PhotoEarth

@Suite(.serialized)
@MainActor
struct LibraryPreparationTests {
    private func photo(_ id: String, lat: Double = 10, lon: Double = 20, time: Double = 1000, favorite: Bool = false) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: GeoCoordinate(latitude: lat, longitude: lon),
                         creationDate: Date(timeIntervalSince1970: time), pixelWidth: 1600, pixelHeight: 1000, isFavorite: favorite)
    }
    private func store() -> (SQLiteTravelIndexStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite")), folder)
    }
    private func activate(_ store: SQLiteTravelIndexStore, _ photos: [PhotoAssetRecord], token: String = "safe") async throws -> TravelIndex {
        let run = try await store.beginMetadataScan(copyCurrent: false)
        for start in stride(from: 0, to: photos.count, by: 256) {
            _ = try await store.stageMetadata(PhotoMetadataBatch(records: Array(photos[start..<min(start + 256, photos.count)])), run: run)
        }
        return try await store.activateMetadata(run: run, sourcePhotoCount: photos.count, token: Data(token.utf8), fullCheck: true,
                                                 authorization: "authorized", configuration: .init(), progress: { _, _ in })
    }

    @Test func firstAuthorizationAcceptsTheStoreFilterAndHandsOffToHome() async throws {
        let initialFilter = UserDefaults.standard.object(forKey: "photoEarth.hidesTransitPhotos") as? Bool ?? true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("first.sqlite"),
                                          hidesTransitPhotos: !initialFilter)
        let library = PreparationTestLibrary(records: [photo("first", favorite: true)], access: .notDetermined)
        let model = makeModel(library, store) { _ in PlaceDisplayLabel(city: "Town", country: "Country") }
        await model.start()
        #expect(model.phase == .welcome)
        await library.setAccess(.authorized)
        await model.requestAccessAndScan()
        try await until { model.phase == .globe && !model.isPreparationPresented }
        #expect(model.index?.visiblePhotoCount == 1)
        #expect(model.hidesTransitPhotos == !initialFilter)
        await model.setSceneActive(false)
    }

    @Test func streamingClusteringMatchesExistingCentersIDsCoversAndJourneys() async throws {
        var records: [PhotoAssetRecord] = []
        for i in 0..<1800 {
            let latitude = i < 900 ? 40.0 + Double(i % 7) / 1000 : -30.0
            let longitude = i < 900 ? 120.0 : 150.0
            records.append(photo("asset-\(i)", lat: latitude, lon: longitude, time: Double(i) * 200, favorite: i % 31 == 0))
        }
        let original = TravelClusterer().makeIndex(records: records)
        var stream = StreamingTravelClusterer()
        var places: [TravelPlace] = []
        for record in records { if let place = stream.append(record) { places.append(place) } }
        if let place = stream.place { places.append(place) }
        #expect(places == original.index.places)
        #expect(StreamingTravelClusterer.journeys(places, configuration: .init()) == original.index.journeys)
    }

    @Test func fiftyThousandPhotosInOnePlaceUseStreamingMembershipAndBoundedPages() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let records = (0..<50_000).map { photo("photo-\($0)", time: Double($0)) }
        let index = try await activate(db, records)
        #expect(index.locatedPhotoCount == 50_000)
        #expect(index.places.count == 1)
        #expect(index.places[0].photoCount == 50_000)
        let page = try await db.photoPage(for: [index.places[0].id], offset: 0, limit: 1000)
        #expect(page.records.count == 48)
        #expect(page.nextOffset == 48)
        #expect(page.records.first?.id == "photo-49999")
    }

    @Test func rebuildReusesExactBasisEvenWhenPlaceIDChangesAndKeepsLateLabels() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = try await activate(db, [photo("a"), photo("b")])
        let run = try await db.beginMetadataScan(copyCurrent: false)
        _ = try await db.stageMetadata(PhotoMetadataBatch(records: [photo("b")]), run: run)
        var named = old.places[0]; named.name = "测试城市"; named.country = "测试国家"
        try await db.updatePlaceNames([named]) // Arrives AFTER staging started.
        let rebuilt = try await db.activateMetadata(run: run, sourcePhotoCount: 1, token: Data("next".utf8), fullCheck: true,
                                                    authorization: "authorized", configuration: .init(), progress: { _, _ in })
        #expect(rebuilt.places[0].id != old.places[0].id)
        #expect(rebuilt.places[0].name == named.name)
        #expect(rebuilt.places[0].country == named.country)
        #expect(try await db.placeLabelJobs(now: Date()).isEmpty)
    }

    @Test func sameIDWithEditedCoordinateDoesNotInheritOldCityOrAcceptStaleWrite() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        var old = try await activate(db, [photo("a")]).places[0]
        old.name = "旧城市"; old.country = "旧国家"
        try await db.updatePlaceNames([old])
        let changed = try await activate(db, [photo("a", lat: -25, lon: 60)])
        #expect(changed.places[0].id == old.id)
        #expect(!PlaceDisplayLabel(place: changed.places[0]).isComplete)
        try await db.updatePlaceNames([old])
        let loaded = try #require(try await db.load())
        #expect(!PlaceDisplayLabel(place: loaded.places[0]).isComplete)
    }

    @Test func validEmptySnapshotIsCommittedWithTokenAndOldLibraryDoesNotRevive() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await activate(db, [photo("old")])
        _ = try await activate(db, [], token: "empty-safe")
        let reopened = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let value = try #require(try await reopened.load())
        #expect(value.places.isEmpty && value.locatedPhotoCount == 0)
        #expect(try await reopened.loadSyncState().token == Data("empty-safe".utf8))
    }

    @Test func staleStagingRunCannotReplaceCurrentDataOrAdvanceToken() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = try await activate(db, [photo("old")], token: "old-safe")
        let stale = try await db.beginMetadataScan(copyCurrent: false)
        _ = try await db.beginMetadataScan(copyCurrent: true)
        await #expect(throws: LibraryPreparationError.self) {
            try await db.activateMetadata(run: stale, sourcePhotoCount: 0, token: Data("wrong".utf8), fullCheck: true,
                                           authorization: "authorized", configuration: .init(), progress: { _, _ in })
        }
        #expect(try await db.load() == old)
        #expect(try await db.loadSyncState().token == Data("old-safe".utf8))
    }

    @Test func wallReadTransactionKeepsPagingStableAcrossAtomicReplacement() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let records = (0..<55).map { photo("p-\($0)", time: Double($0)) }
        let old = try await activate(db, records)
        let reader = try await db.photoReadSnapshot()
        let first = try await reader.photoPage(for: [old.places[0].id], offset: 0, limit: 48)
        _ = try await activate(db, records + [photo("new", time: 90)])
        let second = try await reader.photoPage(for: [old.places[0].id], offset: 48, limit: 48)
        #expect(first.records.count == 48 && second.records.count == 7)
        #expect(Set((first.records + second.records).map(\.id)).count == 55)
        #expect(!second.records.contains { $0.id == "new" })
        let active = try #require(try await db.load())
        #expect(try await db.photoPage(for: [active.places[0].id], offset: 0, limit: 48).records.first?.id == "new")
    }

    @Test func partialResultsAndRetryDateSurviveRestartWithoutCountingAsComplete() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let index = try await activate(db, [photo("a")])
        let retry = Date().addingTimeInterval(3600)
        _ = try await db.recordLabelAttempt(index.places[0], label: PlaceDisplayLabel(city: "", country: "测试国家"), attempts: 1, nextRetryAt: retry)
        let reopened = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let loaded = try #require(try await reopened.load())
        #expect(loaded.places[0].country == "测试国家")
        #expect(!PlaceDisplayLabel(place: loaded.places[0]).isComplete)
        #expect(try await reopened.placeLabelJobs(now: Date()).isEmpty)
        #expect(try await reopened.placeLabelJobs(now: retry.addingTimeInterval(1)).count == 1)
    }

    @Test func stableMissingPlacemarkIsPersistedWithoutSchedulingAnotherRetry() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let index = try await activate(db, [photo("a")])
        _ = try await db.recordLabelAttempt(
            index.places[0],
            label: nil,
            attempts: 1,
            nextRetryAt: nil,
            terminal: true
        )

        let reopened = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        #expect(try await reopened.isLabelTerminal(for: index.places[0]))
        #expect(try await reopened.placeLabelJobs(now: .distantFuture).isEmpty)
        #expect(try await reopened.nextLabelRetry() == nil)

        let catalog = try JourneyPlaceCatalog.shared
        let tokyo = try catalog.label(.init(latitude: 35.686963, longitude: 139.749462), locale: Locale(identifier: "zh-Hans"))
        #expect(tokyo.isComplete && tokyo.country == "日本")
        let ocean = try catalog.label(.init(latitude: 0, longitude: -140), locale: Locale(identifier: "en"))
        #expect(ocean.offlinePlaceID == nil && ocean.country == nil)
    }

    @Test func existingVersionThreeDatabaseAddsTerminalLabelStateWithoutRebuild() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("index.sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        guard let connection else { return }
        let legacySchema = """
            CREATE TABLE place_label_cache (
                basis TEXT PRIMARY KEY, city TEXT NOT NULL, country TEXT,
                attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL,
                updated_at REAL NOT NULL, complete INTEGER NOT NULL DEFAULT 0
            )
            """
        #expect(sqlite3_exec(connection, legacySchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close_v2(connection)

        let store = SQLiteTravelIndexStore(databaseURL: url)
        let index = try await activate(store, [photo("a")])
        _ = try await store.recordLabelAttempt(
            index.places[0],
            label: nil,
            attempts: 1,
            nextRetryAt: nil,
            terminal: true
        )
        #expect(try await store.isLabelTerminal(for: index.places[0]))
        #expect(try await store.load()?.locatedPhotoCount == 1)
    }

    @Test func initialCheckpointWithoutIndexSurvivesLoadAndKeepsUserPause() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        var state = LibraryPreparationProgress(); state.phase = .paused; state.userPaused = true; state.needsMetadata = true
        try await db.savePreparationProgress(state)
        #expect(try await db.load() == nil)
        #expect(try await db.loadPreparationProgress()?.userPaused == true)
    }

    @Test func wholeLibraryPreparationPassesFirstFifteenWithoutAnyBrowsing() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let records = (0..<40).map { photo("p-\($0)", lon: Double($0) * 3, time: Double($0) * 1000) }
        let library = PreparationTestLibrary(records: records)
        var calls = 0
        let model = makeModel(library, db) { _ in calls += 1; return PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        #expect(calls == 40)
        #expect(model.preparationProgress.completePlaces == 40)
        #expect(model.preparationProgress.coveredPhotos == 40)
        try await until { model.phase == .globe }
        #expect(model.phase == .globe)
        #expect(try await db.load()?.places.allSatisfy { PlaceDisplayLabel(place: $0).isComplete } == true)
        #expect(library.signal.hasObserver)
        await model.setSceneActive(false)
    }

    @Test func fullScanCapturesTokenBeforeSnapshotAndReplaysOldDatedImport() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("first")], changes: [PhotoMetadataBatch(records: [photo("old-import", lat: -35, time: -10_000)])])
        let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        #expect(await library.events.prefix(3) == ["token", "snapshot", "changes"])
        #expect(model.index?.locatedPhotoCount == 2)
        #expect(try await db.loadSyncState().token == Data("safe-change".utf8))
        await model.setSceneActive(false)
    }

    @Test func missingCityFinishesFinitePassAndKeepsCoordinatesBrowsable() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(PreparationTestLibrary(records: [photo("a")]), db) { _ in PlaceDisplayLabel(city: "", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .partial }
        #expect(model.canBrowsePreparedLibrary)
        #expect(model.preparationProgress.completePlaces == 0)
        #expect(model.preparationProgress.fraction == 0)
        #expect(model.preparationProgress.attemptedPlaces == 1)
        await model.setSceneActive(false)
    }

    @Test func pausedLibraryRestoresWithoutAutomaticRequestsThenResumesOnlyMissingPlaces() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let records = [photo("a"), photo("b", lat: -35)]
        let library = PreparationTestLibrary(records: records)
        var calls = 0
        let model = makeModel(library, db) { _ in
            calls += 1
            if calls == 2 { try await Task.sleep(for: .seconds(30)) }
            return PlaceDisplayLabel(city: "测试城市", country: "测试国家")
        }
        await model.start()
        try await until { calls == 2 }
        await model.pausePreparation()
        #expect(try await db.loadPreparationProgress()?.userPaused == true)
        var resumedCalls = 0
        let restarted = makeModel(PreparationTestLibrary(records: records), db) { _ in
            resumedCalls += 1; return PlaceDisplayLabel(city: "测试城市", country: "测试国家")
        }
        await restarted.start()
        #expect(restarted.preparationProgress.userPaused)
        #expect(resumedCalls == 0)
        await restarted.resumePreparation()
        try await until { restarted.preparationProgress.phase == .complete }
        #expect(resumedCalls == 1)
        await restarted.setSceneActive(false)
    }

    @Test func pauseIsDurableWhileVisiblePhotoStillAwaitsSharedLookup() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        var calls = 0
        let model = makeModel(PreparationTestLibrary(records: [photo("shared")]), db) { _ in
            calls += 1
            try await Task.sleep(for: .seconds(2))
            return PlaceDisplayLabel(city: "测试城市", country: "测试国家")
        }
        await model.start()
        try await until { calls == 1 }
        let id = try #require(model.index?.places.first?.id)
        let foreground = Task { await model.resolvePlaceLabels(for: [id]) }
        try await until { model.placeLabelStates[id] == .loading }
        try await Task.sleep(for: .milliseconds(20))
        let pausing = Task { await model.pausePreparation() }
        var saved = false
        for _ in 0..<20 {
            saved = try await db.loadPreparationProgress()?.userPaused == true
            if saved { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved, "User pause must be durable without waiting for the other subscriber")
        foreground.cancel()
        await foreground.value; await pausing.value
        #expect(calls == 1)
        await model.setSceneActive(false)
    }

    @Test func deniedPermissionNeverDisplaysPreviouslyCachedPrivateIndex() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await activate(db, [photo("private")])
        let library = PreparationTestLibrary(records: [], access: .denied)
        let model = makeModel(library, db) { _ in Issue.record("Should not query after permission loss"); return nil }
        await model.start()
        #expect(model.phase == .denied && model.index == nil)
        #expect(try await db.load()?.locatedPhotoCount == 1, "Denied is not an empty-library deletion")
    }

    @Test func emptyPhotoKitDeltaAdvancesCheckWithoutStagingOrRepublishingTheIndex() async throws {
        let (db, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = [photo("visible", favorite: true)]
        _ = try await activate(db, photos, token: "before")
        let baseline = try await db.loadSyncState()
        var connection: OpaquePointer?
        try #require(sqlite3_open(folder.appendingPathComponent("index.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, """
            CREATE TRIGGER forbid_staging BEFORE INSERT ON scan_photos
            BEGIN SELECT RAISE(ABORT, 'unexpected full copy'); END
            """, nil, nil, nil) == SQLITE_OK)

        let library = PreparationTestLibrary(records: photos)
        let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "Town", country: "Country") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        let saved = try await db.loadSyncState()
        #expect(saved.token == Data("safe-change".utf8))
        #expect(saved.lastFullCheck == baseline.lastFullCheck)
        #expect(await library.events == ["changes"])
        #expect(model.index?.visiblePhotoCount == 1)
        let stale = LibraryChangeResult(token: Data("late".utf8), sourcePhotoCount: 1, changedAssetCount: 0)
        #expect(try await !db.commitUnchanged(from: baseline, changes: stale, authorization: "authorized"))
        let miscount = LibraryChangeResult(token: Data("wrong".utf8), sourcePhotoCount: 2, changedAssetCount: 0)
        #expect(try await !db.commitUnchanged(from: saved, changes: miscount, authorization: "authorized"))
        #expect(try await db.loadSyncState().token == saved.token)
        await model.setSceneActive(false)
    }

    @Test func weeklyReviewLimitedAccessAndAbandonedStagingReconcileTheSnapshot() async throws {
        enum Reason: CaseIterable { case weekly, limited, interruptedStaging }
        for reason in Reason.allCases {
            let (db, folder) = store()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await activate(db, [photo("old", favorite: true)])
            if reason == .weekly {
                var sql: OpaquePointer?
                try #require(sqlite3_open(folder.appendingPathComponent("index.sqlite").path, &sql) == SQLITE_OK)
                defer { sqlite3_close(sql) }
                try #require(sqlite3_exec(sql, "UPDATE library_sync SET value='1' WHERE key='full_check'", nil, nil, nil) == SQLITE_OK)
            } else if reason == .interruptedStaging {
                _ = try await db.beginMetadataScan(copyCurrent: true)
            }
            let library = PreparationTestLibrary(records: [photo("current", favorite: true)],
                                                 access: reason == .limited ? .limited : .authorized)
            let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "Town", country: "Country") }
            await model.start()
            try await until { model.preparationProgress.phase == .complete }
            #expect(await library.events.contains("snapshot"))
            let place = try #require(model.index?.places.first)
            #expect(try await db.photoPage(for: [place.id], offset: 0, limit: 1).records.first?.id == "current")
            await model.setSceneActive(false)
        }
    }

    @Test func incrementalFavoriteEditKeepsClusteringAndDoesNotGeocodeAgain() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("a")])
        var calls = 0
        let model = makeModel(library, db) { _ in calls += 1; return PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        let date = try #require(model.index?.generatedAt)
        let oldProgressDate = model.preparationProgress.updatedAt
        await library.enqueue([PhotoMetadataBatch(records: [photo("a", favorite: true)], removedIDs: ["a"])])
        await model.updateLibrary()
        try await until { model.preparationProgress.phase == .complete && model.preparationProgress.updatedAt > oldProgressDate }
        #expect(model.index?.generatedAt == date)
        #expect(calls == 1)
        let id = try #require(model.index?.places.first?.id)
        #expect(try await db.photoPage(for: [id], offset: 0, limit: 1).records.first?.isFavorite == true)
        await model.setSceneActive(false)
    }

    @Test func observerReplaysGPSDateDeletionAndPreviouslyUnlocatedImport() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("edited"), photo("deleted", lat: -20), photo("gps-removed", lat: 45)])
        let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        let previousDate = try #require(model.index?.generatedAt)
        let edited = photo("edited", lat: 60, lon: -70, time: -10000)
        let added = photo("formerly-no-gps", lat: 30, lon: 80, time: -20000)
        await library.enqueue([PhotoMetadataBatch(records: [edited, added], removedIDs: ["edited", "deleted", "gps-removed", "formerly-no-gps"])])
        library.signal.fire()
        try await until { model.preparationProgress.phase == .complete && model.index?.generatedAt != previousDate }
        #expect(model.index?.locatedPhotoCount == 2)
        let ids = try #require(model.index?.places.map(\.id))
        let page = try await db.photoPage(for: ids, offset: 0, limit: 48)
        #expect(page.records.map(\.id) == ["edited", "formerly-no-gps"])
        #expect(page.records.first?.coordinate == edited.coordinate)
        #expect(page.records.first?.creationDate == edited.creationDate)
        #expect(model.excludedAssetIDs.isSuperset(of: ["deleted", "gps-removed"]))
        #expect(await library.events.filter { $0 == "snapshot" }.count == 1)
        await model.setSceneActive(false)
    }

    @Test func expiredIncrementalTokenFallsBackToNewSnapshotWithoutLosingNames() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("existing")])
        var calls = 0
        let model = makeModel(library, db) { _ in calls += 1; return PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        let before = model.preparationProgress.updatedAt
        await library.expireNextChangeToken()
        await model.updateLibrary()
        try await until { model.preparationProgress.phase == .complete && model.preparationProgress.updatedAt > before }
        #expect(await library.events.suffix(4) == ["changes", "token", "snapshot", "changes"])
        #expect(model.index?.locatedPhotoCount == 1)
        #expect(calls == 1)
        await model.setSceneActive(false)
    }

    @Test func permissionLossDuringObservationHidesContentAndDoesNotDeadlockWorker() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("private")])
        let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "测试城市", country: "测试国家") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete }
        await library.setAccess(.denied)
        library.signal.fire()
        try await until { model.phase == .denied && model.index == nil && !library.signal.hasObserver }
        #expect(try await db.load()?.locatedPhotoCount == 1)
        await library.setAccess(.authorized)
        await model.setSceneActive(true)
        try await until { model.preparationProgress.phase == .complete && model.index != nil }
        await model.setSceneActive(false)
    }

    @Test func oldWallLimitsFullReplacementsUntilItsReadLeaseCloses() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await activate(db, [photo("old")])
        var reader: SQLiteTravelIndexStore? = try await db.photoReadSnapshot()
        #expect(reader != nil)
        #expect(await db.canActivateMetadata())
        _ = try await activate(db, [photo("new")])
        #expect(!(await db.canActivateMetadata()))
        reader = nil
        for _ in 0..<100 {
            if await db.canActivateMetadata() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await db.canActivateMetadata())
    }

    @Test func firstMetadataCommitEntersGlobeWhileSlowLabelsContinue() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(PreparationTestLibrary(records: [photo("ready")]), db) { _ in
            try await Task.sleep(for: .seconds(10))
            return PlaceDisplayLabel(city: "City", country: "Country")
        }
        await model.start()
        try await until { model.phase == .globe }
        #expect(model.isInitialLibraryReady && !model.isPreparationPresented)
        #expect(model.index?.locatedPhotoCount == 1)
        #expect(model.preparationProgress.completePlaces == 0)
        await model.setSceneActive(false)
    }

    @Test func aRebuildQueuedBehindInitialLabelsPublishesItsActualStartedMode() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("ready")])
        var releaseLookup: CheckedContinuation<Void, Never>?
        var lookups = 0
        defer { releaseLookup?.resume() }
        let model = makeModel(library, db) { _ in
            lookups += 1
            if lookups == 1 { await withCheckedContinuation { releaseLookup = $0 } }
            return PlaceDisplayLabel(city: "City", country: "Country")
        }
        await model.start()
        try await until { releaseLookup != nil && model.phase == .globe }
        #expect(model.preparationProgress.mode == .initial)
        #expect(model.preparationProgress.phase == .labeling)

        await model.updateLibrary(.rebuild)
        #expect(model.isPreparationPresented)
        #expect(model.preparationProgress.mode == .initial,
                "A queued rebuild must not pretend to have started while the old lookup is still active")
        #expect(await library.events.filter { $0 == "snapshot" }.count == 1)
        releaseLookup?.resume()
        releaseLookup = nil

        try await until {
            model.preparationProgress.mode == .rebuild && model.preparationProgress.phase == .complete
        }
        #expect(await library.events.filter { $0 == "snapshot" }.count == 2,
                "The mode label must correspond to an actual second full scan")
        #expect(try await db.loadPreparationProgress()?.mode == .rebuild)
        #expect(model.index?.locatedPhotoCount == 1)
        #expect(lookups == 1, "The queued rebuild preserves the label completed by the previous pass")
        await model.setSceneActive(false)
    }

    @Test func inspectingPreparationKeepsFocusAfterMetadataCommit() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(PreparationTestLibrary(records: [photo("ready")]), db) { _ in
            try await Task.sleep(for: .seconds(10))
            return PlaceDisplayLabel(city: "City", country: "Country")
        }
        await model.start()
        model.retainPreparationFocus()
        try await until { model.isInitialLibraryReady }
        try await Task.sleep(for: .milliseconds(1550))
        #expect(model.isPreparationPresented && model.phase == .scanning)
        model.closePreparation()
        #expect(model.phase == .globe)
        await model.setSceneActive(false)
    }

    @Test(arguments: [false, true])
    func initialHandoffResumesAfterBackgroundUnlessUserOwnsPreparation(retainsFocus: Bool) async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(PreparationTestLibrary(records: [photo("ready")]), db) { _ in
            try await Task.sleep(for: .seconds(10))
            return PlaceDisplayLabel(city: "City", country: "Country")
        }
        await model.start()
        try await until { model.isInitialLibraryReady }
        if retainsFocus { model.retainPreparationFocus() }
        await model.setSceneActive(false)
        try await Task.sleep(for: .milliseconds(1550))
        #expect(model.phase == .scanning && model.isPreparationPresented,
                "The first reveal cannot run while the app is in the background")
        await model.setSceneActive(true)
        if retainsFocus {
            try await Task.sleep(for: .milliseconds(1550))
            #expect(model.phase == .scanning && model.isPreparationPresented)
        } else {
            try await until { model.phase == .globe }
            #expect(!model.isPreparationPresented)
        }
        await model.setSceneActive(false)
    }

    @Test func initialReadableEmptyLibraryEntersExplicitEmptyState() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel(PreparationTestLibrary(records: []), db) { _ in
            Issue.record("An empty index has no place-name requests")
            return PlaceDisplayLabel(city: "", country: "")
        }
        await model.start()
        try await until { model.phase == .empty }
        #expect(!model.isPreparationPresented)
        model.closePreparation()
        #expect(model.phase == .empty)
        await model.setSceneActive(false)
    }

    @Test(arguments: [false, true])
    func undecidedAuthorizationStaysAtWelcomeAcrossStartupAndForeground(foregroundFirst: Bool) async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("not-yet-readable")], access: .notDetermined)
        let model = makeModel(library, db) { _ in
            Issue.record("Welcome must not request place names before authorization")
            return PlaceDisplayLabel(city: "", country: "")
        }
        if foregroundFirst { await model.setSceneActive(true) }
        await model.start()
        if !foregroundFirst { await model.setSceneActive(true) }
        #expect(model.phase == .welcome)
        #expect(model.index == nil && !model.canBrowsePreparedLibrary)
        #expect(!model.isPreparationPresented)
        #expect(await library.events.isEmpty)
        #expect(!library.signal.hasObserver)

        await model.setSceneActive(false)
        await model.setSceneActive(true)
        #expect(model.phase == .welcome)
        #expect(model.index == nil)
        #expect(await library.authorizationStatus() == .notDetermined)
        #expect(await library.events.isEmpty)
        await model.setSceneActive(false)
    }

    @Test(arguments: [PhotoLibraryAccess.denied, .restricted])
    func deniedForegroundKeepsPrivateCacheHiddenAndUndecidedReentryShowsWelcome(access: PhotoLibraryAccess) async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await activate(db, [photo("cached-before-permission-change")])
        let library = PreparationTestLibrary(records: [], access: access)
        let model = makeModel(library, db) { _ in
            Issue.record("Denied access must never read private place names")
            return PlaceDisplayLabel(city: "", country: "")
        }
        await model.start()
        await model.setSceneActive(true)
        #expect(model.phase == .denied)
        #expect(model.index == nil && !model.canBrowsePreparedLibrary)
        #expect(!library.signal.hasObserver)

        await model.setSceneActive(false)
        await library.setAccess(.notDetermined)
        await model.setSceneActive(true)
        #expect(model.phase == .welcome)
        #expect(model.index == nil && !model.isPreparationPresented)
        #expect(await library.events.isEmpty)
        #expect(try await db.load()?.locatedPhotoCount == 1,
                "Changing authorization hides private state without modifying its derived cache")
        await model.setSceneActive(false)
    }

    @Test func authorizationResetClearsAnAlreadyVisibleLibraryBeforeWelcomeReentry() async throws {
        let (db, folder) = store(); defer { try? FileManager.default.removeItem(at: folder) }
        let library = PreparationTestLibrary(records: [photo("previously-authorized")])
        let model = makeModel(library, db) { _ in PlaceDisplayLabel(city: "City", country: "Country") }
        await model.start()
        try await until { model.preparationProgress.phase == .complete && model.index != nil }
        model.closePreparation()
        #expect(model.phase == .globe)

        await model.setSceneActive(false)
        await library.setAccess(.notDetermined)
        await model.setSceneActive(true)
        #expect(model.phase == .welcome)
        #expect(model.index == nil && !model.canBrowsePreparedLibrary)
        #expect(!model.isPreparationPresented && !model.isInitialLibraryReady)
        try await until { !library.signal.hasObserver }
        #expect(!library.signal.hasObserver)
        #expect(try await db.load()?.locatedPhotoCount == 1)
        await model.setSceneActive(false)
    }

    private func makeModel(_ library: PreparationTestLibrary, _ store: SQLiteTravelIndexStore,
                           lookup: @escaping PlaceLabelResolver.Lookup) -> AppModel {
        AppModel(photoLibrary: library, indexStore: store, preferencesStore: MemoryPreferenceStore(),
                 clusterer: TravelClusterer(), placeLabelResolver: PlaceLabelResolver(lookup: lookup),
                 automaticallyMaintainsLibrary: true)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

private actor PreparationTestLibrary: PhotoLibraryUpdating {
    let signal = PreparationTestSignal()
    var records: [PhotoAssetRecord]
    var changes: [PhotoMetadataBatch]
    var access: PhotoLibraryAccess
    var expiresNext = false
    private(set) var events: [String] = []
    init(records: [PhotoAssetRecord], changes: [PhotoMetadataBatch] = [], access: PhotoLibraryAccess = .authorized) {
        self.records = records; self.changes = changes; self.access = access
    }
    func authorizationStatus() async -> PhotoLibraryAccess { access }
    func requestAuthorization() async -> PhotoLibraryAccess { access }
    func scanLocatedPhotos() async throws -> PhotoLibraryScan { PhotoLibraryScan(sourcePhotoCount: records.count, locatedPhotos: records) }
    func currentChangeToken() async throws -> Data { events.append("token"); return Data("start".utf8) }
    func enumeratePhotos(_ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> Int {
        events.append("snapshot")
        try await receive(PhotoMetadataBatch(records: records, checked: records.count, total: records.count))
        return records.count
    }
    func enumerateChanges(since token: Data, _ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> LibraryChangeResult {
        events.append("changes")
        if expiresNext { expiresNext = false; throw LibraryPreparationError.expiredToken }
        let pending = changes; changes = []
        for batch in pending {
            try await receive(batch)
            records.removeAll { existing in batch.removedIDs.contains(existing.id) || batch.records.contains(where: { $0.id == existing.id }) }
            records.append(contentsOf: batch.records)
        }
        return LibraryChangeResult(token: Data("safe-change".utf8), sourcePhotoCount: records.count,
                                   changedAssetCount: pending.reduce(0) { $0 + $1.records.count + $1.removedIDs.count })
    }
    func expireNextChangeToken() { expiresNext = true }
    func setAccess(_ access: PhotoLibraryAccess) { self.access = access }
    func enqueue(_ batches: [PhotoMetadataBatch]) { changes.append(contentsOf: batches) }
    nonisolated func observeChanges(_ callback: @escaping @Sendable () -> Void) { signal.set(callback) }
    nonisolated func stopObservingChanges() { signal.set(nil) }
}

private nonisolated final class PreparationTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func fire() { lock.lock(); let callback = callback; lock.unlock(); callback?() }
    var hasObserver: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    func set(_ callback: (@Sendable () -> Void)?) { lock.lock(); defer { lock.unlock() }; self.callback = callback }
}
