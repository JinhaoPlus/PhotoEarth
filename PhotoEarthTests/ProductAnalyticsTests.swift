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
        XCTAssertEqual(properties["analytics_schema"] as? String, "2")
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
        visit.begin(library: .sample, analytics: analytics)
        for _ in 0..<100 { visit.openedDetail() }
        await drain()
        let queue = try storageRoot().appendingPathComponent("posthog.queueFolder.uuid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        visit.end(analytics: analytics)
        visit.end(analytics: analytics)
        visit.begin(library: .personal, analytics: analytics)
        visit.end(analytics: analytics)
        await drain()
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        let results = try files.map { file in
            let data = try Data(contentsOf: file)
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(event["event"] as? String, ProductEvent.wallBrowsingFinished.rawValue)
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            return try XCTUnwrap(properties["result"] as? String)
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

    func testReenabledAnalyticsDoesNotReportPreviousShow() async throws {
        let analytics = try makeAnalytics()
        let show = makeShow(analytics)
        show.start(waitingForConfirmation: true)
        analytics.setEnabled(false)
        analytics.setEnabled(true)
        show.openedMusicPicker()
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
