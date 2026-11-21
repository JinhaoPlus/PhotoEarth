import Foundation
import OSLog

nonisolated struct PlaceDisplayLabel: Equatable, Sendable {
    let city: String
    let country: String?
    let regionCode: String?
    let source: String?
    let sourceVersion: String?
    let offlinePlaceID: String?

    init(
        city: String,
        country: String?,
        regionCode: String? = nil,
        source: String? = nil,
        sourceVersion: String? = nil,
        offlinePlaceID: String? = nil
    ) {
        self.city = city
        self.country = country
        self.regionCode = regionCode
        self.source = source
        self.sourceVersion = sourceVersion
        self.offlinePlaceID = offlinePlaceID
    }

    var hasCity: Bool {
        let value = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !Self.legacyPlaceholderNames.contains(value) && !value.hasPrefix("地点 ")
    }

    var hasCountry: Bool { !(country ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isComplete: Bool { hasCity && hasCountry }
    var displayCountry: String? {
        let value = (country ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return JourneyRegionNames.name(code: regionCode, fallback: value.isEmpty ? nil : value, locale: AppLocalization.locale)
    }
    var displayCity: String {
        hasCity
            ? city.trimmingCharacters(in: .whitespacesAndNewlines)
            : AppLocalization.unknownPlace(near: displayCountry)
    }
    var compactName: String {
        let name = displayCity
        guard hasCity, let country = displayCountry,
              name.localizedCaseInsensitiveCompare(country) != .orderedSame else { return name }
        return "\(name) · \(country)"
    }
    var displaySubtitle: String {
        hasCity ? (displayCountry ?? AppLocalization.unresolvedPlace) : AppLocalization.unresolvedPlace
    }

    init(place: TravelPlace) {
        self.init(city: place.name, country: place.country, regionCode: place.regionCode, offlinePlaceID: place.offlinePlaceID)
    }

    private static let legacyPlaceholderNames: Set<String> = ["地点", "未知地点", "地名待完善"]
}

nonisolated enum PlaceLabelLoadState: Equatable, Sendable {
    case loading, unavailable
}

nonisolated enum PlaceLabelResolution: Equatable, Sendable {
    case resolved(PlaceDisplayLabel)
    case stableUnavailable(PlaceDisplayLabel?)
    case transientUnavailable(PlaceDisplayLabel?)

    var label: PlaceDisplayLabel? {
        switch self {
        case let .resolved(label): label
        case let .stableUnavailable(label), let .transientUnavailable(label): label
        }
    }

    var shouldRetry: Bool {
        if case .transientUnavailable = self { true } else { false }
    }
}

/// Diagnostic messages contain only fixed event names, counts and error codes.
nonisolated enum PlaceLabelDiagnostics {
    private static let logger = Logger(subsystem: "com.doupi.PhotoEarth.PhotoEarth", category: "PlaceLabels")
    static func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
#if DEBUG
        print("[PlaceLabels] \(message)")
#endif
    }
}

@MainActor
final class PlaceLabelResolver {
    enum Priority { case visible, library }
    typealias Lookup = @MainActor (GeoCoordinate) async throws -> PlaceDisplayLabel?
    private struct Key: Hashable { let coordinate: GeoCoordinate }
    private struct Pending {
        let token: UUID
        let task: Task<PlaceLabelResolution, Never>
        var waiters: Set<UUID>
    }
    private struct Gate {
        let token: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Never>
    }
    private var cache: [Key: PlaceDisplayLabel] = [:]
    private var stableResults: [Key: PlaceLabelResolution] = [:]
    private var inFlight: [Key: Pending] = [:]
    private var gates: [Gate] = []
    private var activeToken: UUID?
    private var visibleStreak = 0
    private var generation = UUID()
    private let lookup: Lookup

    init(locale: Locale = AppLocalization.locale, lookup: Lookup? = nil) {
        let locale = AppLocalization.supportedLocale(for: locale)
        self.lookup = lookup ?? { coordinate in
            try await Self.atlasLabel(coordinate, locale: locale)
        }
    }

    @concurrent private static func atlasLabel(_ coordinate: GeoCoordinate, locale: Locale) async throws -> PlaceDisplayLabel {
        try JourneyPlaceCatalog.shared.label(coordinate, locale: locale)
    }

    /// Subscribers coalesce on the actual coordinate, across views and the
    /// durable library job. Three foreground requests yield to a library request.
    func label(for place: TravelPlace, priority: Priority = .visible) async -> PlaceDisplayLabel? {
        await resolution(for: place, priority: priority).label
    }

    func resolution(for place: TravelPlace, priority: Priority = .visible) async -> PlaceLabelResolution {
        guard !Task.isCancelled else { return .transientUnavailable(nil) }
        let stored = PlaceDisplayLabel(place: place)
        if stored.isComplete { return .resolved(stored) }
        let key = Key(coordinate: place.coordinate)
        if let value = cache[key] { return .resolved(value) }
        if let value = stableResults[key] { return value }
        if var pending = inFlight[key] {
            let waiter = UUID()
            pending.waiters.insert(waiter)
            inFlight[key] = pending
            return await wait(for: pending, key: key, waiter: waiter)
        }
        let currentGeneration = generation
        let token = UUID(), waiter = UUID()
        let task = Task { @MainActor [self] () -> PlaceLabelResolution in
            await withCheckedContinuation { continuation in
                gates.append(Gate(token: token, priority: priority, continuation: continuation))
                pump()
            }
            defer { release(token) }
            guard !Task.isCancelled, generation == currentGeneration else { return .transientUnavailable(nil) }
            let result = await resolve(place.coordinate)
            guard !Task.isCancelled, generation == currentGeneration else { return .transientUnavailable(nil) }
            switch result {
            case let .resolved(label): cache[key] = label
            case .stableUnavailable: stableResults[key] = result
            case .transientUnavailable: break
            }
            return result
        }
        let pending = Pending(token: token, task: task, waiters: [waiter])
        inFlight[key] = pending
        return await wait(for: pending, key: key, waiter: waiter)
    }

    private func pump() {
        guard activeToken == nil, !gates.isEmpty else { return }
        let index: Int
        if visibleStreak >= 3, let library = gates.firstIndex(where: { $0.priority == .library }) { index = library }
        else { index = gates.firstIndex(where: { $0.priority == .visible }) ?? 0 }
        let gate = gates.remove(at: index)
        visibleStreak = gate.priority == .visible ? visibleStreak + 1 : 0
        activeToken = gate.token
        gate.continuation.resume()
    }

    private func release(_ token: UUID) {
        if activeToken == token { activeToken = nil }
        pump()
    }

    private func wait(for pending: Pending, key: Key, waiter: UUID) async -> PlaceLabelResolution {
        let result = await withTaskCancellationHandler {
            await pending.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(waiter, key: key, token: pending.token) }
        }
        removeWaiter(waiter, key: key, token: pending.token)
        return Task.isCancelled ? .transientUnavailable(nil) : result
    }

    private func removeWaiter(_ waiter: UUID, key: Key, token: UUID) {
        guard var pending = inFlight[key], pending.token == token else { return }
        pending.waiters.remove(waiter)
        if pending.waiters.isEmpty {
            pending.task.cancel()
            inFlight[key] = nil
            if let index = gates.firstIndex(where: { $0.token == token }) {
                gates.remove(at: index).continuation.resume()
            }
        } else { inFlight[key] = pending }
    }

    func isResolving(_ place: TravelPlace) -> Bool { inFlight[Key(coordinate: place.coordinate)] != nil }

    func reset() {
        generation = UUID()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight = [:]; cache = [:]; stableResults = [:]
        let pending = gates; gates = []
        pending.forEach { $0.continuation.resume() }
    }

    private func resolve(_ coordinate: GeoCoordinate) async -> PlaceLabelResolution {
        guard coordinate.isValid else { return .stableUnavailable(nil) }
        do {
            let label = try await lookup(coordinate)
            guard !Task.isCancelled else { return .transientUnavailable(nil) }
            if let label, label.isComplete { return .resolved(label) }
            return .stableUnavailable(label.flatMap { $0.hasCity || $0.hasCountry ? $0 : nil })
        } catch {
            return .transientUnavailable(nil)
        }
    }
}
