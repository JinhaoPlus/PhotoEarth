import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoEarth

struct JourneyScanGateTests {
    @Test func everyAssetReceivesExactlyOneReasonInPriorityOrder() {
        for mask in 0..<64 {
            func bit(_ n: Int) -> Bool { mask & (1 << n) != 0 }
            for camera in [CameraEvidence.unknown, .identified, .confirmedMissing] {
                let reason = TravelScanDecision.decide(available: bit(0), excluded: bit(1), screen: bit(2),
                    dated: bit(3), located: bit(4), evidence: camera, excludesMissingCamera: bit(5))
                let expected: TravelScanDecision
                if !bit(0) { expected = .unavailable }
                else if bit(1) { expected = .excludedAlbum }
                else if bit(2) { expected = .screenCapture }
                else if !bit(3) { expected = .invalidDate }
                else if !bit(4) { expected = .missingLocation }
                else if camera == .unknown { expected = .pendingCamera }
                else if camera == .confirmedMissing && bit(5) { expected = .noCamera }
                else { expected = .eligible }
                #expect(reason == expected)
                #expect(reason.included == (expected == .eligible || expected == .pendingCamera))
            }
        }
    }

    @Test func publicationTransitionsWithdrawStaleMembershipAndReuseStableIdentity() throws {
        func key(_ scope: String = "album-a", _ revision: Int = 1, _ locale: String = "en",
                 _ catalog: String = "v1", _ access: String = "authorized") -> ScanPublicationKey {
            .init(access: access, scope: scope, cameraRevision: revision, catalog: catalog, locale: locale)
        }
        let old = try key().serialized()
        #expect(key().transition(from: old) == .reuse)
        #expect(key("album-a", 2).transition(from: old) == .rebuild)
        #expect(key("album-a", 2).previousCameraRevision(from: old) == 1)
        #expect(key("album-b", 2).previousCameraRevision(from: old) == nil)
        #expect(key("album-a", 1, "ja").transition(from: old) == .rebuild)
        #expect(key("album-a", 1, "en", "v2").transition(from: old) == .rebuild)
        #expect(key("album-a", 1, "en", "v2").canRegroupStoredMetadata(from: old))
        #expect(!key("album-a", 2, "en", "v2").canRegroupStoredMetadata(from: old))
        #expect(!key("album-b", 1, "en", "v2").canRegroupStoredMetadata(from: old))
        #expect(!key("album-a", 1, "en", "v2", "limited").canRegroupStoredMetadata(from: old))
        #expect(key().canReuseGeography(from: old))
        #expect(!key("album-b").canReuseGeography(from: old))
        #expect(!key("album-a", 1, "ja").canReuseGeography(from: old))
        #expect(!key("album-a", 1, "en", "v2").canReuseGeography(from: old))
        var legacy = key()
        legacy.visitGroupingVersion = nil
        let legacyData = try legacy.serialized()
        #expect(key().canRegroupStoredMetadata(from: legacyData))
        #expect(!key("album-a", 1, "ja").changesOnlyLocale(from: legacyData))
        #expect(key("album-a", 1, "en", "v1", "limited").transition(from: old) == .withdraw)
        #expect(key("album-b").transition(from: old) == .withdraw)
        #expect(key().transition(from: "authorized") == .withdraw)
        #expect(key().transition(from: nil) == .withdraw)
        let a = TravelScanScope(members: ["x", "y"], limitedIdentifiers: ["a", "b"])
        let b = TravelScanScope(members: ["y", "x"], limitedIdentifiers: ["b", "a"])
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != TravelScanScope(members: ["x"], limitedIdentifiers: ["b", "a"]).fingerprint)
    }

    @Test func unreadableAlbumCannotBroadenScopeWithoutAnObservedDeletion() throws {
        let selected: Set<String> = ["readable", "missing"]
        #expect(throws: LibraryPreparationError.self) {
            try TravelScanScope.verifiedSelection(selected, readable: ["readable"], deleted: [])
        }
        #expect(try TravelScanScope.verifiedSelection(selected, readable: ["readable"], deleted: ["missing"]) == ["readable"])
        #expect(try TravelScanScope.verifiedSelection(selected, readable: selected, deleted: ["missing"]) == selected)
    }

    @Test func ledgerSurvivesReopenRejectsLateEvidenceAndRestoresOnlyEligibleMembers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let ledger = TravelScanLedger(url: url)
        func item(_ id: String, revision: Double = 1, screen: Bool = false) -> ScanAssetMetadata {
            let date = Date(timeIntervalSinceReferenceDate: revision)
            let record = PhotoAssetRecord(id: id, coordinate: .init(latitude: 1, longitude: 2), creationDate: date,
                pixelWidth: 800, pixelHeight: 600, isFavorite: false)
            return .init(id: id, modified: date, available: true, screen: screen, dated: true, located: true, record: record)
        }
        let batch = [item("excluded"), item("candidate"), item("screenshot", screen: true)]
        _ = try await ledger.prepare(.init(members: ["excluded"]))
        let first = try await ledger.filter(batch + batch, sweep: "first")
        #expect(first.map(\.id) == ["candidate"])
        #expect(try await ledger.filter(batch, sweep: "first").isEmpty)
        #expect(try await ledger.sourceCount() == 3)
        let delta = try await ledger.filter([item("candidate"), item("candidate")])
        #expect(delta.map(\.id) == ["candidate"])
        let pending = try await ledger.pending()
        let stale = try #require(pending.first)
        _ = try await ledger.filter([item("candidate", revision: 2)])
        #expect(try await !ledger.record(.confirmedMissing, for: stale))
        let edited = try await ledger.pending()
        let current = try #require(edited.first)
        #expect(try await ledger.record(.confirmedMissing, for: current))
        #expect(try await !ledger.record(.confirmedMissing, for: current))
        let reopened = TravelScanLedger(url: url)
        let snapshot = try await reopened.prepare(.init(members: ["excluded"]))
        #expect(snapshot.revision == 1)
        #expect(try await reopened.removals(after: 0, startingAfter: "") == ["candidate"])
        #expect(try await reopened.removals(after: 1, startingAfter: "").isEmpty)
        let changes = try await reopened.filter([item("candidate", revision: 2)])
        #expect(changes.isEmpty)
        let prefs = TravelScanPreferences(excludesMissingCamera: false)
        _ = try await reopened.prepare(.init(preferences: prefs))
        let restored = try await reopened.filter([item("excluded"), item("candidate", revision: 2), item("screenshot", screen: true)], sweep: "second")
        #expect(restored.map(\.id) == ["excluded", "candidate"])
        try await reopened.finishSweep("second")
        let counts = try await reopened.counts()
        #expect(counts == [.eligible: 1, .pendingCamera: 1, .screenCapture: 1])
        try await reopened.remove(["excluded"])
        #expect(try await reopened.pending().isEmpty)
    }

    @Test func originalHeadersDistinguishConfirmedCameraMissingAlternateAndTruncatedResources() throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        func bytes(_ metadata: [CFString: Any]) throws -> Data {
            let data = NSMutableData()
            let output = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, metadata as CFDictionary)
            #expect(CGImageDestinationFinalize(output))
            return data as Data
        }
        let camera = CameraHeader(canProveMissing: true)
        _ = camera.append(try bytes([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon"]]))
        #expect(camera.completed() == .identified)
        let lens = CameraHeader(canProveMissing: true)
        _ = lens.append(try bytes([kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "EF"]]))
        #expect(lens.completed() == .unknown)
        let plain = try bytes([:])
        for proof in [true, false] {
            let header = CameraHeader(canProveMissing: proof)
            _ = header.append(plain)
            #expect(header.completed() == (proof ? .confirmedMissing : .unknown))
        }
        let truncated = CameraHeader(canProveMissing: true)
        _ = truncated.append(plain.prefix(20))
        #expect(truncated.completed() == .unknown)
    }

    @Test func cityLabelsShipInOneDatabase() throws {
        let catalog = try JourneyPlaceCatalog.shared
        #expect(catalog.version == WorldCityAtlas.revision)
        let resources = Bundle.main
        #expect(resources.url(forResource: "WorldCityAtlas", withExtension: "sqlite") != nil)
        #expect(resources.url(forResource: "JourneyCities", withExtension: "tsv") == nil)
        #expect(resources.url(forResource: "JourneyCitiesManifest", withExtension: "json") == nil)
        #expect(resources.url(forResource: "NaturalEarthPopulatedPlaces", withExtension: "tsv") == nil)
    }

    @Test func retiredDownloadsAreRemovedWithoutChangingOtherCacheContents() throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: caches) }
        let directory = caches.appendingPathComponent("JourneyCatalog")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["installed.json", "status.json", "unrelated.json"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        for _ in 0..<2 { JourneyPlaceCatalog.removeRetiredDownloads(in: caches) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["unrelated.json"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("unrelated.json")) == Data("unrelated.json".utf8))
    }

    @Test func lensPinCatalogGoldenCitiesAndBoundaries() throws {
        let catalog = try JourneyPlaceCatalog.shared
        for language in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: language)
            let hangzhou = try catalog.label(.init(latitude: 30.2741, longitude: 120.1551), locale: locale)
            #expect(hangzhou.offlinePlaceID == "catalog:1159151387")
            #expect(hangzhou.regionCode == "CN")
            let takayama = try catalog.label(.init(latitude: 36.1461, longitude: 137.2522), locale: locale)
            let hida = try catalog.label(.init(latitude: 36.2383, longitude: 137.1855), locale: locale)
            #expect(takayama.regionCode == "JP" && hida.regionCode == "JP")
            #expect(takayama.offlinePlaceID != hida.offlinePlaceID)
        }
        let ocean = try catalog.label(.init(latitude: -40, longitude: -90), locale: Locale(identifier: "en"))
        #expect(ocean.source == JourneyPlaceCatalog.unknownSource && ocean.offlinePlaceID == nil)

    }

    @Test func travelCityNamesRespectUserLanguageAndRegion() async throws {
        let catalog = try JourneyPlaceCatalog.shared
        let cases = [
            (43.55135, 7.01275, "zh-Hans-TW", "戛纳"), (43.55135, 7.01275, "zh-Hant-TW", "坎城"),
            (43.55135, 7.01275, "zh-Hant-HK", "康城"), (20.21173, -87.46325, "ja", "トゥルム"),
            (25.07725, 55.30927, "zh-Hant", "杜拜"), (-8.50694, 115.26248, "zh-Hans", "乌布"),
            (39.76838, -86.15804, "en", "Indianapolis"), (36.16589, -86.78444, "en", "Nashville"),
            (21.30694, -157.85833, "en", "Honolulu"), (33.96095, -83.37794, "en", "Athens"),
            (30.76451, 108.39586, "en", "Chongqing"), (31.01894, 109.45949, "en", "Chongqing"),
        ]
        for (lat, lon, language, expected) in cases {
            let label = try catalog.label(.init(latitude: lat, longitude: lon), locale: Locale(identifier: language))
            #expect(label.city == expected)
            let id = try #require(label.offlinePlaceID)
            #expect(catalog.shelfTitles(for: [id], languages: [language])[id]?[language] == expected)
        }
    }

    @Test func reviewedCoverageUsesTravelCitiesAcrossMunicipalBoundaries() async throws {
        let catalog = try JourneyPlaceCatalog.shared
        let points = [
            (49.48121, 8.44641, "gn:2875376", "Ludwigshafen am Rhein"),
            (49.4891, 8.46694, "1159140549", "Mannheim"),
            (40.51872, -74.4121, "gn:5097529", "Edison"),
            (35.56148, 139.71625, "1159151609", "Tokyo"),
            (39.0011111111, 141.1077777778, "gn:2112731", "Hiraizumi"),
            (44.37611111, -64.30916667, "gn:6062069", "Lunenburg"),
        ]
        for (latitude, longitude, key, name) in points {
            let point = GeoCoordinate(latitude: latitude, longitude: longitude)
            let english = try catalog.label(point, locale: Locale(identifier: "en"))
            let japanese = try catalog.label(point, locale: Locale(identifier: "ja"))
            #expect(english.offlinePlaceID == "catalog:" + key)
            #expect(english.city == name)
            #expect(japanese.offlinePlaceID == english.offlinePlaceID)
            let id = try #require(english.offlinePlaceID)
            #expect(catalog.shelfTitles(for: [id], languages: ["en", "ja"])[id]?["ja"] == japanese.city)
        }
    }

    @Test func bundledAtlasMatchesRepeatedPublicCoordinates() async throws {
        let catalog = try JourneyPlaceCatalog.shared
        let points = [(48.85341, 2.34880), (51.50853, -0.12574), (40.71427, -74.00597),
                      (20.21173, -87.46325), (35.01167, 135.76833), (22.28552, 114.15769)]
        let clock = ContinuousClock()
        let start = clock.now
        var resolved = 0
        let locale = Locale(identifier: "en")
        for _ in 0..<100 {
            for (latitude, longitude) in points {
                let label = try catalog.label(.init(latitude: latitude, longitude: longitude), locale: locale)
                if label.offlinePlaceID != nil { resolved += 1 }
            }
        }
        print("World atlas matched 600 public coordinates in", start.duration(to: clock.now))
        #expect(resolved == 600)
    }

    @Test @MainActor func catalogUpgradeRegroupsDistrictVisitsAcrossLibraryHomeAndTopShelf() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("index.sqlite")
        let locale = Locale(identifier: "en")
        let store = SQLiteTravelIndexStore(databaseURL: database, locale: locale)
        let catalog = try JourneyPlaceCatalog.shared
        let oldRevision = "world-atlas-20261121.4"
        func key(_ revision: String) -> ScanPublicationKey {
            .init(access: "authorized", scope: "test", cameraRevision: 1, catalog: revision, locale: "en")
        }
        let oldLabels = [
            ("Nanshan", "catalog:gn:1916136", GeoCoordinate(latitude: 22.53330, longitude: 113.93040)),
            ("Longgang", "catalog:gn:1802656", GeoCoordinate(latitude: 22.72042, longitude: 114.24593)),
            ("Guangzhou", "catalog:1159151331", GeoCoordinate(latitude: 23.1291, longitude: 113.2644)),
        ]
        let minimum = JourneyVisitThreshold.defaultValue
        let records = oldLabels.enumerated().flatMap { offset, label in
            (0..<minimum).map { item in
                PhotoAssetRecord(id: "asset-\(offset)-\(item)", coordinate: label.2,
                    creationDate: Date(timeIntervalSince1970: Double(offset * 12 * 86_400 + item)),
                    pixelWidth: 900, pixelHeight: 600, isFavorite: false)
            }
        }
        let before = try await store.beginMetadataScan(copyCurrent: false)
        _ = try await store.stageMetadata(.init(records: records), run: before)
        let old = try await store.activateMetadata(run: before, sourcePhotoCount: records.count, token: Data([1]),
            fullCheck: true, authorization: try key(oldRevision).serialized(), configuration: .init()) { _, _ in }
        let districtVisits = zip(old.places, oldLabels).map { place, label in
            var visit = place
            visit.name = label.0
            visit.offlinePlaceID = label.1
            visit.regionCode = "CN"
            visit.country = "China"
            return visit
        }
        try await store.updatePlaceNames(districtVisits)
        let previous = try #require(try await store.load())
        #expect(Set(PlaceCollection.countries(previous.places).flatMap(\.cities).map(\.title)) == ["Nanshan", "Longgang", "Guangzhou"])
        let currentKey = key(catalog.version)
        let sync = try await store.loadSyncState()
        #expect(currentKey.transition(from: sync.authorization) == .rebuild)
        #expect(currentKey.canRegroupStoredMetadata(from: sync.authorization))

        let upgrade = try await store.beginMetadataScan(copyCurrent: true)
        _ = try await store.activateMetadata(run: upgrade, sourcePhotoCount: records.count, token: Data([2]),
            fullCheck: false, authorization: try currentKey.serialized(), configuration: .init(), catalog: catalog) { _, _ in }
        let reopened = SQLiteTravelIndexStore(databaseURL: database, locale: locale)
        let index = try #require(try await reopened.load())
        #expect(currentKey.transition(from: try await reopened.loadSyncState().authorization) == .reuse)
        #expect(index.places.map(\.id) == previous.places.map(\.id))
        #expect(index.places.map(\.offlinePlaceID) == ["catalog:1159151215", "catalog:1159151215", "catalog:1159151331"])
        #expect(index.journeys.map(\.placeIDs) == index.places.map { [$0.id] })
        let country = try #require(PlaceCollection.countries(index.places).first)
        #expect(country.cities.map(\.title) == ["Guangzhou", "Shenzhen"])
        #expect(PlaceCollection.recent(index.places, minimumVisitItems: minimum).map(\.title) == ["Guangzhou", "Shenzhen", "Shenzhen"])
        let home = OverviewContentModel(latestCovers: { _ in [:] })
        home.receive(index, minimumVisitItems: minimum)
        #expect(home.recent.map(\.place.name) == ["Guangzhou", "Shenzhen"])
        let shelf = JourneyShelfSelection.recent(in: index, minimumVisitItems: minimum)
        #expect(shelf.map(\.collection.title) == home.recent.map(\.place.name))
        let shenzhen = try #require(shelf.first { $0.collection.title == "Shenzhen" })
        #expect(shenzhen.collection.placeIDs == country.cities[1].placeIDs)
        let page = try await reopened.photoPage(for: shenzhen.collection.placeIDs, offset: 0, limit: records.count)
        #expect(Set(page.records.map(\.id)) == Set(records.prefix(minimum * 2).map(\.id)))
    }

    @Test func languageChangeReusesCityMembershipAndPublishesTranslatedShelfTitles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("index.sqlite")
        let catalog = try JourneyPlaceCatalog.shared
        let london = GeoCoordinate(latitude: 51.50853, longitude: -0.12574)
        func key(_ language: String) -> ScanPublicationKey {
            .init(access: "authorized", scope: "test", cameraRevision: 1, catalog: catalog.version, locale: language)
        }
        let english = SQLiteTravelIndexStore(databaseURL: database, locale: Locale(identifier: "en"))
        let record = PhotoAssetRecord(id: "fixture", coordinate: london, creationDate: Date(timeIntervalSince1970: 1),
                                     pixelWidth: 900, pixelHeight: 600, isFavorite: false)
        let run = try await english.beginMetadataScan(copyCurrent: false)
        _ = try await english.stageMetadata(.init(records: [record]), run: run)
        let previous = try key("en").serialized()
        let first = try await english.activateMetadata(run: run, sourcePhotoCount: 1, token: Data([5]),
            fullCheck: true, authorization: previous, configuration: .init(), catalog: catalog) { _,_ in }
        let chinese = SQLiteTravelIndexStore(databaseURL: database, locale: Locale(identifier: "zh-Hans-TW"))
        let changed = try await chinese.refreshLocale(from: previous, to: key("zh-Hans-TW"), catalog: catalog)
        #expect(changed)
        let current = try #require(try await chinese.load())
        #expect(current.places.map(\.id) == first.places.map(\.id))
        #expect(current.places.map(\.offlinePlaceID) == first.places.map(\.offlinePlaceID))
        #expect(current.journeys.map(\.placeIDs) == first.journeys.map(\.placeIDs))
        #expect(current.places.first?.name == "伦敦")
        #expect(try await chinese.loadSyncState().token == Data([5]))
        let id = try #require(current.places.first?.offlinePlaceID)
        let titles = catalog.shelfTitles(for: [id], languages: ["zh-Hans", "zh-Hant", "ja"])
        var item = JourneyShelfItem(route: "route", title: "London", assetID: "fixture", photoProof: "")
        item.localizedTitles = titles[id]
        #expect(JourneyShelfItem.displayTitles(in: [item], language: "zh-Hant")["route"] == "倫敦")
        #expect(JourneyShelfItem.displayTitles(in: [item], language: "ja")["route"] == "ロンドン")
    }

    @Test func bundledAtlasUsesReviewedOwerriSpelling() throws {
        let atlas = try #require(WorldCityAtlas.bundled)
        #expect(atlas.name(for: "1159116695", locale: Locale(identifier: "zh-Hans")) == "奥韦里")
    }

    @Test func regionalLabelsSurviveInitialScanCacheMigrationAndLanguageChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("index.sqlite")
        let catalog = try JourneyPlaceCatalog.shared
        let hk = "zh-Hant-HK", tw = "zh-Hant-TW"
        func key(_ region: String) -> ScanPublicationKey {
            .init(access: "authorized", scope: "test", cameraRevision: 1, catalog: catalog.version, locale: region)
        }
        let hongKong = SQLiteTravelIndexStore(databaseURL: database, locale: Locale(identifier: hk))
        let photo = PhotoAssetRecord(id: "cannes-fixture", coordinate: .init(latitude: 43.55135, longitude: 7.01275),
            creationDate: Date(timeIntervalSince1970: 1), pixelWidth: 900, pixelHeight: 600, isFavorite: false)
        let run = try await hongKong.beginMetadataScan(copyCurrent: false)
        _ = try await hongKong.stageMetadata(.init(records: [photo]), run: run)
        var legacy = key(hk)
        legacy.labelLocaleVersion = nil
        let old = try legacy.serialized()
        let first = try await hongKong.activateMetadata(run: run, sourcePhotoCount: 1, token: Data([8]),
            fullCheck: true, authorization: old, configuration: .init(), catalog: catalog) { _,_ in }
        #expect(first.places.first?.name == "康城")
        #expect(try await hongKong.refreshLocale(from: old, to: key(hk), catalog: catalog))
        let taiwan = SQLiteTravelIndexStore(databaseURL: database, locale: Locale(identifier: tw))
        #expect(try await taiwan.refreshLocale(from: key(hk).serialized(), to: key(tw), catalog: catalog))
        let current = try #require(try await taiwan.load())
        #expect(current.places.first?.name == "坎城")
        #expect(current.places.map(\.id) == first.places.map(\.id))
        #expect(current.places.map(\.offlinePlaceID) == first.places.map(\.offlinePlaceID))
        #expect(try await taiwan.loadSyncState().token == Data([8]))
        #expect(try await hongKong.load()?.places.first?.name == "康城")
        let id = try #require(first.places.first?.offlinePlaceID)
        var item = JourneyShelfItem(route: "cannes", title: "Cannes", assetID: "fixture", photoProof: "")
        item.localizedTitles = catalog.shelfTitles(for: [id], languages: ["zh-Hant", "ja"])[id]
        #expect(JourneyShelfItem.displayTitles(in: [item], language: hk)["cannes"] == "康城")
        #expect(JourneyShelfItem.displayTitles(in: [item], language: tw)["cannes"] == "坎城")
        #expect(JourneyShelfItem.displayTitles(in: [item], language: "ja-JP")["cannes"] == item.localizedTitles?["ja"])
    }

    @Test func routesKeepReturnVisitsAcrossMonthsSeparate() {
        func visit(_ id: String, _ city: String?, _ day: Int) -> TravelPlace {
            let date = Date(timeIntervalSince1970: TimeInterval(day * 86400))
            return TravelPlace(id: id, name: city ?? "", country: city.map { _ in "Japan" },
                offlinePlaceID: city, coordinate: .init(latitude: 36, longitude: 137), startDate: date,
                endDate: date, photoCount: 1, coverAssetID: id)
        }
        let visits = [visit("a","city",0), visit("b","city",45), visit("unknown",nil,65),
                      visit("c","city",90), visit("d","other",120)]
        let routes = StreamingTravelClusterer.journeys(visits, configuration: .init())
        #expect(routes.map(\.placeIDs) == [["a"],["b"],["unknown"],["c"],["d"]])
        #expect(PlaceCollection.recent(visits).count == 5)
        let sameName = [visit("a","A",0), visit("b","B",20)].map { place in
            var copy = place; copy.name = "Springfield"; return copy
        }
        #expect(PlaceCollection.city(containing: sameName[0], in: sameName).placeIDs == ["a"])
    }
}

extension JourneyScanGateTests {
    @Test func officialEbinaBoundaryKeepsNeighborCitiesSeparate() throws {
        let catalog = try JourneyPlaceCatalog.shared
        let locale = Locale(identifier: "en-US")
        func label(_ latitude: Double, _ longitude: Double) throws -> PlaceDisplayLabel {
            try catalog.label(.init(latitude: latitude, longitude: longitude), locale: locale)
        }
        let ebina = try label(35.43417, 139.39419)
        #expect(ebina.city == "Ebina")
        #expect(ebina.offlinePlaceID == "catalog:gn:11612543")
        #expect(try label(35.38121, 139.39651).city == "Samukawa")
        #expect(try label(35.44272, 139.36931).city == "Atsugi")
    }

    @Test func cityIdentityFormsVisitsBeforeApplyingDistanceAndMinimumItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"),
                                            locale: Locale(identifier: "en"), hidesTransitPhotos: false)
        let catalog = try JourneyPlaceCatalog.shared
        let nanshan = GeoCoordinate(latitude: 22.53330, longitude: 113.93040)
        let longgang = GeoCoordinate(latitude: 22.72042, longitude: 114.24593)
        let paris = GeoCoordinate(latitude: 48.85837, longitude: 2.29448)
        let versailles = GeoCoordinate(latitude: 48.80486, longitude: 2.12035)
        #expect(GlobeMath.distanceKilometers(from: nanshan, to: longgang) > 30)
        #expect(GlobeMath.distanceKilometers(from: paris, to: versailles) < 30)

        func photos(_ prefix: String, at coordinate: GeoCoordinate, hour: Int, count: Int) -> [PhotoAssetRecord] {
            (0..<count).map { offset in
                PhotoAssetRecord(id: "\(prefix)-\(offset)", coordinate: coordinate,
                    creationDate: Date(timeIntervalSince1970: Double(hour * 3_600 + offset)),
                    pixelWidth: 2048, pixelHeight: 1365, isFavorite: false)
            }
        }
        let firstVisit = photos("nanshan", at: nanshan, hour: 0, count: 3)
            + photos("longgang", at: longgang, hour: 24, count: 3)
        let records = firstVisit + photos("return", at: longgang, hour: 24 * 12, count: 5)
            + photos("paris", at: paris, hour: 24 * 20, count: 5)
            + photos("versailles", at: versailles, hour: 24 * 20 + 1, count: 5)
        let run = try await store.beginMetadataScan(copyCurrent: false)
        _ = try await store.stageMetadata(.init(records: records), run: run)
        let index = try await store.activateMetadata(run: run, sourcePhotoCount: records.count,
            token: Data([1]), fullCheck: true, authorization: "test",
            configuration: .init(), catalog: catalog) { _, _ in }

        #expect(index.places.map(\.name) == ["Shenzhen", "Shenzhen", "Paris", "Versailles"])
        #expect(index.places.map(\.photoCount) == [6, 5, 5, 5])
        #expect(index.places.map(\.coordinate) == [nanshan, longgang, paris, versailles])
        #expect(index.journeys.map { $0.placeIDs.count } == [1, 1, 2])
        #expect(PlaceCollection.recent(index.places, minimumVisitItems: JourneyVisitThreshold.defaultValue).count == 4)
        let visit = try #require(index.places.first)
        let page = try await store.photoPage(for: [visit.id], offset: 0, limit: 10)
        #expect(Set(page.records.map(\.id)) == Set(firstVisit.map(\.id)))
        #expect(Set(page.records.map(\.coordinate)) == [nanshan, longgang])
    }

    @Test func incrementalAndFullPublicationAgreeOnVisitIdentityRTreeAndRestoredCity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try JourneyPlaceCatalog.shared
        let center = GeoCoordinate(latitude: 30.2741, longitude: 120.1551)
        func photo(_ id: String, _ distance: Double, _ days: Int) -> PhotoAssetRecord {
            .init(id: id, coordinate: .init(latitude: center.latitude, longitude: center.longitude + distance),
                  creationDate: Date(timeIntervalSince1970: Double(days * 86_400)), pixelWidth: 2048,
                  pixelHeight: 1365, isFavorite: false)
        }
        let original = [photo("a",0,0), photo("second",0.02,0), photo("removed",1.0,15), photo("repeat",0,45)]
        let replacement = photo("new",-0.02,0)
        let final = original.filter { $0.id != "removed" } + [replacement]
        let key = ScanPublicationKey(access: "authorized", scope: "test", cameraRevision: 1,
                                     catalog: catalog.version, locale: AppLocalization.locale.identifier)
        func publish(_ store: SQLiteTravelIndexStore, records: [PhotoAssetRecord], deleted: [String] = [], full: Bool) async throws -> TravelIndex {
            let run = try await store.beginMetadataScan(copyCurrent: !full)
            _ = try await store.stageMetadata(.init(records: records, removedIDs: deleted), run: run)
            return try await store.activateMetadata(run: run, sourcePhotoCount: 5, token: Data([1]), fullCheck: full,
                authorization: try key.serialized(), configuration: .init(), catalog: catalog) { _, _ in }
        }
        let a = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("a.sqlite"))
        let b = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("b.sqlite"))
        _ = try await publish(a, records: original, full: true)
        let incremental = try await publish(a, records: [replacement], deleted: ["removed"], full: false)
        let complete = try await publish(b, records: final, full: true)
        #expect(incremental.places == complete.places)
        #expect(incremental.journeys.map(\.placeIDs) == complete.journeys.map(\.placeIDs))
        #expect(incremental.places.count == 2 && incremental.journeys.count == 2)
        #expect(incremental.places.first?.coordinate == center)
        #expect(incremental.places.allSatisfy { $0.offlinePlaceID == "catalog:1159151387" })
        let viewport = EarthViewport(center: center, angularRadius: 5)
        let aa = try await a.photos(in: viewport, limit: 32)
        let bb = try await b.photos(in: viewport, limit: 32)
        #expect(aa == bb)
        #expect(Set(aa.map(\.id)) == Set(final.map(\.id)))
        let reopened = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("a.sqlite"))
        let restored = try await reopened.load()
        #expect(restored?.places == complete.places)
        let change = PhotoAssetRecord(id: replacement.id, coordinate: .init(latitude: 31.2304, longitude: 121.4737),
            creationDate: replacement.creationDate, pixelWidth: replacement.pixelWidth,
            pixelHeight: replacement.pixelHeight, isFavorite: replacement.isFavorite)
        let moved = try await publish(a, records: [change], full: false)
        let movedVisit = try #require(moved.places.first { $0.coordinate == change.coordinate })
        #expect(movedVisit.offlinePlaceID == "catalog:1159151605")
    }
}
