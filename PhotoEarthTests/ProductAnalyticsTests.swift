import Foundation
import QuartzCore
import XCTest
@testable import PhotoEarth

@MainActor final class ProductAnalyticsTests: XCTestCase {
    private let suiteName = UUID().uuidString
    private let worker = DispatchQueue(label: "PhotoEarth.tests.analytics")
    private var token: String { "phc_" + suiteName.replacingOccurrences(of: "-", with: "") }

    private func makeAnalytics() throws -> ProductAnalytics {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let config = try XCTUnwrap(AnalyticsConfiguration(token: token, host: "https://eu.i.posthog.com"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [OfflineAnalyticsProtocol.self]
        let analytics = ProductAnalytics(configuration: config, defaults: defaults, session: session, serialQueue: worker)
        addTeardownBlock { @MainActor in
            analytics.setEnabled(false)
            await self.drain()
            defaults.removePersistentDomain(forName: self.suiteName)
        }
        return analytics
    }

    private func storageRoot() throws -> URL {
        try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent(XCTUnwrap(Bundle.main.bundleIdentifier)).appendingPathComponent(token)
    }

    func testRejectsInvalidConfigurationAndDisablesSimulatorCollection() {
        XCTAssertNil(AnalyticsConfiguration(token: "phx_personal", host: "https://us.i.posthog.com"))
        XCTAssertNil(AnalyticsConfiguration(token: "phc_../other", host: "https://us.i.posthog.com"))
        XCTAssertNil(AnalyticsConfiguration(token: "phc_valid", host: "https://example.org"))
        #if targetEnvironment(simulator)
        XCTAssertNil(AnalyticsConfiguration.bundled)
        #endif
    }

    func testSDKSubmitsBatchToConfiguredRegion() async throws {
        let analytics = try makeAnalytics()
        let batch = expectation(forNotification: .init("PhotoEarthTestBatch"), object: nil) { note in
            guard let request = note.object as? URLRequest else { return false }
            return request.url?.host == "eu.i.posthog.com" && request.httpMethod == "POST"
        }
        // Five events trigger the pinned SDK's default tvOS batch threshold.
        for _ in 0..<5 { analytics.capture(.sampleOpened) }
        await fulfillment(of: [batch], timeout: 10)
    }

    func testSDKQueueFiltersPropertiesAndWithdrawalErasesIdentityAndEvents() async throws {
        let analytics = try makeAnalytics()
        let root = try storageRoot()
        let queue = root.appendingPathComponent("posthog.queueFolder.uuid")

        func events() throws -> [[String: Any]] {
            try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil).map {
                let data = try Data(contentsOf: $0)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-metadata"))
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
        }

        analytics.capture(.wallOpened, value: "collection", context: .init(library: .sample, entry: .recent))
        analytics.capture(.slideshowStarted, value: "private-metadata")
        await drain()
        let queued = try events()
        XCTAssertEqual(queued.count, 2)
        let wall = try XCTUnwrap(queued.first { $0["event"] as? String == ProductEvent.wallOpened.rawValue })
        let properties = try XCTUnwrap(wall["properties"] as? [String: Any])
        XCTAssertEqual(properties["scope"] as? String, "collection")
        XCTAssertEqual(properties["entry"] as? String, "recent")
        XCTAssertEqual(properties["library_mode"] as? String, "sample")
        XCTAssertEqual(properties["analytics_schema"] as? String, "3")
        XCTAssertEqual(properties["product"] as? String, "photoearth")
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertNil(properties["$device_id"])
        XCTAssertNil(properties["$timezone"])
        let id = try XCTUnwrap(wall["distinct_id"] as? String)
        let slideshow = try XCTUnwrap(queued.first { $0["event"] as? String == ProductEvent.slideshowStarted.rawValue })
        XCTAssertNil((slideshow["properties"] as? [String: Any])?["scope"])

        analytics.setEnabled(false)
        analytics.capture(.sampleOpened)
        await drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let relaunched = try makeAnalytics()
        XCTAssertFalse(relaunched.enabled)
        relaunched.capture(.appOpened)
        await drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        relaunched.setEnabled(true)
        relaunched.capture(.appOpened)
        await drain()
        let after = try events()
        XCTAssertEqual(after.count, 1)
        XCTAssertNotEqual(try XCTUnwrap(after.first?["distinct_id"] as? String), id)
    }

    func testBusyWorkerDoesNotBlockDisplayLinkOrReplayWithdrawnEvents() async throws {
        let analytics = try makeAnalytics()
        let root = try storageRoot()
        let queue = root.appendingPathComponent("posthog.queueFolder.uuid")

        // Simulate a stalled SDK worker. The deadline also releases it if the
        // production path regresses to a synchronous dispatch and blocks the UI.
        let unblock = DispatchSemaphore(value: 0)
        let entered = expectation(description: "background worker stalled")
        let releasedByUI = expectation(description: "display link fired while the worker was stalled")
        worker.async {
            entered.fulfill()
            if unblock.wait(timeout: .now() + 5) == .success { releasedByUI.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 2)
        analytics.capture(.appOpened)
        analytics.setEnabled(false)
        analytics.capture(.sampleOpened)
        analytics.setEnabled(true)
        analytics.capture(.sidebarSelected, value: "recent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let frame = AnalyticsTestFrame { unblock.signal() }
        let displayLink = CADisplayLink(target: frame, selector: #selector(AnalyticsTestFrame.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        defer { displayLink.invalidate() }
        await fulfillment(of: [releasedByUI], timeout: 6)
        await drain()

        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["event"] as? String, ProductEvent.sidebarSelected.rawValue)
    }

    func testStalledWorkerBoundsPendingEvents() async throws {
        let analytics = try makeAnalytics()
        let unblock = DispatchSemaphore(value: 0)
        worker.async { _ = unblock.wait(timeout: .now() + 5) }
        for _ in 0..<256 { analytics.capture(.sampleOpened) }
        unblock.signal()
        await drain()

        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 64)
    }

    func testAllEventsCarryBuildAndLanguageWithoutPrivateFields() {
        let fields = ["entry": "private-metadata", "music_source": "private-metadata", "asset_id": "private-metadata",
                      "origin": "private-metadata", "operation": "private-metadata", "stage": "private-metadata",
                      "choice": "private-metadata", "transaction_id": "private-metadata", "query": "private-metadata",
                      "scope": "private-metadata", "library_mode": "private-metadata", "app_version": "private-metadata"]
        for event in ProductEvent.allCases {
            let properties = event.properties(value: "private-metadata", fields: fields)
            for key in ["app_version", "app_build", "build_channel", "platform", "os_version", "app_language", "system_language"] {
                XCTAssertFalse((properties[key] as? String ?? "").isEmpty, "\(event) missing \(key)")
            }
            XCTAssertFalse(properties.values.contains { $0 as? String == "private-metadata" })
        }
        XCTAssertEqual(ProductEvent.languageTag("fr-CA"), "fr")
        XCTAssertEqual(ProductEvent.languageTag("zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(ProductEvent.languageTag(nil), "unknown")
        XCTAssertEqual(JourneyEventContext.Elapsed(.seconds(59)), .under1m)
        XCTAssertEqual(JourneyEventContext.Elapsed(.seconds(60)), .from1to5m)
        XCTAssertEqual(JourneyEventContext.Elapsed(.seconds(300)), .from5to30m)
        XCTAssertEqual(JourneyEventContext.Elapsed(.seconds(1800)), .atLeast30m)
    }

    func testWallReportsOnlyOneOutcomeEvenAfterManyDetailSelections() async throws {
        let analytics = try makeAnalytics()
        let visit = PhotoWallAnalyticsVisit()
        visit.begin(context: .init(library: .sample, entry: .homeCity, scope: .city), analytics: analytics)
        for _ in 0..<100 { visit.openedDetail() }
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        visit.end(analytics: analytics)
        visit.end(analytics: analytics)
        visit.begin(context: .init(library: .personal, entry: .globe, scope: .currentView), analytics: analytics)
        visit.end(analytics: analytics)
        await drain()
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        let results = try files.map { file in
            let data = try Data(contentsOf: file)
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(event["event"] as? String, ProductEvent.wallBrowsingFinished.rawValue)
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            let result = try XCTUnwrap(properties["result"] as? String)
            XCTAssertEqual(properties["scope"] as? String, result == "viewed_details" ? "city" : "currentView")
            XCTAssertEqual(properties["entry"] as? String, result == "viewed_details" ? "homeCity" : "globe")
            return result
        }
        XCTAssertEqual(results.sorted(), ["viewed_details", "wall_only"])
    }

    private func makeShow(_ analytics: ProductAnalytics) -> EarthSlideshowCoordinator {
        EarthSlideshowCoordinator(scope: .init(id: "private-metadata", title: "private-metadata", kind: .library),
                                 places: [], analyticsLibrary: .sample, analytics: analytics, reduceMotion: true,
                                 makeSnapshot: { throw EarthSlideshowPlanError.unavailable }, cameraAction: { _, _ in })
    }

    func testOneSlideshowAttemptAcrossPickerRetryAndRepeatedClose() async throws {
        let analytics = try makeAnalytics()
        let show = makeShow(analytics)
        show.start(waitingForConfirmation: true)
        show.openedMusicPicker()
        show.openedMusicPicker()
        show.retry()
        show.cancel()
        show.cancel()
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        let queued = try files.map { file in
            let data = try Data(contentsOf: file)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-metadata"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(queued.compactMap { $0["event"] as? String }.sorted(),
                       [ProductEvent.slideshowRequested, .musicPickerOpened, .slideshowFinished].map(\.rawValue).sorted())
        let end = try XCTUnwrap(queued.first { $0["event"] as? String == ProductEvent.slideshowFinished.rawValue })
        let properties = try XCTUnwrap(end["properties"] as? [String: Any])
        XCTAssertEqual(properties["result"] as? String, "closed_before_start")
        XCTAssertEqual(properties["elapsed_bucket"] as? String, "under1m")
        XCTAssertEqual(properties["library_mode"] as? String, "sample")
        XCTAssertEqual(properties["scope"] as? String, "library")
    }

    func testPlaybackPickerAndControlsReachSDKWithBoundedValues() async throws {
        let analytics = try makeAnalytics()
        let show = makeShow(analytics)
        show.start(waitingForConfirmation: true)
        show.beginPlayback(music: .online)
        show.openedMusicPicker()
        show.openedMusicPicker()
        for _ in 0..<20 { show.recordAction(.musicTransport) }
        show.finishedMusicPicker(selection: .appleMusic, choice: .appleMusic)
        show.finishedMusicPicker(selection: nil)
        show.cancel()
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        let events = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        func props(_ event: ProductEvent) -> [[String: Any]] {
            events.filter { $0["event"] as? String == event.rawValue }.compactMap { $0["properties"] as? [String: Any] }
        }
        XCTAssertEqual(props(.musicPickerOpened).count, 1)
        XCTAssertEqual(props(.musicPickerOpened).first?["stage"] as? String, "playback")
        XCTAssertEqual(props(.slideshowAction).compactMap { $0["action"] as? String }, ["musicTransport"])
        XCTAssertEqual(props(.musicPickerResult).compactMap { $0["result"] as? String }.sorted(), ["cancelled", "confirmed"])
        let committed = try XCTUnwrap(props(.musicPickerResult).first { $0["result"] as? String == "confirmed" })
        XCTAssertEqual(committed["choice"] as? String, "appleMusic")
        XCTAssertEqual(committed["scope"] as? String, "library")
        XCTAssertEqual(props(.slideshowFinished).first?["music_source"] as? String, "appleMusic")
        XCTAssertTrue(props(.slideshowContentReady).isEmpty)
    }

    func testWallScopeFollowsTheRouteEvenWhenACityHasOnlyOneVisit() throws {
        let place = try XCTUnwrap(SampleTravelIndex.make().index.places.first)
        let city = PlaceCollection.city(containing: place, in: [place])
        for entry: JourneyEventContext.Entry in [.homeCity, .photoGlobe, .countries, .topShelf] {
            XCTAssertEqual(entry.wallScope(for: city), .city)
            XCTAssertEqual(entry.wallScope(for: nil), .currentView)
        }
        let visit = try XCTUnwrap(PlaceCollection.recent([place]).first)
        XCTAssertEqual(JourneyEventContext.Entry.recent.wallScope(for: visit), .recentVisit)
        let country = try XCTUnwrap(PlaceCollection.countries([place]).first)
        XCTAssertEqual(JourneyEventContext.Entry.countries.wallScope(for: country), .country)
    }

    func testReadyMediaReportsOneContentMilestoneForTheShow() async throws {
        let analytics = try makeAnalytics()
        let sample = SampleTravelIndex.make()
        let photo = try XCTUnwrap(sample.photos.first)
        let place = try XCTUnwrap(sample.index.places.first { $0.id == photo.placeID })
        let snapshot = try SlideshowSnapshot(places: [place], journeys: [])
        try snapshot.append([photo])
        var config = EarthSlideshowConfiguration.standard
        config.earthIntroDuration = 0.02
        config.chapterTitleDuration = 0.02
        let show = EarthSlideshowCoordinator(scope: .init(id: "private-metadata", title: "", kind: .city),
                                             places: [place], analyticsLibrary: .sample, analytics: analytics,
                                             configuration: config, reduceMotion: false,
                                             makeSnapshot: { snapshot }, cameraAction: { _, _ in })
        show.start()
        defer { show.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while show.phase != .presentingItem && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(show.phase, .presentingItem)
        for _ in 0..<3 { show.markCurrentItemReady(photo.id) }
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        let milestones = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
            .compactMap { url -> [String: Any]? in
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                guard event["event"] as? String == ProductEvent.slideshowContentReady.rawValue else { return nil }
                return event["properties"] as? [String: Any]
            }
        XCTAssertEqual(milestones.count, 1)
        XCTAssertEqual(milestones.first?["scope"] as? String, "city")
        XCTAssertNil(milestones.first?["asset_id"])
    }

    func testStoreAndScanFieldsStayOnTheCorrespondingEvents() {
        let context = JourneyEventContext(offerOrigin: .anniversary, operation: .trial)
        let result = ProductEvent.storeResult.properties(value: "completed", fields: context.properties)
        XCTAssertEqual(result["origin"] as? String, "anniversary")
        XCTAssertEqual(result["operation"] as? String, "trial")
        XCTAssertEqual(result["result"] as? String, "completed")
        let scan = ProductEvent.scopeEditFinished.properties(value: "saved", fields: ["origin": "emptyLibrary"])
        XCTAssertEqual(scan["origin"] as? String, "emptyLibrary")
        let other = ProductEvent.anniversaryAction.properties(value: "expand_year", fields: context.properties)
        XCTAssertNil(other["origin"])
        XCTAssertNil(other["operation"])
        XCTAssertEqual(other["action"] as? String, "expand_year")
    }

    func testReenabledAnalyticsDoesNotReportPreviousShow() async throws {
        let analytics = try makeAnalytics()
        let show = makeShow(analytics)
        show.start(waitingForConfirmation: true)
        analytics.setEnabled(false)
        analytics.setEnabled(true)
        show.openedMusicPicker()
        show.recordAction(.journeyPicker)
        show.musicAvailability(.appleMusic, "ready")
        show.finishedMusicPicker(selection: .online, choice: .recommended)
        show.cancel()
        analytics.capture(.foregrounded)
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["event"] as? String, ProductEvent.foregrounded.rawValue)
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume() }
        }
    }
}

@MainActor private final class AnalyticsTestFrame: NSObject {
    let onFrame: () -> Void
    init(onFrame: @escaping () -> Void) { self.onFrame = onFrame }

    @objc func tick(_ link: CADisplayLink) {
        link.invalidate()
        onFrame()
    }
}

private final class OfflineAnalyticsProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/batch" {
            NotificationCenter.default.post(name: .init("PhotoEarthTestBatch"), object: request)
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
