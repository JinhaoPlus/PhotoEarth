import Foundation
import Testing
import UIKit
@testable import PhotoEarth

@MainActor
@Suite
struct OnlineSlideshowCatalogTests {
    @Test func usesServerPresentationAndKeepsLegacyPlaylistPlayable() throws {
        let data = Data("""
        {"version":2,"playlists":[
          {"id":"server-category","presentation":{"titles":{"en":"Studio Session"},"symbol":"music.note"},
           "tracks":[{"title":"First","artist":"Artist","stream":"first"},{"title":"Second","artist":"Artist","stream":"second"}]},
          {"id":"piano","tracks":[{"title":"Third","artist":"Artist","stream":"third"},{"title":"Fourth","artist":"Artist","stream":"fourth"}]}
        ]}
        """.utf8)
        let playlists = try OnlineSlideshowCatalog.decode(data)
        #expect(playlists.map(\.displayTitle) == [
            "Studio Session", AppLocalization.string("slideshow.music.online.piano", defaultValue: "Piano")
        ])
        #expect(playlists.map(\.symbol) == ["music.note", "pianokeys"])
        #expect(playlists.last?.tracks.first?.url.path == "/tracks/third/index.m3u8")
    }

    @Test func usesLastValidatedDownloadWhenRefreshFails() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let data = Data("""
        {"version":2,"playlists":[{"id":"piano","tracks":[
          {"title":"First","artist":"Artist","stream":"first"},
          {"title":"Second","artist":"Artist","stream":"second"}
        ]}]}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: OnlineSlideshowCatalog.url, statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        let live = try await OnlineSlideshowCatalog.load(cacheDirectory: cache) { _ in
            (data, response)
        }
        #expect(!live.isCached)
        let invalid = try await OnlineSlideshowCatalog.load(cacheDirectory: cache) { _ in
            (Data("invalid catalog".utf8), response)
        }
        #expect(invalid.isCached)
        let offline = try await OnlineSlideshowCatalog.load(cacheDirectory: cache) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(offline.isCached)
        #expect(offline.playlists.first?.tracks.map(\.title) == ["First", "Second"])
    }
}

@Suite(.serialized)
@MainActor
struct EarthSlideshowTests {
    @Test func transitionRecipesUseFinalPagesAndSpaceAccents() {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        func page(_ index: Int, _ ratios: [CGFloat], minutes: Int = 0, favorite: Bool = false, dynamic: Bool = false) -> SlideshowPageDescriptor {
            let date = start.addingTimeInterval(Double(minutes) * 60)
            return .init(ids: ratios.indices.map { "\(index)-\($0)" }, ratios: ratios, visitID: "one",
                         firstDate: date, lastDate: date, favorite: favorite, dynamic: dynamic)
        }
        var director = SlideshowTransitionDirector()
        let pages = [page(0,[1.5]), page(1,[1.5],favorite: true), page(2,[0.75]), page(3,[1.5]),
                     page(4,[0.75]), page(5,[0.75]), page(6,[0.75]), page(7,[0.75],minutes:45),
                     page(8,[0.75,0.75]), page(9,[0.75,0.75]), page(10,[0.75,0.75])]
        let choices = zip(pages, pages.dropFirst()).map { director.transition(from: $0, to: $1, manual: false, reduced: false).kind }
        #expect(choices == [.settle,.dissolve,.dissolve,.backdrop,.dissolve,.dissolve,.reveal,.dissolve,.dissolve,.stagger])
        #expect(director.transition(from: pages[0], to: pages[1], manual: false, reduced: false).kind == .settle)
        #expect(director.transition(from: pages[0], to: pages[1], manual: true, reduced: false) == .init(kind: .dissolve, duration: 0.16))
        #expect(director.transition(from: pages[0], to: pages[1], manual: false, reduced: true) == .init(kind: .dissolve, duration: 0.20))
        for next in [page(11,[0.75,0.56]), page(12,[1.5],favorite:true,dynamic:true), page(13,[1.5],minutes:1440)] {
            var fresh = SlideshowTransitionDirector()
            #expect(fresh.transition(from: pages[9], to: next, manual: false, reduced: false).kind == .dissolve)
        }
    }

    @Test func highMotionSharesOneBudgetAcrossEffectsAndRevisits() {
        var director = SlideshowTransitionDirector()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func page(_ n: Int, _ ratios: [CGFloat] = [1.5], favorite: Bool = false, dynamic: Bool = false) -> SlideshowPageDescriptor {
            .init(ids: ratios.indices.map { "\(n)-\($0)" }, ratios: ratios, visitID: "trip",
                  firstDate: date, lastDate: date, favorite: favorite, dynamic: dynamic)
        }
        func choose(_ a: SlideshowPageDescriptor, _ b: SlideshowPageDescriptor, manual: Bool = false, reduced: Bool = false) -> SlideshowEffect {
            director.transition(from: a, to: b, manual: manual, reduced: reduced).kind
        }
        for n in 0..<15 {
            #expect(choose(page(n), page(n + 1, [1.8])) == .dissolve)
            #expect(choose(page(n), page(n + 1, [1.8])) == .dissolve)
        }
        let wide = page(16, [1.8])
        #expect(choose(page(15), wide, manual: true) == .dissolve)
        #expect(choose(page(15), wide, reduced: true) == .dissolve)
        #expect(choose(page(15), page(99, dynamic: true)) == .dissolve)
        #expect(choose(page(15), wide) == .panoramaGlide)
        #expect(choose(page(15), wide) == .dissolve)
        for n in 17..<32 {
            #expect(!choose(page(n), page(n + 1, favorite: true)).isHighMotion)
            #expect(choose(page(15), wide) == .dissolve)
        }
        #expect(choose(page(32), page(33, favorite: true)) == .focusPullback)
        for n in 34..<49 { #expect(choose(page(n), page(n + 1)) == .dissolve) }
        #expect(choose(page(49), page(50, [0.6, 0.6, 0.6])) == .centerOpen)
    }

    @Test func openingAPortraitTriptychCountsTheCenterPhotoFirst() {
        let effect = EarthSlideshowTransition(kind: .centerOpen, duration: SlideshowEffect.centerOpen.duration)
        let ratios: [CGFloat] = [0.6, 0.6, 0.6]
        func visible(_ progress: Double) -> IndexSet {
            effect.visibleTiles(at: progress, ratios: ratios, in: SlideshowCollageLayout.television)
        }
        #expect(visible(0).isEmpty)
        #expect(visible(0.15) == IndexSet(integer: 1))
        #expect(visible(1) == IndexSet(integersIn: 0..<3))
    }

    @Test func frozenMembershipSurvivesIndexReplacementAndPagesTiedDatesWithoutGaps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slideshow-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let source = (0..<170).map { record($0, visit: 0, date: date) }
        let place = visit(0, photoCount: source.count)
        let originalJourney = journey("original-trip", [place])
        try await store.save(snapshot(places: [place], records: source, journeys: [originalJourney]))
        let wall = try await store.photoReadSnapshot()
        try await wall.detachWallForSlideshow()
        let excluded = Set(source.prefix(60).map(\.id))
        try await store.save(snapshot(places: [place], records: [source[0]], journeys: [journey("new-trip", [place])]))
        let frozen = try await wall.slideshowSnapshot(for: [place], excluding: excluded)
        #expect(frozen.journeys == [originalJourney])
        let restoredPage = try await wall.photoPage(for: [place.id], offset: 0, limit: 48)
        #expect(restoredPage.records.count == 48)
        // The original wall and slideshow still exist, but neither occupies
        // either of the two permitted live WAL reader leases.
        let liveReaders = try await [store.photoReadSnapshot(), store.photoReadSnapshot()]
        #expect(liveReaders.count == 2)
        var request = SlideshowPageSequence.Request(visit: place)
        var read: [String] = []
        repeat {
            let page = try await frozen.page(request, limit: 48)
            #expect(page.records.count <= 48)
            if page.next != nil { #expect(page.records.count == 48) }
            read += page.records.map(\.id)
            request.after = page.next
        } while request.after != nil
        #expect(read == source.map(\.id).filter { !excluded.contains($0) }.sorted())
    }

    @Test func completelyExcludedStopsDoNotAdvertiseAnEmptyJourney() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let hidden = visit(0, photoCount: 1)
        let visible = visit(1, photoCount: 2)
        let visits = [hidden, visible]
        let source = [record(0, visit: 0), record(0, visit: 1), record(1, visit: 1)]
        try await store.save(snapshot(places: visits, records: source,
            journeys: [journey("hidden", [hidden]), journey("visible", [visible])]))
        let wall = try await store.photoReadSnapshot()
        let frozen = try await wall.slideshowSnapshot(for: visits, excluding: Set(source.prefix(2).map(\.id)))
        let plan = SlideshowPageSequence(places: frozen.places ?? [], journeys: frozen.journeys)
        #expect(plan.segments.map(\.id) == ["visible"])
        let page = try await frozen.page(.init(visit: visible), limit: 3)
        #expect(page.records.map(\.id) == [source[2].id])
    }

    @Test func frozenWallStartsWithItsOrderedFirstPageAndKeepsRemovedAssetsOut() async throws {
        let place = visit(0, photoCount: 8)
        let source = (0..<8).map { record($0, visit: 0) }
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let coordinator = EarthSlideshowCoordinator(scope: .init(id: "view", title: "", kind: .currentView),
            places: [place], reduceMotion: true, analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: {
                for await _ in gate { break }
                return try frozen(source)
            }, cameraAction: { _, _ in })
        coordinator.removeAssets([source[0].id])
        coordinator.start()
        defer { coordinator.cancel(); continuation.finish() }
        #expect(coordinator.phase == .preparing)
        #expect(coordinator.currentItem == nil)
        continuation.yield(())
        try await waitUntil { coordinator.filmstrip.count == 7 }
        #expect(coordinator.currentItem?.id == source[1].id)
        #expect(Set(coordinator.filmstrip.map(\.id)) == Set(source.dropFirst().map(\.id)))
    }

    @Test func frozenViewportReadsOnlyProjectedFramesAcrossSparseChronologicalPages() async throws {
        let place = visit(0, photoCount: 125)
        let source = (0..<125).map { ordinal in
            let base = record(ordinal, visit: 0)
            return PhotoAssetRecord(id: base.id,
                coordinate: .init(latitude: 0, longitude: ordinal.isMultiple(of: 20) ? 1 : -1),
                creationDate: base.creationDate, pixelWidth: 1280, pixelHeight: 720,
                isFavorite: false, placeID: place.id)
        }
        let viewport = PhotoViewportSnapshot(viewport: .init(center: place.coordinate, angularRadius: 15),
                                            isCurrent: { true }, containsCoordinate: { $0.longitude > 0 })
        let reader = ViewportSlideshowSnapshot(source: try frozen(source), viewport: viewport, members: [place.id])
        var request = SlideshowPageSequence.Request(visit: place)
        var read: [String] = []
        repeat {
            let page = try await reader.page(request, limit: 3)
            #expect(page.records.count <= 3)
            read += page.records.map(\.id)
            request.after = page.next
        } while request.after != nil
        #expect(read == source.filter { $0.coordinate.longitude > 0 }.map(\.id))
    }

    @Test func largeFixedScopesReadOnlyAnOpeningPageAndReleaseTheLiveReader() async throws {
        for count in [10_000, 50_000] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SQLiteTravelIndexStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
            let place = visit(0, photoCount: count)
            let records = (0..<count).map { record($0, visit: 0) }
            try await store.save(snapshot(places: [place], records: records))
            let app = AppModel()
            let viewport = PhotoViewportSnapshot(viewport: .init(center: place.coordinate, angularRadius: 30),
                                                isCurrent: { true }, containsCoordinate: { _ in true })
            let clock = ContinuousClock()
            for kind in [EarthSlideshowScope.Kind.library, .city, .currentView] {
                let reader = try await store.photoReadSnapshot()
                let wall = try await app.photoPage(in: viewport, offset: 0, limit: 48, reader: reader)
                let start = clock.now
                if kind == .currentView {
                    var opening: Duration?
                    let show = app.makeEarthSlideshow(scope: .init(id: "view", title: "", kind: kind), places: [place],
                        viewport: viewport, reader: reader, wallRecords: wall.records, reduceMotion: true) { _, _ in
                        if opening == nil { opening = start.duration(to: clock.now) }
                    }
                    show.start()
                    defer { show.cancel() }
                    try await waitUntil(timeout: .seconds(10)) { opening != nil && show.currentItem != nil }
                    #expect(show.currentItem?.id == records.first?.id)
                    #expect(!wall.records.contains { $0.id == records.first?.id })
                    print("Slideshow startup rows=\(count) scope=view title=\(try #require(opening)) firstSelected=\(start.duration(to: clock.now))")
                } else {
                    let frozen = try await reader.slideshowSnapshot(for: kind == .library ? nil : [place], excluding: [])
                    let detached = clock.now
                    let page = try await frozen.page(.init(visit: place), limit: 3)
                    #expect(page.records.map(\.id) == records.prefix(3).map(\.id))
                    #expect(page.next != nil)
                    print("Slideshow startup rows=\(count) scope=\(kind) detachAndVisits=\(start.duration(to: detached)) first3=\(start.duration(to: clock.now))")
                }
            }
        }
    }

    @Test func identicalVisionFramesAreConservativelyMergedAndFavoriteWins() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
            UIColor.white.setFill()
            context.fill(CGRect(x: 22, y: 18, width: 52, height: 42))
        }
        let provider = FixedThumbnailProvider(image: image)
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: provider)
        let first = record(0, visit: 0, favorite: false)
        let favorite = record(1, visit: 0, favorite: true)

        let result = try await analyzer.selectPage([first, favorite], longEdge: 128)
        result.commit()
        #expect(result.records.map(\.id) == [favorite.id])
        let later = try await analyzer.selectPage([record(20, visit: 3)], longEdge: 128)
        #expect(later.records.isEmpty)
    }

    @Test func identicalVideoPostersAloneDoNotRemoveDifferentClips() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48)).image { context in
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        }
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: FixedThumbnailProvider(image: image))
        let first = record(1, visit: 0, mediaKind: .video, duration: 3)
        let second = record(2, visit: 0, mediaKind: .video, duration: 8)
        let a = try await analyzer.selectPage([first], longEdge: 96)
        a.commit()
        let b = try await analyzer.selectPage([second], longEdge: 96)
        #expect(b.records.map(\.id) == [second.id])
    }

    @Test func delayedOpeningPreviewsShareOneWaitAndRetainEveryCandidate() async throws {
        let source = (0..<3).map { record($0, visit: 0) }
        let provider = DelayedOpeningThumbnailProvider()
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: provider)
        let selection = try await analyzer.selectPage(source, longEdge: 384, prepareOpening: true)
        #expect(provider.peakWaiting == 3)
        #expect(Set(selection.records.map(\.id)) == Set(source.map(\.id)))
    }

    @Test func discardedAnalysisLeavesTheSamePageEligibleOnResume() async throws {
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider())
        let candidate = record(0, visit: 0)
        _ = try await analyzer.selectPage([candidate], longEdge: 96)
        let resumed = try await analyzer.selectPage([candidate], longEdge: 96)
        #expect(resumed.records == [candidate])
        resumed.commit()
        let repeated = try await analyzer.selectPage([candidate], longEdge: 96)
        #expect(repeated.records.isEmpty)
    }

    @Test func reencodedImageAcrossDistantPagesIsSkippedWhileAnotherSubjectAtTheSameTimeSurvives() async throws {
        let paris = try #require(SamplePhotoResource.url(for: "sample-paris-1"))
        let rio = try #require(SamplePhotoResource.url(for: "sample-rio-1"))
        let first = try #require(UIImage(contentsOfFile: paris.path))
        let other = try #require(UIImage(contentsOfFile: rio.path))
        let encoded = try #require(first.jpegData(compressionQuality: 0.75))
        let reencoded = try #require(UIImage(data: encoded))
        let original = record(0, visit: 0)
        let differentSubject = record(1, visit: 0, date: original.creationDate)
        let copy = record(200, visit: 3)
        let provider = MappedThumbnailProvider(images: [original.id: first, differentSubject.id: other, copy.id: reencoded])
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: provider)
        let opening = try await analyzer.selectPage([original, differentSubject], longEdge: 384)
        #expect(Set(opening.records.map(\.id)) == [original.id, differentSubject.id])
        opening.commit()
        for pageIndex in 1...4 {
            let page = (0..<8).map { record(pageIndex * 8 + $0, visit: 2) }
            let result = try await analyzer.selectPage(page, longEdge: 384)
            result.commit()
        }
        let distant = try await analyzer.selectPage([copy], longEdge: 384)
        #expect(distant.records.isEmpty)
    }

    @Test func slideshowSpacesPhotosAcrossPagesAndVisitsWhileKeepingVideo() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 60_059)
        let source = [
            record(0, visit: 1, date: base),
            record(1, visit: 1, date: base.addingTimeInterval(2), mediaKind: .livePhoto),
            record(2, visit: 1, date: base.addingTimeInterval(6), mediaKind: .video, duration: 4),
            record(3, visit: 1, date: base.addingTimeInterval(59.99)),
            record(4, visit: 1, date: base.addingTimeInterval(60), mediaKind: .livePhoto),
            record(5, visit: 0, date: base.addingTimeInterval(-120)),
            record(6, visit: 0, date: base.addingTimeInterval(-10))
        ]
        let stops = [visit(0, photoCount: 2), visit(1, photoCount: 5)]
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "", kind: .library),
            places: stops, configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count == 4 }
        #expect(show.filmstrip.map(\.id) == [source[0], source[2], source[4], source[5]].map(\.id))
    }

    @Test func aPhotoSkippedForTimingDoesNotHideALaterCopyOfItsScene() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 60_059)
        let first = record(0, visit: 0, date: base)
        let tooSoon = record(1, visit: 0, date: base.addingTimeInterval(10))
        let anotherBurstFrame = record(2, visit: 0, date: base.addingTimeInterval(15))
        let later = record(3, visit: 0, date: base.addingTimeInterval(65))
        let paris = try #require(SamplePhotoResource.url(for: "sample-paris-1"))
        let rio = try #require(SamplePhotoResource.url(for: "sample-rio-1"))
        let firstScene = try #require(UIImage(contentsOfFile: paris.path))
        let secondScene = try #require(UIImage(contentsOfFile: rio.path))
        let previews = MappedThumbnailProvider(images: [
            first.id: firstScene, tooSoon.id: secondScene, anotherBurstFrame.id: secondScene, later.id: secondScene
        ])
        let show = EarthSlideshowCoordinator(scope: .init(id: "city", title: "", kind: .city),
            places: [visit(0, photoCount: 4)], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: previews),
            makeSnapshot: { try frozen([first, tooSoon, anotherBurstFrame, later]) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count == 2 }
        #expect(show.filmstrip.map(\.id) == [first.id, later.id])
    }

    @Test func sustainedSessionVisitsEveryPeriodWithoutRepeats() async throws {
        let visits = (0..<8).map { visit($0, photoCount: 20) }
        let source = (0..<8).flatMap { v in (0..<20).map { record($0, visit: v) } }
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.01
        config.chapterTitleDuration = 0.01
        config.stillDuration = 30
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: visits, configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        show.start()
        try await waitUntil { show.phase == .presentingItem }
        var played = Set<String>()
        var periods = Set<String>()
        for _ in source {
            try await waitUntil { show.currentItem.map { !played.contains($0.id) } ?? false }
            let item = try #require(show.currentItem)
            let inserted = played.insert(item.id).inserted
            #expect(inserted)
            if let visitID = item.record.placeID { periods.insert(visitID) }
            #expect(show.filmstrip[show.itemIndex].id == item.id)
            show.markCurrentItemReady(item.id)
            show.move(forward: true)
        }
        #expect(played == Set(source.map(\.id)))
        #expect(periods.count == 8)
        #expect(show.phase == .ending || show.phase == .completed)
        show.cancel()
    }

    @Test func browsingThreeHundredPhotosPagesForwardAndSeeksBackWithoutPlaying() async throws {
        let source = (0..<300).map { record($0, visit: 0) }
        let show = EarthSlideshowCoordinator(scope: .init(id: "city", title: "", kind: .city),
            places: [visit(0, photoCount: 300)], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem }
        show.setPaused(true)
        while show.filmstrip.count < source.count {
            let count = show.filmstrip.count
            show.prepareFilmstrip(around: try #require(show.filmstrip.last?.id))
            try await waitUntil { show.filmstrip.count > count }
            try #require(show.filmstrip.count > count)
        }
        #expect(show.filmstrip.map(\.id) == source.map(\.id))
        #expect(show.currentItem?.id == source[0].id && show.viewedCount == 0)
        show.selectPausedItem(source[299].id)
        #expect(show.currentItem?.record == source[299])
        show.removeAssets([source[1].id])
        show.selectPausedItem(source[1].id)
        #expect(show.currentItem?.id == source[299].id)
        show.selectPausedItem(source[0].id)
        #expect(show.currentItem?.record == source[0])
        #expect(show.nextItemForPrefetch?.record == source[2] && show.isPaused)
    }

    @Test func activePlaybackKeepsTheTelevisionAwakeAndTerminalStatesReleaseIt() {
        let active: [EarthSlideshowPhase] = [.preparing, .earthIntro, .chapterTitle, .presentingItem,
            .transitioningItem, .earthChapterBridge, .ending]
        let terminal: [EarthSlideshowPhase] = [.idle, .completed, .cancelled, .failed("unavailable")]
        let activeStaysAwake = active.allSatisfy { $0.keepsDisplayAwake }
        #expect(activeStaysAwake)
        #expect(terminal.allSatisfy { !$0.keepsDisplayAwake })
    }

    @Test func scopedJourneysReadEveryPageOfEachVisitInOrderAndRetryInPlace() throws {
        let visits = (0..<4).map { visit($0, photoCount: 20) }
        let recent = journey("recent", [visits[3], visits[1], visits[2]])
        let old = journey("old", [visits[0]])
        // The wall contains just three of the four stops in the two journeys.
        var pages = SlideshowPageSequence(places: [visits[3], visits[0], visits[1]], journeys: [old, recent])
        #expect(pages.segments.map(\.id) == ["recent", "old"])
        #expect(pages.segments[0].visits == [visits[1], visits[3]])
        #expect(pages.segmentIndex(forVisitID: visits[2].id) == nil)
        let initial = pages.begin()
        let first = try #require(initial)
        #expect(first.visit == visits[1])
        pages.interrupt()
        let resumed = pages.begin()
        #expect(resumed == first)
        let cursor = SlideshowPageSequence.Cursor(record(0, visit: 1))
        pages.finish(first, next: cursor)
        let next = pages.begin()
        let continuation = try #require(next)
        #expect(continuation.visit == first.visit && continuation.after == cursor)
        pages.finish(first, next: nil)
        #expect(pages.state == .reading(continuation))
        pages.fail(continuation)
        let automatic = pages.begin()
        let retry = try #require(automatic)
        #expect(retry.visit == first.visit && retry.after == cursor && retry.attempt == 1)
        pages.fail(retry)
        #expect(pages.state == .retryable)
        pages.retry()
        let retried = pages.begin()
        #expect(retried == continuation)
        pages.finish(continuation, next: nil)
        let nextStop = pages.begin()
        let stop = try #require(nextStop)
        #expect(stop.visit == visits[3])
        pages.finish(stop, next: nil)
        let nextJourney = pages.begin()
        let last = try #require(nextJourney)
        #expect(last.visit == visits[0])
        pages.finish(last, next: nil)
        #expect(pages.state == .exhausted)
    }

    @Test func favoritesAndMediaKindsKeepTheirCaptureOrderAfterSelection() async throws {
        let source = [record(0, visit: 0), record(1, visit: 0), record(2, visit: 0),
                      record(3, visit: 0, favorite: true, mediaKind: .video, duration: 5)]
        let analyzer = PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider())
        let selected = try await analyzer.selectPage(Array(source.reversed()), longEdge: 96)
        #expect(selected.records == source)
    }

    @Test func preparedQueueWaitsForConfirmationEvenIfTheFirstPhotoIsRemoved() async throws {
        let source = [record(0, visit: 0), record(1, visit: 0)]
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: [visit(0, photoCount: 2)], configuration: .standard, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        show.start(waitingForConfirmation: true)
        try await waitUntil { show.preparation.readyCount == 2 }
        #expect(show.awaitsPlaybackConfirmation)
        #expect(show.phase == .preparing)

        let firstID = try #require(show.currentItem?.id)
        show.removeAssets([firstID])
        #expect(show.phase == .preparing)
        #expect(show.currentItem?.id != firstID)

        show.beginPlayback()
        #expect(!show.awaitsPlaybackConfirmation)
        #expect(show.phase == .earthIntro)
        show.cancel()
    }

    @Test func openingTitleAppearsBeforeTheFirstPageIsSelected() async throws {
        let source = [record(0, visit: 0)]
        let firstVisit = visit(0, photoCount: 1)
        let provider = DelayedOpeningThumbnailProvider(delay: .milliseconds(400))
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.02
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: [firstVisit], configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: provider),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start(waitingForConfirmation: true)
        try await waitUntil { provider.peakWaiting > 0 }
        #expect(show.phase == .preparing)
        #expect(show.currentItem == nil)

        show.beginPlayback()
        #expect(show.phase == .earthIntro)
        #expect(show.displayedChapter?.visit == firstVisit)
        #expect(show.displayedJourneyIndex == 0)
        #expect(show.currentItem == nil)

        try await waitUntil { show.phase == .presentingItem }
        #expect(show.currentItem?.record == source[0])
    }

    @Test func removingTheOpeningCandidatesClearsTheirTitle() async throws {
        let first = record(0, visit: 1)
        let next = record(0, visit: 0)
        let visits = [visit(1, photoCount: 1), visit(0, photoCount: 1)]
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: visits, configuration: .standard, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: DelayedOpeningThumbnailProvider(delay: .milliseconds(400))),
            makeSnapshot: { try frozen([first, next]) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .earthIntro }
        #expect(show.displayedChapter?.visit == visits[0])
        #expect(show.currentItem == nil)

        show.removeAssets([first.id])
        #expect(show.phase == .preparing)
        #expect(show.displayedChapter == nil)

        try await waitUntil { show.phase == .earthIntro }
        #expect(show.displayedChapter?.visit == visits[1])
    }

    @Test func allMissingMediaCanBeRetriedWithoutReplayingSuccessfulItems() async throws {
        let source = [record(0, visit: 0), record(1, visit: 0)]
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.01
        config.chapterTitleDuration = 0.01
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: [visit(0, photoCount: 2)], configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        show.start()
        try await waitUntil { show.phase == .presentingItem }
        show.markCurrentItemReady(source[0].id)
        show.move(forward: true)
        let originalAttempt = show.mediaRetryRevision
        show.markCurrentItemUnavailable(source[1].id, revision: originalAttempt)
        #expect(show.mediaRetryRevision != originalAttempt)
        show.markCurrentItemUnavailable(source[1].id, revision: originalAttempt)
        #expect(show.currentItem?.id == source[1].id)
        show.markCurrentItemUnavailable(source[1].id, revision: show.mediaRetryRevision)
        try await waitUntil { if case .failed = show.phase { true } else { false } }
        #expect(show.viewedCount == 1)
        show.retry()
        try await waitUntil { show.currentItem?.id == source[1].id }
        show.markCurrentItemReady(source[1].id)
        try await waitUntil { show.phase == .presentingItem }
        #expect(show.viewedCount == 2)
        show.cancel()
    }

    @Test func pausingFreezesTheDwellClockAndResumeContinues() async throws {
        let place = visit(0, photoCount: 2)
        let source = [record(0, visit: 0), record(1, visit: 0)]
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        configuration.stillDuration = 0.08
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(source[0].id)
        coordinator.setPaused(true)
        try await Task.sleep(for: .milliseconds(140))
        #expect(coordinator.itemIndex == 0)

        coordinator.setPaused(false)
        coordinator.move(forward: false)
        try await waitUntil { coordinator.itemIndex == 1 }
        #expect(coordinator.navigationDirection == 1)
        coordinator.cancel()
    }

    @Test func sceneSuspensionResumesOnlyAPreviouslyPlayingSlideshow() async throws {
        let place = visit(0, photoCount: 2)
        let source = [record(0, visit: 0), record(1, visit: 0)]
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        configuration.stillDuration = 30
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(source[0].id)

        coordinator.suspend()
        coordinator.suspend()
        #expect(coordinator.isPaused)
        coordinator.resumeAfterSuspension()
        #expect(!coordinator.isPaused)

        coordinator.setPaused(true)
        coordinator.suspend()
        coordinator.resumeAfterSuspension()
        #expect(coordinator.isPaused)
        coordinator.cancel()
    }

    @Test func manualNavigationPublishesTheSameShortDurationUsedByTheTransitionClock() async throws {
        let place = visit(0, photoCount: 2)
        let source = [record(0, visit: 0), record(1, visit: 0)]
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        configuration.stillDuration = 30
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(source[0].id)
        coordinator.move(forward: true)
        #expect(coordinator.activeTransition == nil)
        try await Task.sleep(for: .milliseconds(190))
        #expect(coordinator.canvasPage?.record.id == source[0].id)
        #expect(coordinator.phase == .transitioningItem)
        coordinator.markCurrentItemReady(source[1].id)

        #expect(coordinator.phase == .transitioningItem)
        #expect(coordinator.itemIndex == 1)
        #expect(coordinator.activeTransition == .init(kind: .dissolve, duration: 0.16))
        coordinator.setPaused(true)
        let frozenProgress = coordinator.transitionProgress(at: .now)
        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.transitionProgress(at: .now) == frozenProgress)
        #expect(coordinator.phase == .transitioningItem)
        coordinator.setPaused(false)
        try await waitUntil(timeout: .seconds(1)) { coordinator.phase == .presentingItem }
        #expect(coordinator.activeTransition == nil)
        coordinator.cancel()
    }

    @Test func enablingReduceMotionFinishesTheCurrentTransitionAndShortensTheNextAutomaticTransition() async throws {
        let place = visit(0, photoCount: 3)
        let records = (0..<3).map { record($0, visit: 0) }
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.stillDuration = 0.08
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place], configuration: configuration, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(records) }, cameraAction: { _, _ in }
        )
        defer { coordinator.cancel() }
        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(records[0].id)
        try await waitUntil { coordinator.currentItem?.id == records[1].id }
        coordinator.markCurrentItemReady(records[1].id)
        #expect(coordinator.activeTransition != nil)
        coordinator.updateReduceMotion(true)
        #expect(coordinator.activeTransition == nil)
        #expect(coordinator.canvasPage?.record.id == records[1].id)
        try await waitUntil { coordinator.currentItem?.id == records[2].id }
        coordinator.markCurrentItemReady(records[2].id)
        #expect(coordinator.activeTransition == .init(kind: .dissolve, duration: 0.20))
    }

    @Test func selectingAPhotoAcrossChaptersPreviewsItWithoutResumingPlayback() async throws {
        let visits = [visit(0, photoCount: 1), visit(1, photoCount: 1)]
        let source = [record(0, visit: 0), record(0, visit: 1)]
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.01
        config.chapterTitleDuration = 0.01
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "Library", kind: .collection),
            places: visits, configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) }, cameraAction: { _, _ in })
        defer { show.cancel() }

        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count == 2 }
        let first = try #require(show.currentItem?.id)
        let other = try #require(show.filmstrip.first { $0.id != first })
        show.selectPausedItem(other.id)
        #expect(show.currentItem?.id == first)
        show.setPaused(true)
        show.selectPausedItem("removed")
        #expect(show.currentItem?.id == first)

        show.selectPausedItem(other.id)
        #expect(show.isPaused)
        #expect(show.currentItem?.id == other.id)
        #expect(show.phase == .presentingItem)
        show.setPaused(false)
        #expect(show.currentItem?.id == other.id)
    }

    @Test func dynamicPlaybackReceivesItsFullDwellAfterContentBecomesReady() async throws {
        let place = visit(0, photoCount: 2)
        let source = [
            record(0, visit: 0, mediaKind: .video, duration: 0.22),
            record(1, visit: 0),
        ]
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        configuration.maximumVideoDuration = 0.22
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(source[0].id)
        try await Task.sleep(for: .milliseconds(140))
        coordinator.synchronizeDwellWithDynamicPlayback(source[0].id)
        try await Task.sleep(for: .milliseconds(120))
        #expect(coordinator.itemIndex == 0)
        try await waitUntil(timeout: .seconds(1)) { coordinator.itemIndex == 1 }
        coordinator.cancel()
    }

    @Test(arguments: [PhotoMediaKind.livePhoto, .video])
    func finishedMotionAdvancesWithoutWaitingForTheFallbackDwell(kind: PhotoMediaKind) async throws {
        let place = visit(0, photoCount: 2)
        let source = [
            record(0, visit: 0, mediaKind: kind, duration: 10),
            record(1, visit: 0),
        ]
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        configuration.dynamicEndHold = 0.02
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )
        defer { coordinator.cancel() }

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.markCurrentItemReady(source[0].id)
        coordinator.synchronizeDwellWithDynamicPlayback(source[0].id)
        coordinator.dynamicPlaybackDidFinish("stale-item")
        try await Task.sleep(for: .milliseconds(60))
        #expect(coordinator.itemIndex == 0)

        coordinator.dynamicPlaybackDidFinish(source[0].id)
        coordinator.setPaused(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(coordinator.itemIndex == 0)
        coordinator.setPaused(false)
        try await waitUntil(timeout: .milliseconds(500)) { coordinator.itemIndex == 1 }
    }

    @Test func deletingTheCurrentMemoryUsesItsImmediateSuccessorAndKeepsStableIdentity() async throws {
        let place = visit(0, photoCount: 3)
        let source = (0..<3).map { record($0, visit: 0) }
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 0.02
        configuration.chapterTitleDuration = 0.02
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: place.id, title: place.name, kind: .recentVisit),
            places: [place],
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil { coordinator.phase == .presentingItem }
        coordinator.removeAssets([source[0].id])
        #expect(coordinator.currentItem?.id == source[1].id)

        coordinator.move(forward: true)
        #expect(coordinator.currentItem?.id == source[2].id)
        coordinator.removeAssets([source[1].id])
        #expect(coordinator.currentItem?.id == source[2].id)
        #expect(coordinator.itemIndex == 0)
        coordinator.cancel()
    }

    @Test func firstPagePlaysWhileTheNextPageOfTheSameVisitIsStillBeingAnalyzed() async throws {
        let visits = [visit(0, photoCount: 12), visit(1, photoCount: 12)]
        let source = (0..<12).map { record($0, visit: 0) }
            + (0..<12).map { record($0, visit: 1) }
        let provider = BlockingAfterSixThumbnailProvider()
        var configuration = EarthSlideshowConfiguration.standard
        configuration.earthIntroDuration = 30
        let coordinator = EarthSlideshowCoordinator(
            scope: EarthSlideshowScope(id: "city", title: "City", kind: .city),
            places: visits,
            configuration: configuration,
            reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: provider),
            makeSnapshot: { try frozen(source) },
            cameraAction: { _, _ in }
        )

        coordinator.start()
        try await waitUntil(timeout: .seconds(1)) { provider.requestCount == 7 }
        #expect(coordinator.phase == .earthIntro)
        #expect(coordinator.filmstrip.count == 3)
        #expect(coordinator.preparation.stage == .analyzing)
        #expect(provider.requestCount == 7)
        coordinator.cancel()
    }

    @Test(arguments: [false, true])
    func skippingToAnUnpreparedJourneyBypassesUnreadPagesAndPreservesPause(paused: Bool) async throws {
        let old = visit(0, photoCount: 2)
        let recent = visit(1, photoCount: 100)
        let source = (0..<100).map { record($0, visit: 1) } + (0..<2).map { record($0, visit: 0) }
        let journeys = [journey("older", [old]), journey("newer", [recent])]
        let show = EarthSlideshowCoordinator(scope: .init(id: "city", title: "City", kind: .city),
            places: [old, recent], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source, journeys: journeys) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count > 4 }
        #expect(show.currentJourneyNumber == 1 && show.journeyCount == 2 && show.canSkipToNextJourney)
        #expect(show.currentJourney?.id == "newer")
        #expect(show.filmstrip.allSatisfy { $0.placeID == recent.id })
        show.markCurrentItemReady(source[0].id)
        show.setPaused(paused)
        show.skipToNextJourney()
        try await waitUntil { show.phase == .presentingItem && show.currentJourney?.id == "older" }
        #expect(show.currentItem?.id == "asset-0-0")
        #expect(show.currentJourneyNumber == 2 && !show.canSkipToNextJourney)
        #expect(show.isPaused == paused)
        #expect(show.viewedCount == 1)
        #expect(show.preparation.candidateCount < 30)
        show.skipToNextJourney()
        #expect(show.currentItem?.id == "asset-0-0")
        show.move(forward: false)
        #expect(show.currentItem?.id == "asset-1-0")
        show.skipToNextJourney()
        #expect(show.currentItem?.id == "asset-0-0")
        #expect(show.canSkipToPreviousJourney)
        show.skipToPreviousJourney()
        #expect(show.currentItem?.id == "asset-1-0")
        #expect(!show.canSkipToPreviousJourney && show.isPaused == paused)
        show.prepareFilmstrip(around: "asset-1-0")
        try await waitUntil { show.filmstrip.count >= 18 }
        #expect(show.filmstrip.prefix(18).map(\.id) == (0..<18).map { "asset-1-\($0)" })
        while show.filmstrip.count < source.count {
            let count = show.filmstrip.count
            show.prepareFilmstrip(around: show.filmstrip.last?.id)
            try await waitUntil { show.filmstrip.count > count }
            try #require(show.filmstrip.count > count)
        }
        #expect(show.filmstrip.map(\.id) == source.map(\.id))
        show.skipToNextJourney()
        try await waitUntil { show.currentItem?.id == "asset-0-0" }
        #expect(show.isPaused == paused)
        show.restart()
        try await waitUntil { show.phase == .presentingItem }
        #expect(show.currentJourney?.id == "newer" && show.canSkipToNextJourney)
    }

    @Test func tripFiltersIncludeEveryVisitedCityAndBothYearsOfACrossYearTrip() {
        let calendar = Calendar(identifier: .gregorian)
        func stop(_ id: String, _ name: String, _ code: String, year: Int) -> TravelPlace {
            let date = calendar.date(from: DateComponents(year: year, month: 1, day: 2))!
            return TravelPlace(id: id, name: name, country: code, regionCode: code, offlinePlaceID: id,
                               coordinate: .init(latitude: 0, longitude: 0), startDate: date, endDate: date,
                               photoCount: 5, coverAssetID: nil)
        }
        let tokyo = stop("t", "Tokyo", "JP", year: 2024)
        let paris = stop("p", "Paris", "FR", year: 2025)
        let osaka = stop("o", "Osaka", "JP", year: 2023)
        let trip = EarthSlideshowSegment(id: "cross", visits: [tokyo, paris])
        let index = SlideshowJourneyFilter([trip, .init(id: "domestic", visits: [osaka])], calendar: calendar)
        #expect(index.years == [2025, 2024, 2023])
        #expect(index.citiesByCountry["region:JP"]?.count == 2)
        #expect(index.matches(year: 2024, country: "region:FR", query: "tOkYO  páris") == [trip])
        #expect(index.matches(year: 2025, country: "region:JP", city: .catalog("t"), query: "") == [trip])
        #expect(index.matches(year: 2023, country: "region:JP", query: "Tokyo").isEmpty)
        #expect(index.matches(year: nil, country: nil, query: "OSAKA").map(\.id) == ["domestic"])
    }

    @Test func homeTripSelectionReplacesPreloadedItemsAndSurvivesSkipAndReplay() async throws {
        var stops = (0..<3).map { visit($0, photoCount: 1) }
        for i in stops.indices { stops[i].offlinePlaceID = "tokyo" }
        let source = stops.indices.map { record(0, visit: $0, date: stops[$0].startDate) }
        let trips = [journey("new", [stops[2]]), journey("middle", [stops[1]])]
        let show = EarthSlideshowCoordinator(scope: .init(id: "library", title: "Show", kind: .library),
            places: stops, configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source, journeys: trips) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start(waitingForConfirmation: true)
        try await waitUntil { show.filmstrip.count == 3 }
        let old = "visit:" + stops[0].id
        show.chooseJourneys(["middle", old])
        try await waitUntil { show.filmstrip.count == 2 }
        #expect(show.availableJourneys.count == 3)
        #expect(show.journeys.map(\.id) == ["middle", old])
        #expect(show.filmstrip.map(\.id) == [source[1].id, source[0].id])
        show.chooseJourneys([])
        #expect(show.selectedJourneyIDs == ["middle", old])
        show.chooseJourneys(nil)
        try await waitUntil { show.filmstrip.count == 3 }
        show.chooseJourneys([old, "middle"])
        show.beginPlayback()
        try await waitUntil { show.phase == .presentingItem }
        #expect(show.currentItem?.id == source[1].id)
        show.skipToNextJourney()
        try await waitUntil { show.currentItem?.id == source[0].id }
        #expect(!show.canSkipToNextJourney)
        show.restart()
        try await waitUntil { show.phase == .presentingItem }
        #expect(show.currentItem?.id == source[1].id && show.journeyCount == 2)
        show.removeAssets([source[0].id, source[1].id])
        show.restart()
        try await waitUntil { if case .failed = show.phase { return true }; return false }
        #expect(show.currentItem == nil)
        show.chooseJourneys(["new"])
        try await waitUntil { show.currentItem?.id == source[2].id }
        #expect(show.awaitsPlaybackConfirmation && show.journeyCount == 1)
    }

    @Test func repeatVisitsToTheSameCityUseDatesAndSeparateJourneysWithoutFlyingAgain() async throws {
        var stops = (0..<3).map { visit($0, photoCount: 1) }
        for index in stops.indices { stops[index].offlinePlaceID = "tokyo" }
        let source = stops.indices.map { record(0, visit: $0, date: stops[$0].startDate) }
        let journeys = [journey("older", [stops[0]]), journey("newer", Array(stops[1...]))]
        var cameraMoves = 0
        let show = EarthSlideshowCoordinator(scope: .init(id: "country", title: "Japan", kind: .country),
            places: stops, configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            makeSnapshot: { try frozen(source, journeys: journeys) },
            cameraAction: { _, _ in cameraMoves += 1 })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count == 3 }
        #expect(show.currentItem?.id == source[1].id && cameraMoves == 1)
        show.move(forward: true)
        #expect(show.currentItem?.id == source[2].id)
        #expect(show.phase == .transitioningItem)
        show.move(forward: true)
        #expect(show.currentItem?.id == source[0].id && show.currentJourneyNumber == 2)
        #expect(show.phase == .chapterTitle && cameraMoves == 1)
    }

    @Test func collageUsesFullImageAreaAndKeepsTheLargerPairWhenItFitsBetter() {
        let skinny: CGFloat = 9.0 / 16
        let landscape: CGFloat = 4.0 / 3
        let cases: [([CGFloat], Int)] = [
            ([0.75, 0.75, 0.75], 2), ([skinny, skinny, skinny], 3),
            ([0.75, landscape], 2), ([landscape, 0.75], 2), ([1 / skinny, 0.75], 1),
            ([1, 0.75], 1), ([0.75, 0], 1), ([skinny, skinny], 1), ([1.5, 1.5], 1)
        ]
        for (ratios, expected) in cases {
            #expect(SlideshowCollageLayout.count(for: ratios) == expected)
        }
        let sizes = SlideshowCollageLayout.sizes(for: [0.75, 4/3], in: CGSize(width: 1920, height: 1080))
        #expect(sizes[0].height == sizes[1].height)
        #expect(abs(sizes[0].width / sizes[0].height - 0.75) < 0.00001)
        #expect(abs(sizes[0].width + sizes[1].width + 6 - 1920) < 0.00001)
    }

    @Test func collageCountsVisibleMembersAndResumesFromTheInspectedPhoto() async throws {
        let photos = (0..<3).map { record($0, visit: 0, pixelWidth: 900, pixelHeight: 1600) }
            + [record(3, visit: 0, mediaKind: .livePhoto)]
        var config = quickChapters
        config.stillDuration = 0.04
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "", kind: .library),
            places: [visit(0, photoCount: 4)], configuration: config, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            imageScheduler: SharedPhotoImageScheduler(requester: CollageTestRequester()),
            makeSnapshot: { try frozen(photos) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.collageTiles.count == 3 }
        let ids = photos.prefix(3).map(\.id)
        #expect(show.viewedCount == 0)
        show.markCurrentItemReady(ids[0])
        #expect(show.viewedCount == 0)
        show.markCollageDisplayed(ids)
        #expect(show.viewedCount == 3 && show.nextItemForPrefetch?.record == photos[3])
        show.setPaused(true)
        show.move(forward: true)
        #expect(show.currentItem?.record == photos[3] && show.collageTiles.isEmpty)
        show.move(forward: false)
        #expect(show.collageTiles.map(\.id) == ids)
        show.selectPausedItem(ids[1])
        #expect(show.isPaused && show.collageTiles.isEmpty && show.currentItem?.id == ids[1])
        show.markCurrentItemReady(ids[1])
        show.setPaused(false)
        try await waitUntil { show.currentItem?.id == ids[2] }
    }

    @Test func slowTileFallsBackWithoutLosingItsPlaceOrRevivingAWithdrawnPhoto() async throws {
        let photos = (0..<3).map { record($0, visit: 0, pixelWidth: 750, pixelHeight: 1000) }
        let requester = CollageTestRequester()
        requester.delayedID = photos[1].id
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "", kind: .library),
            places: [visit(0, photoCount: 3)], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            imageScheduler: SharedPhotoImageScheduler(requester: requester),
            makeSnapshot: { try frozen(photos) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && !show.preparingCollage }
        #expect(show.collageTiles.isEmpty && show.currentItem?.id == photos[0].id)
        #expect(show.singlePreview?.id == photos[0].id)
        show.markCurrentItemReady(photos[0].id)
        #expect(show.viewedCount == 1)
        show.move(forward: true)
        #expect(show.currentItem?.id == photos[1].id)
        show.removeAssets([photos[1].id])
        requester.deliverDelayed()
        #expect(show.collageTiles.isEmpty && show.currentItem?.id == photos[2].id)
        #expect(!show.filmstrip.contains { $0.id == photos[1].id })
        #expect(requester.networkRequests == 0)
    }

    @Test func visibleCollageDropsRevokedMemberAndRejectsStaleDisplay() async throws {
        let photos = (0..<3).map { record($0, visit: 0, pixelWidth: 900, pixelHeight: 1600) }
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "", kind: .library),
            places: [visit(0, photoCount: 3)], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            imageScheduler: SharedPhotoImageScheduler(requester: CollageTestRequester()),
            makeSnapshot: { try frozen(photos) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.collageTiles.count == 3 }
        let ids = show.collageTiles.map(\.id)
        show.setPaused(true)
        show.removeAssets([ids[1]])
        show.markCollageDisplayed(ids)
        #expect(show.viewedCount == 0)
        #expect(show.currentItem?.id == ids[0] && show.collageTiles.isEmpty)
        show.move(forward: true)
        #expect(show.currentItem?.id == ids[2] && show.isPaused)
    }

    @Test func collageStaysWithinTheSameVisitDayAndHalfHour() async throws {
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        let photos = [-60.0, 0, 1801, 1861, 1921].enumerated().map { index, interval in
            record(index, visit: index == 4 ? 1 : 0, date: midnight.addingTimeInterval(interval),
                   mediaKind: index == 3 ? .livePhoto : .photo, pixelWidth: 750, pixelHeight: 1000)
        }
        let show = EarthSlideshowCoordinator(scope: .init(id: "all", title: "", kind: .library),
            places: [visit(0, photoCount: 4), visit(1, photoCount: 1)], configuration: quickChapters, reduceMotion: false,
            analyzer: PhotoSimilarityAnalyzer(thumbnailProvider: NilThumbnailProvider()),
            imageScheduler: SharedPhotoImageScheduler(requester: CollageTestRequester()),
            makeSnapshot: { try frozen(photos) }, cameraAction: { _, _ in })
        defer { show.cancel() }
        show.start()
        try await waitUntil { show.phase == .presentingItem && show.filmstrip.count == photos.count }
        show.setPaused(true)
        for _ in photos {
            #expect(show.collageTiles.isEmpty)
            show.move(forward: true)
        }
    }

    private var quickChapters: EarthSlideshowConfiguration {
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.02
        config.earthBridgeDuration = 0.02
        config.chapterTitleDuration = 0.02
        return config
    }

    private func journey(_ id: String, _ visits: [TravelPlace]) -> TravelJourney {
        TravelJourney(id: id, title: id, startDate: visits[0].startDate,
                      endDate: visits[visits.count - 1].endDate, placeIDs: visits.map(\.id))
    }

    private func frozen(_ source: [PhotoAssetRecord], journeys: [TravelJourney] = []) throws -> SlideshowSnapshot {
        let snapshot = try SlideshowSnapshot(journeys: journeys)
        try snapshot.append(source)
        return snapshot
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func visit(_ index: Int, photoCount: Int) -> TravelPlace {
        let start = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 1_000_000)
        return TravelPlace(
            id: "visit-\(index)",
            name: "City \(index)",
            country: "Country",
            coordinate: GeoCoordinate(latitude: Double(index), longitude: Double(index)),
            startDate: start,
            endDate: start.addingTimeInterval(5 * 86_400),
            photoCount: photoCount,
            coverAssetID: "asset-\(index)-0"
        )
    }

    private func record(
        _ index: Int,
        visit: Int,
        date: Date? = nil,
        favorite: Bool = false,
        mediaKind: PhotoMediaKind = .photo,
        duration: TimeInterval = 0,
        pixelWidth: Int = 1_920,
        pixelHeight: Int = 1_080
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: "asset-\(visit)-\(index)",
            coordinate: GeoCoordinate(latitude: Double(visit), longitude: Double(visit)),
            creationDate: date ?? self.visit(visit, photoCount: 0).startDate.addingTimeInterval(Double(index) * 60),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isFavorite: favorite,
            mediaKind: mediaKind,
            duration: duration,
            placeID: "visit-\(visit)"
        )
    }

    private func snapshot(
        places: [TravelPlace],
        records: [PhotoAssetRecord],
        journeys: [TravelJourney] = []
    ) -> TravelIndexSnapshot {
        TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourcePhotoCount: records.count,
                locatedPhotoCount: records.count,
                places: places,
                journeys: journeys
            ),
            photos: records
        )
    }
}

@MainActor
private final class MappedThumbnailProvider: SlideshowThumbnailProviding {
    let images: [String: UIImage]
    init(images: [String: UIImage]) { self.images = images }
    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? { images[record.id] }
}

@MainActor
private final class FixedThumbnailProvider: SlideshowThumbnailProviding {
    let image: UIImage
    init(image: UIImage) { self.image = image }
    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? { image }
}

@MainActor
final class NilThumbnailProvider: SlideshowThumbnailProviding {
    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? { nil }
}

@MainActor
private final class BlockingAfterSixThumbnailProvider: SlideshowThumbnailProviding {
    private(set) var requestCount = 0

    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? {
        requestCount += 1
        if requestCount > 6 {
            try? await Task.sleep(for: .seconds(5))
        }
        return nil
    }
}


@MainActor
private final class DelayedOpeningThumbnailProvider: SlideshowThumbnailProviding {
    private let delay: Duration
    private var waiting = 0
    private(set) var peakWaiting = 0

    init(delay: Duration = .milliseconds(80)) { self.delay = delay }

    func image(for record: PhotoAssetRecord, longEdge: Int) async -> UIImage? {
        waiting += 1
        peakWaiting = max(peakWaiting, waiting)
        defer { waiting -= 1 }
        try? await Task.sleep(for: delay)
        return nil
    }
}

@MainActor private final class CollageTestRequester: SharedPhotoImageRequesting {
    var delayedID: String?
    var networkRequests = 0
    private var delayed: [@MainActor @Sendable (OverviewImageDelivery) -> Void] = []
    private let tile = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

    func request(_ key: SharedPhotoImageKey, network: Bool, token: UUID,
                 completion: @escaping @MainActor @Sendable (OverviewImageDelivery) -> Void) {
        if network { networkRequests += 1 }
        if key.assetID == delayedID { delayed.append(completion) }
        else { completion(.init(image: tile)) }
    }

    func deliverDelayed() {
        for completion in delayed { completion(.init(image: tile)) }
        delayed.removeAll()
    }
    func cancel(_ token: UUID) {}
    func invalidate(_ ids: Set<String>?) {}
}
