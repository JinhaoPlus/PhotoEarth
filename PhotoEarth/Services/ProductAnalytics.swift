import Combine
import Foundation
import PostHog
import os

nonisolated struct AnalyticsConfiguration {
    let token: String
    let host: String

    init?(token: String, host: String) {
        guard token.hasPrefix("phc_"), token.count > 8,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              ["https://us.i.posthog.com", "https://eu.i.posthog.com"].contains(host) else { return nil }
        self.token = token
        self.host = host
    }

    static var bundled: Self? {
        #if DEBUG || targetEnvironment(simulator)
        return nil
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              let token = Bundle.main.object(forInfoDictionaryKey: "PostHogProjectToken") as? String,
              let host = Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String else { return nil }
        return Self(token: token, host: host)
        #endif
    }
}

nonisolated struct JourneyEventContext: Sendable {
    enum Library: String, Sendable { case sample, personal, publicGlobe }
    enum Entry: String, Sendable { case home, homeCity, recent, countries, topShelf, photoGlobe, globe, mapReview }
    enum Music: String, Sendable { case none, online, appleMusic }
    enum Elapsed: String, Sendable {
        case under1m, from1to5m, from5to30m, atLeast30m

        init(_ duration: Duration) {
            switch duration {
            case ..<(.seconds(60)): self = .under1m
            case ..<(.seconds(300)): self = .from1to5m
            case ..<(.seconds(1800)): self = .from5to30m
            default: self = .atLeast30m
            }
        }
    }
    var library: Library?
    var entry: Entry?
    var scope: EarthSlideshowScope.Kind?
    var music: Music?
    var elapsed: Elapsed?

    var properties: [String: String] {
        ["library_mode": library?.rawValue, "entry": entry?.rawValue, "scope": scope?.rawValue,
         "music_source": music?.rawValue, "elapsed_bucket": elapsed?.rawValue].compactMapValues { $0 }
    }
}

nonisolated enum ProductEvent: String, CaseIterable {
    case appOpened = "photoearth_app_opened"
    case sampleOpened = "photoearth_sample_opened"
    case photoAccessResult = "photoearth_photo_access_result"
    case firstScanRequested = "photoearth_first_scan_requested"
    case firstIndexReady = "photoearth_first_index_ready"
    case sidebarSelected = "photoearth_sidebar_selected"
    case wallOpened = "photoearth_photo_wall_opened"
    case wallBrowsingFinished = "photoearth_wall_browsing_finished"
    case slideshowRequested = "photoearth_slideshow_requested"
    case slideshowStarted = "photoearth_slideshow_started"

    case foregrounded = "photoearth_foregrounded"
    case welcomePresented = "photoearth_welcome_presented"
    case accessRequested = "photoearth_photo_access_requested"
    case scopePresented = "photoearth_scan_scope_presented"
    case scopeDismissed = "photoearth_scan_scope_dismissed"
    case preparationAction = "photoearth_preparation_action"
    case preparationFailed = "photoearth_preparation_failed"
    case homePresented = "photoearth_home_presented"
    case topShelfOpened = "photoearth_top_shelf_opened"
    case globeExplored = "photoearth_globe_explored"
    case mapReviewOpened = "photoearth_map_review_opened"
    case musicPickerOpened = "photoearth_music_picker_opened"
    case slideshowFinished = "photoearth_slideshow_finished"
    case settingsChanged = "photoearth_settings_changed"

    static func languageTag(_ identifier: String?) -> String {
        guard let identifier else { return "unknown" }
        let language = Locale(identifier: identifier).language
        guard let code = language.languageCode?.identifier.lowercased(), (2...3).contains(code.utf8.count),
              code.utf8.allSatisfy({ (97...122).contains($0) }) else { return "unknown" }
        if code == "zh" { return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
        return code
    }

    private static let buildProperties: [String: String] = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var properties = ["platform": "tvOS", "os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                          "system_language": languageTag(Locale.preferredLanguages.first),
                          "app_language": AppLocalization.localeIdentifier, "analytics_schema": "2"]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            properties["app_version"] = version
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            properties["app_build"] = build
        }
        #if DEBUG || targetEnvironment(simulator)
        properties["build_channel"] = "development"
        #else
        switch Bundle.main.appStoreReceiptURL?.lastPathComponent {
        case "sandboxReceipt": properties["build_channel"] = "testflight"
        case "receipt": properties["build_channel"] = "release"
        default: properties["build_channel"] = "unknown"
        }
        #endif
        return properties
    }()

    // Runs after SDK enrichment. Only the listed property and values can leave the app.
    func properties(value: String?, fields: [String: Any] = [:]) -> [String: Any] {
        var properties: [String: Any] = Self.buildProperties
        properties["product"] = "photoearth"
        properties["$geoip_disable"] = true
        properties["$process_person_profile"] = false
        if let mode = fields["library_mode"] as? String, JourneyEventContext.Library(rawValue: mode) != nil {
            properties["library_mode"] = mode
        }
        if [.wallOpened, .globeExplored].contains(self), let entry = fields["entry"] as? String,
           JourneyEventContext.Entry(rawValue: entry) != nil { properties["entry"] = entry }
        if self == .slideshowFinished, let scope = fields["scope"] as? String,
           EarthSlideshowScope.Kind(rawValue: scope) != nil { properties["scope"] = scope }
        if [.slideshowStarted, .slideshowFinished].contains(self), let music = fields["music_source"] as? String,
           JourneyEventContext.Music(rawValue: music) != nil { properties["music_source"] = music }
        if self == .slideshowFinished, let elapsed = fields["elapsed_bucket"] as? String,
           JourneyEventContext.Elapsed(rawValue: elapsed) != nil { properties["elapsed_bucket"] = elapsed }
        guard let value else { return properties }
        switch self {
        case .photoAccessResult where ["granted", "denied", "undetermined"].contains(value),
             .firstIndexReady where ["ready", "empty"].contains(value):
            properties["result"] = value
        case .sidebarSelected where ["home", "recent", "countries", "anniversary", "settings"].contains(value):
            properties["screen"] = value
        case .wallOpened where ["collection", "currentView"].contains(value),
             .slideshowRequested where EarthSlideshowScope.Kind(rawValue: value) != nil,
             .slideshowStarted where EarthSlideshowScope.Kind(rawValue: value) != nil:
            properties["scope"] = value
        case .scopePresented where ["initial", "settings"].contains(value):
            properties["origin"] = value
        case .scopeDismissed where ["saved", "dismissed"].contains(value):
            properties["result"] = value
        case .wallBrowsingFinished where ["wall_only", "viewed_details"].contains(value):
            properties["result"] = value
        case .topShelfOpened where ["city", "globe"].contains(value):
            properties["destination"] = value
        case .preparationAction where ["update", "labels", "rebuild", "pause", "resume"].contains(value):
            properties["action"] = value
        case .preparationFailed where LibraryPreparationMode(rawValue: value) != nil:
            properties["mode"] = value
        case .slideshowFinished where ["completed", "closed_before_start", "closed_after_start", "failed", "restarted"].contains(value):
            properties["result"] = value
        case .settingsChanged where ["scan_scope", "transit_filter", "journey_minimum", "top_shelf", "globe_hints", "globe_imagery"].contains(value):
            properties["setting"] = value
        default: break
        }
        return properties
    }
}

/// Shared by the wall's tiles. Only leaving the wall emits a summary.
@MainActor final class PhotoWallAnalyticsVisit {
    private var consent: UInt64?
    private var library: JourneyEventContext.Library?
    private var viewedDetails = false

    func begin(library: JourneyEventContext.Library?, analytics: ProductAnalytics) {
        guard consent == nil, let library, analytics.enabled else { return }
        self.library = library
        consent = analytics.consentRevision
    }

    func openedDetail() { if consent != nil { viewedDetails = true } }

    func end(analytics: ProductAnalytics) {
        if let consent, consent == analytics.consentRevision {
            analytics.capture(.wallBrowsingFinished, value: viewedDetails ? "viewed_details" : "wall_only",
                              context: .init(library: library))
        }
        consent = nil
        library = nil
        viewedDetails = false
    }
}

@MainActor final class ProductAnalytics: ObservableObject {
    static let shared = ProductAnalytics(configuration: .bundled)
    private let preference = "photoEarth.analytics.enabled"
    private let defaults: UserDefaults
    private let worker: PostHogWorker?
    private(set) var consentRevision: UInt64 = 0
    @Published private(set) var enabled: Bool

    init(configuration: AnalyticsConfiguration?, defaults: UserDefaults = .standard,
         session: URLSessionConfiguration? = nil, serialQueue: DispatchQueue? = nil) {
        self.defaults = defaults
        enabled = defaults.object(forKey: preference) as? Bool ?? true
        worker = configuration.map {
            PostHogWorker(configuration: $0, defaults: defaults, session: session, serialQueue: serialQueue)
        }
        if let worker, !enabled || defaults.bool(forKey: PostHogWorker.purgePending) { worker.withdraw() }
    }

    var isConfigured: Bool { worker != nil }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        consentRevision &+= 1
        defaults.set(enabled, forKey: preference)
        if !enabled { worker?.withdraw() }
        self.enabled = enabled
    }

    func capture(_ event: ProductEvent, value: String? = nil, context: JourneyEventContext = .init()) {
        guard enabled else { return }
        worker?.enqueue(event, value: value, context: context)
    }
}

// The serial queue owns the SDK. Only the small admission counters cross queues.
private nonisolated final class PostHogWorker: @unchecked Sendable {
    static let purgePending = "photoEarth.analytics.purgePending"
    private static let maxPendingEvents = 64

    private struct Admission {
        var generation: UInt64 = 0
        var pending = 0
    }
    private let admission = OSAllocatedUnfairLock(initialState: Admission())
    private let queue: DispatchQueue
    private let configuration: AnalyticsConfiguration
    private let defaults: UserDefaults
    private let session: URLSessionConfiguration?
    private var sdk: PostHogSDK?

    init(configuration: AnalyticsConfiguration, defaults: UserDefaults,
         session: URLSessionConfiguration?, serialQueue: DispatchQueue?) {
        self.configuration = configuration
        self.defaults = defaults
        self.session = session
        queue = serialQueue ?? DispatchQueue(label: "PhotoEarth.PostHog", qos: .utility)
    }

    func enqueue(_ event: ProductEvent, value: String?, context: JourneyEventContext) {
        let generation = admission.withLock { state -> UInt64? in
            guard state.pending < Self.maxPendingEvents else { return nil }
            state.pending += 1
            return state.generation
        }
        guard let generation else { return }
        queue.async {
            defer { self.admission.withLock { $0.pending -= 1 } }
            guard self.admission.withLock({ $0.generation == generation }) else { return }
            self.capture(event, value: value, context: context, generation: generation)
        }
    }

    func withdraw() {
        admission.withLock { $0.generation &+= 1 }
        // Persist intent before returning so a relaunch can finish an interrupted purge.
        defaults.set(true, forKey: Self.purgePending)
        queue.async {
            self.sdk?.optOut()
            self.sdk?.close()
            self.sdk = nil
            self.purge()
        }
    }

    private func capture(_ event: ProductEvent, value: String?, context: JourneyEventContext, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        if sdk == nil {
            if defaults.bool(forKey: Self.purgePending) {
                purge()
                guard !defaults.bool(forKey: Self.purgePending) else { return }
            }
            let config = PostHogConfig(projectToken: configuration.token, host: configuration.host)
            config.captureApplicationLifecycleEvents = false
            config.captureScreenViews = false
            config.enableSwizzling = false
            config.preloadFeatureFlags = false
            config.sendFeatureFlagEvent = false
            config.errorTrackingConfig.autoCapture = false
            config.errorTrackingConfig.exceptionSteps.enabled = false
            config.personProfiles = .never
            config.setDefaultPersonProperties = false
            config.maxQueueSize = 200
            config.urlSessionConfiguration = session ?? .ephemeral
            config.setBeforeSend { [admission] event in
                guard admission.withLock({ $0.generation == generation }),
                      let knownEvent = ProductEvent(rawValue: event.event) else { return nil }
                event.properties = knownEvent.properties(value: event.properties["event_value"] as? String, fields: event.properties)
                return event
            }
            sdk = PostHogSDK.with(config)
        }
        var properties = context.properties
        properties["event_value"] = value
        sdk?.capture(event.rawValue, properties: properties)
    }

    private func purge() {
        // posthog-ios 3.79 keeps the tvOS queue under Library/Caches even after close().
        guard let bundle = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent(bundle).appendingPathComponent(configuration.token)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // An installation that never collected has no queue.
        } catch {
            defaults.set(true, forKey: Self.purgePending)
            return
        }
        defaults.removeObject(forKey: Self.purgePending)
    }
}
