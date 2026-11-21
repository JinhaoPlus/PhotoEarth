import Foundation

/// Only a successful, current read can commit a cursor. A failed visit stays
/// retryable after all other visits have had a turn.
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
    private var pending: [Request]
    private var head = 0
    private var failed: [Request] = []
    private(set) var state: State

    init(places: [TravelPlace]) {
        let sorted = places.filter { $0.photoCount > 0 }.sorted(by: SlideshowOrdering.visitComesFirst)
        // Alternate years, then distribute separate visits to the same
        // catalog city across rounds so a home city cannot own the opening.
        var groups: [String: [TravelPlace]] = [:]
        var cities: [String] = []
        for index in sorted.indices {
            let place = sorted[index.isMultiple(of: 2) ? sorted.count - 1 - index / 2 : index / 2]
            let city = place.offlinePlaceID ?? place.id
            if groups[city] == nil { cities.append(city) }
            groups[city, default: []].append(place)
        }
        pending = []
        var pass = 0
        while !cities.isEmpty {
            var next: [String] = []
            for city in cities {
                guard let visits = groups[city] else { continue }
                pending.append(Request(visit: visits[pass]))
                if visits.count > pass + 1 { next.append(city) }
            }
            cities = next
            pass += 1
        }
        state = pending.isEmpty ? .exhausted : .ready
    }

    mutating func begin() -> Request? {
        guard state == .ready else { return nil }
        let request = pending[head]
        head += 1
        if head >= 64 && head * 2 >= pending.count {
            pending.removeFirst(head)
            head = 0
        }
        state = .reading(request)
        return request
    }

    mutating func finish(_ request: Request, next: Cursor?) {
        guard state == .reading(request) else { return }
        if let next {
            guard request.after.map({ ($0.date, $0.id) < (next.date, next.id) }) ?? true else {
                fail(request)
                return
            }
            pending.append(Request(visit: request.visit, after: next))
        }
        settle()
    }

    mutating func fail(_ request: Request) {
        guard state == .reading(request) else { return }
        if request.attempt == 0 {
            var delayed = request
            delayed.attempt = 1
            pending.append(delayed)
        } else {
            failed.append(request)
        }
        settle()
    }

    mutating func interrupt() {
        guard case .reading(let request) = state else { return }
        pending.insert(request, at: head)
        settle()
    }

    mutating func retry() {
        guard state == .retryable else { return }
        pending.append(contentsOf: failed.map { Request(visit: $0.visit, after: $0.after) })
        failed.removeAll()
        settle()
    }

    private mutating func settle() {
        state = head < pending.count ? .ready : (failed.isEmpty ? .exhausted : .retryable)
    }
}
