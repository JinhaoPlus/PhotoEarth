import Foundation

/// A journey intersected with the source wall. Its dates describe only the
/// stops the viewer can actually see in this show.
nonisolated struct EarthSlideshowSegment: Identifiable, Equatable, Sendable {
    let id: String
    let startDate: Date
    let endDate: Date
    let visits: [TravelPlace]

    init(id: String, visits: [TravelPlace]) {
        precondition(!visits.isEmpty)
        self.id = id
        self.visits = visits.sorted(by: SlideshowOrdering.visitComesFirst)
        startDate = self.visits[0].startDate
        endDate = self.visits.map(\.endDate).max() ?? startDate
    }

    func coverAssetID(excluding excluded: Set<String>) -> String? {
        visits.lazy.compactMap(\.coverAssetID).first { !excluded.contains($0) }
    }

    static func scoped(to places: [TravelPlace], journeys: [TravelJourney]) -> [Self] {
        var remaining = Dictionary(places.filter { $0.photoCount > 0 }.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var scoped: [Self] = []
        for journey in journeys {
            let visits = journey.placeIDs.compactMap { remaining.removeValue(forKey: $0) }
            if !visits.isEmpty {
                scoped.append(.init(id: journey.id, visits: visits))
            }
        }
        // Older indexes can have visits without journey membership.
        for visit in remaining.values {
            scoped.append(.init(id: "visit:" + visit.id, visits: [visit]))
        }
        return scoped.sorted {
            if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate > $1.endDate }
            return $0.id < $1.id
        }
    }
}

/// Read the newest journey first, then finish each stop in capture order.
/// A failed read retains its cursor so retrying cannot reorder the trip.
nonisolated struct SlideshowPageSequence {
    struct Cursor: Hashable, Sendable {
        let date: Date
        let id: String
        init(_ record: PhotoAssetRecord) { date = record.creationDate; id = record.id }
    }
    struct Request: Equatable, Sendable {
        let visit: TravelPlace
        var after: Cursor?
        var attempt = 0
    }
    enum State: Equatable {
        case ready, reading(Request), retryable, exhausted
    }

    let segments: [EarthSlideshowSegment]
    private let segmentByVisit: [String: Int]
    private var segmentIndex = 0
    private var visitIndex = 0
    private var cursor: Cursor?
    private var attempt = 0
    private(set) var state: State

    init(places: [TravelPlace], journeys: [TravelJourney] = []) {
        self.init(segments: EarthSlideshowSegment.scoped(to: places, journeys: journeys))
    }

    init(segments: [EarthSlideshowSegment]) {
        self.segments = segments
        var indexes: [String: Int] = [:]
        for (index, segment) in segments.enumerated() {
            for visit in segment.visits { indexes[visit.id] = index }
        }
        segmentByVisit = indexes
        state = segments.isEmpty ? .exhausted : .ready
    }

    func segmentIndex(forVisitID id: String) -> Int? { segmentByVisit[id] }

    mutating func start(atSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segmentIndex = index
        visitIndex = 0
        cursor = nil
        attempt = 0
        state = .ready
    }

    mutating func begin() -> Request? {
        guard state == .ready else { return nil }
        let request = Request(visit: segments[segmentIndex].visits[visitIndex], after: cursor, attempt: attempt)
        state = .reading(request)
        return request
    }

    mutating func finish(_ request: Request, next: Cursor?) {
        guard state == .reading(request) else { return }
        if let next {
            guard cursor.map({ ($0.date, $0.id) < (next.date, next.id) }) ?? true else {
                fail(request)
                return
            }
        } else {
            visitIndex += 1
            if visitIndex == segments[segmentIndex].visits.count {
                segmentIndex += 1
                visitIndex = 0
            }
        }
        cursor = next
        attempt = 0
        state = segmentIndex < segments.count ? .ready : .exhausted
    }

    mutating func fail(_ request: Request) {
        guard state == .reading(request) else { return }
        if attempt == 0 {
            attempt = 1
            state = .ready
        } else {
            state = .retryable
        }
    }

    mutating func interrupt() {
        if case .reading = state { state = .ready }
    }

    mutating func retry() {
        guard state == .retryable else { return }
        attempt = 0
        state = .ready
    }
}
