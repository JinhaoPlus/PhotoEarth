import Foundation
import CoreGraphics
import UIKit
import SQLite3
import Testing
@testable import PhotoEarth

@MainActor @Suite(.serialized)
struct ScenicCoverTests {
    private func photo(_ id: String, place: String = "visit", date: Double = 0, favorite: Bool = false) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: .init(latitude: 20, longitude: 30),
                         creationDate: Date(timeIntervalSince1970: date), pixelWidth: 1600, pixelHeight: 1000,
                         isFavorite: favorite, placeID: place)
    }
    private func place(_ id: String = "visit", start: Double = 0, end: Double = 100) -> TravelPlace {
        TravelPlace(id: id, name: "City", country: "Country", coordinate: .init(latitude: 20, longitude: 30),
                    startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end),
                    photoCount: 100, coverAssetID: nil)
    }
    private var scenic: ScenicCoverAnalysis { .init(scenery: 0.9, aesthetics: 0.7, isUtility: false, largestFace: 0) }
    private var portrait: ScenicCoverAnalysis { .init(scenery: 0.8, aesthetics: 0.95, isUtility: false, largestFace: 0.3) }
    private var fallback: PhotoPreviewMetadata { .init(assetID: "latest", pixelWidth: 1600, pixelHeight: 1000) }

    @Test func sceneryBeatsFavoritePortraitAndUtilityWithoutExcludingSmallPeople() {
        let photos = [photo("portrait", favorite: true), photo("scenery"), photo("receipt", favorite: true)]
        let scores = ["portrait": portrait, "scenery": scenic,
                      "receipt": ScenicCoverAnalysis(scenery: 0.99, aesthetics: 1, isUtility: true, largestFace: 0)]
        #expect(ScenicCoverPolicy.best(in: photos, analyses: scores)?.id == "scenery")
        #expect(ScenicCoverAnalysis(scenery: 0.8, aesthetics: 0.3, isUtility: false, largestFace: 0.02).isScenic)
        #expect(!ScenicCoverPolicy.labels.contains("bernese_mountain"))
        #expect(!ScenicCoverPolicy.labels.contains("blue_sky"), "Sky alone does not prove a scenery composition")
        #expect(!ScenicCoverAnalysis(scenery: .nan, aesthetics: nil, isUtility: false, largestFace: 0).isScenic)
    }

    @Test func scoresHaveStableTiesAndLowQualitySceneryFallsBack() {
        let records = [photo("b", date: 1), photo("a", date: 1)]
        #expect(ScenicCoverPolicy.best(in: records, analyses: ["a": scenic, "b": scenic])?.id == "a")
        #expect(ScenicCoverPolicy.best(in: records.reversed(), analyses: ["a": scenic, "b": scenic])?.id == "a")
        #expect(!ScenicCoverAnalysis(scenery: 0.9, aesthetics: -0.8, isUtility: false, largestFace: 0).isScenic)
    }

    @Test func cityCoversRankLandmarksUsingTheFullFrame() async throws {
        let clear = photo("clear")
        let panorama = photo("panorama", favorite: true)
        let gothicFacade = CityCoverPolicy.landmarkConfidence(["arch": 0.6, "structure": 0.8, "outdoor": 0.9])
        #expect(gothicFacade == 0.6)
        #expect(CityCoverPolicy.landmarkConfidence(["arch": 0.9, "structure": 0.9, "outdoor": 0]) == 0)
        #expect(CityCoverPolicy.landmarkConfidence(["cityscape": 0.95, "building": 0.9, "outdoor": 0.9, "structure": 0.9]) == 0)
        let scores: [String: ScenicCoverAnalysis] = [
            "clear": .init(scenery: 0.05, aesthetics: 0.65, isUtility: false, largestFace: 0,
                           landmark: gothicFacade),
            "panorama": .init(scenery: 0.99, aesthetics: 0.9, isUtility: false, largestFace: 0, landmark: 0.05),
        ]
        #expect(CityCoverPolicy.best(in: [clear, panorama], analyses: scores) == clear)
        #expect(CityCoverPolicy.best(in: [panorama], analyses: scores) == panorama)
        let missingAesthetics = ScenicCoverAnalysis(scenery: 1, aesthetics: nil, isUtility: false, largestFace: 0, landmark: 1)
        #expect(CityCoverPolicy.best(in: [clear], analyses: [clear.id: missingAesthetics]) == nil)
        let selector = ScenicCoverSelector(store: CoverTestStore(photos: [clear, panorama])) { photo in scores[photo.id] }
        let selection = try await selector.select(for: [place()], revision: "1", fallback: nil, usesCityPoster: true)
        #expect(selection?.assetID == clear.id)
    }

    @Test func sceneInterestOnlyTipsCloseEligiblePosters() {
        let stop = photo("frequent")
        let single = photo("single")
        func poster(appeal: Float, utility: Bool = false) -> ScenicCoverAnalysis {
            .init(scenery: 0.9, aesthetics: appeal, isUtility: utility, largestFace: 0)
        }
        let photos = [stop, single]
        let strong = [stop.id: Float(1)]
        let close = [stop.id: poster(appeal: 0.55), single.id: poster(appeal: 0.65)]
        #expect(CityCoverPolicy.best(in: photos, analyses: close) == single)
        #expect(CityCoverPolicy.best(in: photos, analyses: close, sceneStrengths: strong) == stop)
        for ineligibleOrWeak in [poster(appeal: 0.4), poster(appeal: -0.5), poster(appeal: 1, utility: true)] {
            let scores = [stop.id: ineligibleOrWeak, single.id: poster(appeal: 0.65)]
            #expect(CityCoverPolicy.best(in: photos, analyses: scores, sceneStrengths: [stop.id: 10]) == single)
        }
        #expect(CityCoverPolicy.best(in: photos, analyses: close, sceneStrengths: [stop.id: .nan]) == single)
    }

    @Test func cityRanksTheActuallyScoredBackupInItsOwnScene() async throws {
        let missing = photo("missing")
        let single = photo("single")
        let nearby = photo("nearby")
        let store = CoverTestStore(photos: [missing, single], backups: [missing.id: [nearby]], strengths: [nearby.id: 1])
        let selector = ScenicCoverSelector(store: store) { record in
            guard record.id != missing.id else { return nil }
            let appeal: Float = record.id == single.id ? 0.65 : 0.55
            return .init(scenery: 0.9, aesthetics: appeal, isUtility: false, largestFace: 0)
        }
        let visit = place()
        let chosen = try await selector.select(for: [visit], revision: "1", fallback: nil,
                                               priorityVisitID: visit.id, usesCityPoster: true)
        #expect(chosen?.assetID == nearby.id)
    }

    @Test func tripCoversKeepFamilyPortraitsAndOnlyReplaceAnIncumbentForAMeaningfulImprovement() {
        let records = [photo("current"), photo("family"), photo("receipt")]
        let near = ScenicCoverAnalysis(scenery: 0, aesthetics: 0.74, isUtility: false, largestFace: 0.7)
        let utility = ScenicCoverAnalysis(scenery: 0, aesthetics: 1, isUtility: true, largestFace: 0)
        let close = ["current": scenic, "family": near, "receipt": utility]
        #expect(JourneyCoverPolicy.best(in: records, analyses: close, incumbent: nil)?.id == "family")
        #expect(JourneyCoverPolicy.best(in: records.reversed(), analyses: close, incumbent: "current")?.id == "current")
        let improved = ["current": scenic, "family": portrait, "receipt": utility]
        #expect(JourneyCoverPolicy.best(in: records, analyses: improved, incumbent: "current")?.id == "family")
        #expect(JourneyCoverPolicy.best(in: [photo("receipt")], analyses: improved, incumbent: "current") == nil)
    }

    @Test func unscoredIncumbentSurvivesUntilBothImagesCanBeCompared() async throws {
        let records = [photo("current"), photo("family")]
        let window = JourneyCoverWindow(latest: records[0], visibleVisitEnds: ["visit": records[0].creationDate])
        let unavailable = ScenicCoverAnalysis(scenery: 0, aesthetics: nil, isUtility: false, largestFace: 0)
        let legacy = CoverTestStore(photos: records)
        await legacy.saveCoverAnalysis(unavailable, assetID: "current", revision: "1")
        var attempts: [String] = []
        let analyze: ScenicCoverSelector.Analyze = { record in
            let retried = attempts.contains(record.id)
            attempts.append(record.id)
            if record.id == "current" { return retried ? scenic : unavailable }
            return portrait
        }
        let first = ScenicCoverSelector(store: legacy, analyze: analyze)
        let held = try await first.select(for: [place()], revision: "1", fallback: fallback, journeyWindow: window, currentCover: records[0])
        #expect(held?.assetID == "current")
        #expect(await legacy.savedCount == 2, "Only the new complete challenger adds a cached score")
        #expect(attempts == ["current", "family"])
        let next = ScenicCoverSelector(store: legacy, analyze: analyze)
        let improved = try await next.select(for: [place()], revision: "1", fallback: fallback, journeyWindow: window, currentCover: records[0])
        #expect(improved?.assetID == "family")
        #expect(attempts == ["current", "family", "current"])
        #expect(await legacy.savedCount == 3)
    }

    @Test func allVideoJourneyRanksStaticPostersWithoutChangingCityScenicCandidates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        let visit = place(end: 25)
        let photos = (0..<26).map { n in
            PhotoAssetRecord(id: "video-\(n)", coordinate: .init(latitude: 20, longitude: 30),
                creationDate: Date(timeIntervalSince1970: Double(n)), pixelWidth: 1920, pixelHeight: 1080,
                isFavorite: n == 5, mediaKind: .video, duration: 10, placeID: visit.id)
        }
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
            sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: [visit], journeys: [])
        try await store.save(.init(index: index, photos: photos))
        let cities = try await store.scenicCoverCandidates(for: [visit])
        let window = try #require(try await store.journeyCoverWindow(for: [visit], excluding: []))
        let journey = try await store.scenicCoverCandidates(for: [visit], journeyWindow: window)
        #expect(cities.isEmpty)
        #expect(journey.count >= 2 && journey.count <= 24)
        let selector = ScenicCoverSelector(store: store) { record in
            #expect(record.mediaKind == .video)
            return record.isFavorite ? portrait : scenic
        }
        let chosen = try await selector.select(for: [visit], revision: "10.0", fallback: nil, journeyWindow: window)
        #expect(chosen?.assetID == "video-5")
    }

    @Test func journeyCoverWindowRejectsStoredOldPosterBeforeSamplingAndOnCloudFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"), hidesTransitPhotos: false)
        // Nov 19 to Oct 20 crosses a month, and the exact 30-day boundary is inclusive.
        let end = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                                 year: 2026, month: 11, day: 19, hour: 12).date!.timeIntervalSince1970
        let day = 86_400.0
        let start = end - 30 * day
        let recent = place("recent", start: start - 10 * day, end: end + 15 * day)
        let oldPlaces = (0..<30).map { place("old-\($0)", start: start - Double($0 + 2) * day,
                                              end: start - Double($0 + 2) * day) }
        let visits = [recent] + oldPlaces
        let oldPhotos = oldPlaces.map { photo($0.id, place: $0.id, date: $0.endDate.timeIntervalSince1970) }
        let photos = oldPhotos + [
            photo("outside", place: recent.id, date: start - 1, favorite: true),
            photo("boundary", place: recent.id, date: start),
            photo("recent-favorite", place: recent.id, date: end - 12 * day, favorite: true),
            photo("latest", place: recent.id, date: end),
            photo("excluded-new", place: recent.id, date: end + 15 * day, favorite: true)
        ]
        let excluded: Set<String> = ["excluded-new"]
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: visits, journeys: [])
        try await store.save(.init(index: index, photos: photos))
        let window = try #require(try await store.journeyCoverWindow(for: visits, excluding: excluded))
        #expect(window.latest.id == "latest")
        #expect(window.visibleVisitEnds.count == 1)
        let candidates = try await store.scenicCoverCandidates(for: visits, journeyWindow: window, excluding: excluded)
        #expect(Set(candidates.map(\.id)) == ["boundary", "recent-favorite", "latest"])
        let original = try #require(try await store.visibleJourneyCover("outside", in: [recent.id]))
        let suite = "journey-cover-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["trip": original.id, "other": "keep"], forKey: JourneyCoverWindow.preferenceKey)
        let restored = window.restore(original, id: original.id, journeyID: "trip", excluding: excluded, defaults: defaults)
        #expect(restored == nil)
        #expect(defaults.dictionary(forKey: JourneyCoverWindow.preferenceKey) as? [String: String] == ["other": "keep"])
        let unavailable = ScenicCoverSelector(store: store) { record in
            #expect(window.contains(record))
            return nil
        }
        let fallback = try await unavailable.select(for: visits, revision: "10.0", fallback: PhotoPreviewMetadata(original),
                                                    journeyWindow: window, currentCover: original, excluding: excluded)
        #expect(fallback?.assetID == "latest")
        let readable = ScenicCoverSelector(store: store) { record in record.id == "recent-favorite" ? portrait : scenic }
        let winner = try await readable.select(for: visits, revision: "10.0", fallback: nil, journeyWindow: window, excluding: excluded)
        #expect(winner?.assetID == "recent-favorite")
        let empty = try await store.journeyCoverWindow(for: visits, excluding: Set(photos.map(\.id)))
        #expect(empty == nil)
    }

    @Test func previousCropScoresAreReplacedWhenOpeningAnExistingIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        let visit = place(end: 10)
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: 1, locatedPhotoCount: 1, places: [visit], journeys: [])
        try await store.save(.init(index: index, photos: [photo("cover")]))
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let previousSchema = """
            ALTER TABLE cover_analysis DROP COLUMN landmark;
            ALTER TABLE cover_analysis ADD COLUMN poster_assessment TEXT;
            INSERT INTO cover_analysis (asset_id, source_revision, strategy_version, scenery, utility, largest_face)
            VALUES ('cover', '10.0', 3, 1, 0, 0);
            """
        try #require(sqlite3_exec(db, previousSchema, nil, nil, nil) == SQLITE_OK)
        let upgraded = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        #expect(try await upgraded.coverAnalyses(for: ["cover"], revision: "10.0").isEmpty)
        let score = ScenicCoverAnalysis(scenery: 0.5, aesthetics: 0.7, isUtility: false, largestFace: 0, landmark: 0.9)
        try await upgraded.saveCoverAnalysis(score, assetID: "cover", revision: "10.0")
        let reopened = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        #expect(try await reopened.coverAnalyses(for: ["cover"], revision: "10.0")["cover"] == score)
    }

    @Test func fiftyThousandPhotosYieldBoundedDiverseCandidatesAndDurableScores() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = (0..<50_000).map { photo("asset-\($0)", date: Double($0), favorite: $0 == 123) }
        let visit = place(end: 49_999)
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: [visit], journeys: [])
        try await store.save(.init(index: index, photos: photos))
        let candidates = try await store.scenicCoverCandidates(for: [visit])
        #expect(candidates.count <= 24)
        #expect(Set(candidates.map(\.id)).count == candidates.count)
        #expect(candidates.contains { $0.id == "asset-0" })
        #expect(candidates.contains { $0.id == "asset-49999" })
        #expect(candidates.contains { $0.id == "asset-123" })
        #expect(try await store.scenicCoverCandidates(for: [visit]) == candidates)
        var posterScore = scenic
        posterScore.landmark = 0.8
        try await store.saveCoverAnalysis(posterScore, assetID: "asset-0", revision: "10.0")
        let reopened = SQLiteTravelIndexStore(databaseURL: url)
        #expect(try await reopened.visibleJourneyCover("asset-123", in: [visit.id])?.id == "asset-123")
        #expect(try await reopened.visibleJourneyCover("asset-123", in: ["another-visit"]) == nil)
        #expect(try await reopened.coverAnalyses(for: ["asset-0"], revision: "10.0")["asset-0"] == posterScore)
        #expect(try await reopened.coverAnalyses(for: ["asset-0"], revision: "11.0").isEmpty)
        try await reopened.saveCoverAnalysis(portrait, assetID: "asset-0", revision: "11.0")
        #expect(try await reopened.coverAnalyses(for: ["asset-0"], revision: "10.0")["asset-0"] == posterScore)
        try await reopened.invalidateCoverAnalyses(for: ["asset-0"])
        #expect(try await reopened.coverAnalyses(for: ["asset-0"], revision: "10.0").isEmpty)
    }

    @Test func countrySamplingIncludesOldVisitsAndNeverExceedsSix() {
        let visits = (0..<100).map { place("visit-\($0)", end: Double($0)) }
        let selected = ScenicCoverPolicy.visits(from: visits)
        #expect(selected.count == 6)
        #expect(selected.first?.id == "visit-99")
        #expect(selected.last?.id == "visit-0")
        #expect(ScenicCoverPolicy.visits(from: visits.reversed()) == selected)
    }

    @Test func citySamplingBackfillsDuplicateAnchorsAndPrioritizesSeparatedMomentsFromTheQualifyingVisit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"), hidesTransitPhotos: false)
        let recent = place("recent", start: 20_000, end: 180_000)
        let short = place("short", start: 181_000, end: 182_000)
        let old = place("old", start: 0, end: 8_000)
        // A full interval between shooting sessions and a dense burst in each session.
        let bursts = (0..<28).flatMap { session in
            let sessionStart = 20_000.0 + Double(session / 14) * 86_400 + Double(session % 14) * 480
            return (0..<12).map { frame in
                photo("burst-\(session)-\(frame)", place: recent.id, date: sessionStart + Double(frame),
                      favorite: session == 27 && frame == 11)
            }
        }
        let older = (0..<8).map { photo("old-\($0)", place: old.id, date: 500 + Double($0 * 1_000)) }
        let shortStop = photo("short", place: short.id, date: 181_000)
        let records = bursts + older + [shortStop]
        let visits = [recent, old, short]
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(),
                                sourcePhotoCount: records.count, locatedPhotoCount: records.count, places: visits, journeys: [])
        try await store.save(.init(index: index, photos: records))
        let candidates = try await store.scenicCoverCandidates(for: visits, priorityVisitID: recent.id)
        #expect(candidates.count == 24)
        #expect(Set(candidates.map(\.id)).count == 24)
        #expect(candidates.prefix(18).allSatisfy { $0.placeID == recent.id })
        #expect(candidates.dropFirst(18).allSatisfy { $0.placeID == old.id })
        #expect(candidates.first?.id == "burst-27-11")
        let times = candidates.prefix(18).map(\.creationDate).sorted()
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 120 })
        let refilled = try await store.scenicCoverCandidates(for: [recent, short], priorityVisitID: recent.id,
                                                            excluding: ["burst-27-11"])
        #expect(refilled.count == 24)
        #expect(refilled.allSatisfy { $0.placeID == recent.id && $0.id != "burst-27-11" })
    }

    @Test func missingCoverSlotsOwnOnlyTheirNearestEligibleAlternatives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"),
                                          hidesTransitPhotos: false)
        let first = photo("first", date: 0)
        func sample(_ id: String, latitude: Double, date: Double, kind: PhotoMediaKind = .photo) -> PhotoAssetRecord {
            PhotoAssetRecord(id: id, coordinate: .init(latitude: latitude, longitude: 30),
                             creationDate: Date(timeIntervalSince1970: date), pixelWidth: 1600, pixelHeight: 1000,
                             isFavorite: false, mediaKind: kind, placeID: "visit")
        }
        let far = sample("far", latitude: 21, date: 3_600)
        let farNeighbor = sample("far-neighbor", latitude: 21, date: 2)
        let foreign = photo("foreign", place: "other", date: 1)
        let hidden = photo("removed", date: 0)
        let video = sample("video", latitude: 20, date: 0, kind: .video)
        let records = [first, far, farNeighbor, foreign, hidden, video, photo("tie-b", date: 5),
                       photo("tie-a", date: 5), photo("star", date: 5, favorite: true)]
        let visits = [place(end: 3_600), place("other")]
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(),
                                sourcePhotoCount: records.count, locatedPhotoCount: records.count,
                                places: visits, journeys: [])
        try await store.save(.init(index: index, photos: records))
        let result = try await store.scenicCoverBackups(for: [first, far], missing: [first.id],
                                                       excluding: [hidden.id])
        #expect(result.mapValues { $0.map(\.id) } == [first.id: ["star", "tie-a"]])
        let both = try await store.scenicCoverBackups(for: [first, far], missing: [first.id, far.id],
                                                     excluding: [hidden.id])
        #expect(both[far.id]?.map(\.id) == [farNeighbor.id])
    }

    @Test func localSceneryAvoidsNetworkAndScoresAreSharedAcrossCollections() async throws {
        let store = CoverTestStore(photos: [photo("old"), photo("latest", date: 100)])
        var localCalls = 0
        let selector = ScenicCoverSelector(store: store) { record in
            localCalls += 1
            return record.id == "old" ? scenic : portrait
        }
        #expect(try await selector.select(for: [place()], revision: "1", fallback: fallback)?.assetID == "old")
        #expect(localCalls == 2)
        // A different collection still reuses the successful per-photo analyses.
        #expect(try await selector.select(for: [place(), place("other")], revision: "1", fallback: fallback)?.assetID == "old")
        #expect(localCalls == 2)
    }

    @Test func cityRefillsOnlyMissingSlotsInRoundsAndUsesCachedWinners() async throws {
        let primary = [photo("a"), photo("b"), photo("c")]
        let store = CoverTestStore(photos: primary, backups: [
            "a": [photo("a1"), photo("a2")], "b": [photo("b1"), photo("b2")], "c": [photo("c1")]
        ])
        let winner = ScenicCoverAnalysis(scenery: 1, aesthetics: 1, isUtility: false, largestFace: 0)
        await store.saveCoverAnalysis(winner, assetID: "b1", revision: "1")
        var attempts: [String] = []
        let selector = ScenicCoverSelector(store: store) { p in
            attempts.append(p.id)
            return ["c", "a2"].contains(p.id) ? scenic : nil
        }
        let selected = try await selector.select(for: [place()], revision: "1", fallback: fallback, usesCityPoster: true)
        #expect(selected?.assetID == "b1")
        #expect(attempts == ["a", "b", "c", "a1", "a2"])
        #expect(await store.backupLookups == 1)
    }

    @Test func cityDoesNotSpendBackupSlotsOnLowScoresOrUtilityImages() async throws {
        let store = CoverTestStore(photos: [photo("utility")], backups: ["utility": [photo("other")]])
        let selector = ScenicCoverSelector(store: store) { _ in
            ScenicCoverAnalysis(scenery: 1, aesthetics: 1, isUtility: true, largestFace: 0)
        }
        let selected = try await selector.select(for: [place()], revision: "1", fallback: fallback, usesCityPoster: true)
        #expect(selected == fallback)
        #expect(await store.backupLookups == 0)
    }

    @Test func unavailablePhotosAreSkippedOnceAndKeepFallback() async throws {
        let store = CoverTestStore(photos: (0..<24).map { photo("cloud-\($0)") })
        var localCalls = 0
        let selector = ScenicCoverSelector(store: store) { _ in
            localCalls += 1
            return nil
        }
        #expect(try await selector.select(for: [place()], revision: "1", fallback: fallback)?.assetID == "latest")
        #expect(localCalls == 24)
        #expect(await store.savedCount == 0, "Cloud unavailability must not become a durable non-scenic classification")
    }

    @Test func cloudOnlyDeliveryDoesNotEnqueueNetworkForCoverAnalysis() async {
        let backend = CoverPreviewTestRequester()
        let scheduler = SharedPhotoImageScheduler(requester: backend, automaticScheduling: false)
        let result = await CoverThumbnailRequest(scheduler: scheduler).value(for: photo("cloud"))
        #expect(result.needsNetwork && result.image == nil)
        #expect(backend.networkFlags == [false, false])
        #expect(backend.longEdges == [512, 320])
        #expect(backend.originalFlags == [false, false])
        #expect(scheduler.metrics.peakNetwork == 0)
    }

    @Test func scoringUsesOnlyFullCompositionFinalPixelsAndRetriesUndersizedResults() async throws {
        let backend = CoverPreviewTestRequester()
        let scheduler = SharedPhotoImageScheduler(requester: backend, automaticScheduling: false)
        let adequate = try Self.coverImage(longEdge: 256)
        let small = try Self.coverImage(longEdge: 255)
        backend.deliveries = [[.init(image: adequate, isFinal: false), .init(image: small)], [.init(image: adequate)]]
        let asset = photo("old-visit")
        let first = await CoverThumbnailRequest(scheduler: scheduler).value(for: asset)
        #expect(first.image === adequate)
        #expect(backend.longEdges == [512, 320])
        #expect(backend.keys.allSatisfy { $0.forCoverAnalysis && !$0.fillsTarget && $0.width == $0.height })
        #expect(backend.networkFlags == [false, false])
        #expect(adequate.size.height < 256 && adequate.size.width < 256)
        // A low-quality final thumbnail must not poison future reads of the 512 bucket.
        backend.deliveries = [[.init(image: adequate)]]
        let second = await CoverThumbnailRequest(scheduler: scheduler).value(for: asset)
        #expect(second.image === adequate)
        #expect(backend.longEdges == [512, 320, 512])
    }

    @Test func oversizedFastDerivativePreservesAspectAndOrientation() throws {
        let input = try Self.coverImage(longEdge: 1_024)
        let output = try #require(CoverAnalysisPreview.boundedImage(input))
        #expect(output.cgImage?.width == 512 && output.cgImage?.height == 256)
        #expect(output.imageOrientation == input.imageOrientation)
        #expect(CoverAnalysisPreview.boundedImage(try Self.coverImage(longEdge: 128)) == nil)
    }

    @Test func stalledLocalPreviewReleasesItsSubscriptionAtTheDeadline() async {
        let backend = CoverPreviewTestRequester()
        backend.deliveries = [[]]
        let scheduler = SharedPhotoImageScheduler(requester: backend, automaticScheduling: false)
        let result = await CoverThumbnailRequest(scheduler: scheduler).value(for: photo("stalled"),
                                                                              deadline: .now.advanced(by: .milliseconds(60)))
        #expect(result.failed && result.image == nil)
        #expect(scheduler.subscriptionCount == 0 && scheduler.activeLocalCount == 0)
        #expect(backend.longEdges == [512])
        #expect(backend.cancellations == 1)
    }

    private static func coverImage(longEdge: Int) throws -> UIImage {
        let context = try #require(CGContext(data: nil, width: longEdge, height: longEdge / 2,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return UIImage(cgImage: try #require(context.makeImage()), scale: 2, orientation: .right)
    }

    @Test func leavingOneScreenKeepsTheSharedVisitSelectionRunning() async throws {
        let visit = place()
        let store = CoverTestStore(photos: [photo("first"), photo("winner", date: 50)])
        var attempts: [String] = []
        var finishFirstPreview: CheckedContinuation<Void, Never>?
        let selector = ScenicCoverSelector(store: store) { record in
            attempts.append(record.id)
            if attempts.count == 1 {
                await withCheckedContinuation { finishFirstPreview = $0 }
            }
            return record.id == "winner" ? scenic : portrait
        }
        let home = Task {
            try await selector.select(for: [visit], revision: "1", fallback: fallback,
                                      priorityVisitID: visit.id, usesCityPoster: true)
        }
        while finishFirstPreview == nil { await Task.yield() }
        var shelfEntered = false
        let shelf = Task {
            shelfEntered = true
            return try await selector.select(for: [visit], revision: "1", fallback: fallback,
                                             priorityVisitID: visit.id, usesCityPoster: true)
        }
        while !shelfEntered { await Task.yield() }
        home.cancel()
        do { _ = try await home.value; Issue.record("A canceled subscriber received a selection") }
        catch is CancellationError {}
        finishFirstPreview?.resume()
        #expect(try await shelf.value?.assetID == "winner")
        #expect(attempts == ["first", "winner"])
        #expect(await store.candidateLookups == 1)
    }

    @Test func reopenedSelectorReusesCompletedFallbackWhileLocalPreviewsAreUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        let visit = place()
        let otherVisit = place("other", end: 200)
        let records = [photo("older"), photo("latest", date: 100), photo("otherPhoto", place: otherVisit.id, date: 200)]
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: records.count, locatedPhotoCount: records.count, places: [visit, otherVisit], journeys: [])
        try await store.save(.init(index: index, photos: records))
        var attempts = 0
        let cold = ScenicCoverSelector(store: store) { _ in
            attempts += 1
            return nil
        }
        #expect(try await cold.select(for: [visit], revision: "10.0", fallback: fallback,
                                      priorityVisitID: visit.id, usesCityPoster: true) == fallback)
        #expect(attempts > 0)
        let reopened = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: false)
        var otherStarted = false
        var otherFinished = false
        let warm = ScenicCoverSelector(store: reopened) { record in
            if record.placeID == otherVisit.id {
                otherStarted = true
                defer { otherFinished = true }
                try await Task.sleep(for: .seconds(3))
                return scenic
            }
            Issue.record("The existing visit should reuse its completed selection")
            return nil
        }
        let other = Task {
            try await warm.select(for: [otherVisit], revision: "10.0", fallback: nil,
                                  priorityVisitID: otherVisit.id, usesCityPoster: true)
        }
        while !otherStarted { await Task.yield() }
        #expect(try await warm.select(for: [visit], revision: "10.0", fallback: fallback,
                                      priorityVisitID: visit.id, usesCityPoster: true) == fallback)
        #expect(!otherFinished, "A persisted selection should bypass the occupied Vision queue")
        other.cancel()
        _ = await other.result
    }

    @Test func coldVisitsOverlapAndCanceledCardFreesItsSlotWithoutSaving() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"), hidesTransitPhotos: false)
        let visits = (0..<5).map { place("visit-\($0)") }
        let photos = visits.map { photo($0.id, place: $0.id) }
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: visits, journeys: [])
        try await store.save(.init(index: index, photos: photos))
        var started: [String] = []
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        var peak = 0
        let selector = ScenicCoverSelector(store: store) { record in
            started.append(record.id)
            await withCheckedContinuation {
                waiting[record.id] = $0
                peak = max(peak, waiting.count)
            }
            return scenic
        }
        let tasks = visits.map { visit in
            Task { try await selector.select(for: [visit], revision: "10.0", fallback: nil,
                                             priorityVisitID: visit.id, usesCityPoster: true) }
        }
        defer {
            for task in tasks { task.cancel() }
            for continuation in waiting.values { continuation.resume() }
        }
        func waitForStarts(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while started.count < count, ContinuousClock.now < deadline { await Task.yield() }
            try #require(started.count == count)
        }
        try await waitForStarts(2)
        // The first winner is published while the other card still waits.
        let first = started[0]
        let firstIndex = try #require(visits.firstIndex { $0.id == first })
        waiting.removeValue(forKey: first)?.resume()
        #expect(try await tasks[firstIndex].value?.assetID == first)
        try await waitForStarts(4)
        let canceled = started[1]
        let offset = try #require(visits.firstIndex { $0.id == canceled })
        tasks[offset].cancel()
        do { _ = try await tasks[offset].value; Issue.record("Canceled card received a cover") }
        catch is CancellationError {}
        waiting.removeValue(forKey: canceled)?.resume()
        try await waitForStarts(5)
        for id in Array(waiting.keys) { waiting.removeValue(forKey: id)?.resume() }
        for (i, visit) in visits.enumerated() where i != offset {
            #expect(try await tasks[i].value?.assetID == visit.id)
        }
        let saved = try await store.savedVisitCovers(for: visits.map(\.id), excluding: [])
        #expect(peak == 3 && saved.count == 4 && saved[canceled] == nil)
        #expect(try await store.coverAnalyses(for: [canceled], revision: "10.0").isEmpty)
    }

    @Test func concurrentRequestsSerializeAndCanceledAnalysisCannotWrite() async throws {
        let store = CoverTestStore(photos: [photo("old")])
        var running = 0, peak = 0
        let selector = ScenicCoverSelector(store: store) { _ in
            running += 1; peak = max(peak, running)
            defer { running -= 1 }
            try await Task.sleep(for: .milliseconds(100))
            return scenic
        }
        let first = Task { try await selector.select(for: [place()], revision: "1", fallback: fallback) }
        let second = Task { try await selector.select(for: [place("other")], revision: "1", fallback: fallback) }
        _ = try await first.value; _ = try await second.value
        #expect(peak == 1)
        #expect(await store.savedCount == 1)

        let delayedStore = CoverTestStore(photos: [photo("old")])
        var started = false
        let delayed = ScenicCoverSelector(store: delayedStore) { _ in
            started = true
            // An underlying inference can finish after cancellation.
            try? await Task.sleep(for: .milliseconds(200))
            return scenic
        }
        let canceled = Task { try await delayed.select(for: [place()], revision: "1", fallback: fallback) }
        while !started { await Task.yield() }
        delayed.invalidate()
        do { _ = try await canceled.value; Issue.record("Canceled result was accepted") } catch is CancellationError {} catch { throw error }
        #expect(await delayedStore.savedCount == 0)
    }

    @Test func modelFailureStopsInferenceAndDoesNotTriggerCloudDownloads() async throws {
        let store = CoverTestStore(photos: (0..<24).map { photo("asset-\($0)") })
        var calls = 0
        let selector = ScenicCoverSelector(store: store) { _ in
            calls += 1
            throw CoverFixtureError.modelUnavailable
        }
        #expect(try await selector.select(for: [place()], revision: "1", fallback: fallback)?.assetID == "latest")
        #expect(calls == 1)
        #expect(try await selector.select(for: [place()], revision: "1", fallback: fallback)?.assetID == "latest")
        #expect(calls == 1, "A failing model needs a cooldown, not repeated download attempts")
    }

    @Test func candidatesExcludeVideosForeignMembershipAndHiddenTransitPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteTravelIndexStore(databaseURL: url, hidesTransitPhotos: true)
        let later = 70.0 * 86_400
        let photos = [photo("photo", date: 0, favorite: true), photo("photo2", date: 50), photo("photo3", date: 100),
                      photo("hidden", place: "sparse", date: later),
                      PhotoAssetRecord(id: "video", coordinate: .init(latitude: 20, longitude: 30),
                          creationDate: Date(timeIntervalSince1970: 90), pixelWidth: 1920, pixelHeight: 1080,
                          isFavorite: false, mediaKind: .video, duration: 10, placeID: "visit")]
        let visits = [place(), place("sparse", start: later, end: later)]
        let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: 10),
                                sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: visits, journeys: [])
        try await store.save(.init(index: index, photos: photos))
        let candidates = try await store.scenicCoverCandidates(for: visits)
        #expect(!candidates.contains { $0.id == "hidden" || $0.id == "video" })
        #expect(!candidates.isEmpty)
        #expect(try await store.scenicCoverCandidates(for: [place("foreign")]).isEmpty)
        let hiddenWindow = try await store.journeyCoverWindow(for: visits, excluding: [])
        #expect(hiddenWindow?.latest.id == "photo3")
        _ = try await store.setTransitFiltering(false)
        #expect(try await store.scenicCoverCandidates(for: visits).contains { $0.id == "hidden" })
        let rawWindow = try await store.journeyCoverWindow(for: visits, excluding: [])
        #expect(rawWindow?.latest.id == "hidden")
    }
}

private nonisolated enum CoverFixtureError: Error { case modelUnavailable }

@MainActor private final class CoverPreviewTestRequester: SharedPhotoImageRequesting {
    var deliveries: [[OverviewImageDelivery]] = []
    private(set) var keys: [SharedPhotoImageKey] = []
    private(set) var cancellations = 0
    private(set) var networkFlags: [Bool] = []
    private(set) var longEdges: [Int] = []
    private(set) var originalFlags: [Bool] = []

    func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        networkFlags.append(network)
        longEdges.append(key.longEdge)
        originalFlags.append(key.usesOriginal)
        keys.append(key)
        let next = deliveries.isEmpty ? [.init(needsNetwork: true)] : deliveries.removeFirst()
        for result in next { completion(result) }
    }
    func cancel(_ token: UUID) { cancellations += 1 }
    func invalidate(_ ids: Set<String>?) {}
}

private actor CoverTestStore: ScenicCoverStoring {
    let photos: [PhotoAssetRecord]
    var cache: [String: ScenicCoverAnalysis] = [:]
    var savedCount = 0
    private(set) var candidateLookups = 0
    let backups: [String: [PhotoAssetRecord]]
    private(set) var backupLookups = 0
    let strengths: [String: Float]
    init(photos: [PhotoAssetRecord], backups: [String: [PhotoAssetRecord]] = [:], strengths: [String: Float] = [:]) {
        self.photos = photos
        self.backups = backups
        self.strengths = strengths
    }
    func sceneStrengths(for photos: [PhotoAssetRecord], excluding: Set<String>) -> [String: Float] {
        let ids = Set(photos.map(\.id)).subtracting(excluding)
        return strengths.filter { ids.contains($0.key) }
    }
    func scenicCoverBackups(for primaries: [PhotoAssetRecord], missing: Set<String>, excluding: Set<String>) -> [String: [PhotoAssetRecord]] {
        backupLookups += 1
        return backups.filter { missing.contains($0.key) }
    }
    func scenicCoverCandidates(for places: [TravelPlace], journeyWindow: JourneyCoverWindow?, priorityVisitID: String?, excluding: Set<String>) -> [PhotoAssetRecord] {
        candidateLookups += 1
        return photos
    }
    func coverAnalyses(for ids: [String], revision: String) -> [String: ScenicCoverAnalysis] { cache }
    func saveCoverAnalysis(_ analysis: ScenicCoverAnalysis, assetID: String, revision: String) {
        savedCount += 1; cache[assetID] = analysis
    }
}
