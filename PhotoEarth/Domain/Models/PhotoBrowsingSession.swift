import Foundation

/// Position metadata for one frozen wall. Appended pages keep their database
/// order; a queued right press crosses a page boundary exactly once.
nonisolated struct PhotoBrowsingSession {
    enum Move: Equatable { case photo(String), loadMore, boundary }

    private(set) var orderedIDs: [String] = []
    private(set) var positions: [String: Int] = [:]
    private(set) var currentID: String?
    private(set) var waitsForNextPage = false

    var currentPosition: Int? { currentID.flatMap { positions[$0] } }

    mutating func update(ids: [String], currentID: String) -> String? {
        update(records: ids, id: \.self, currentID: currentID)
    }

    mutating func update<Record>(records: [Record], id keyPath: KeyPath<Record, String>, currentID: String) -> String? {
        let appends = records.count > orderedIDs.count &&
            (orderedIDs.isEmpty ||
             (records.first?[keyPath: keyPath] == orderedIDs.first &&
              records[orderedIDs.count - 1][keyPath: keyPath] == orderedIDs.last))
        if appends {
            // Read IDs only from the new page. Do not remap a 50,000-photo
            // wall just to let its current detail continue one page further.
            appendIDs(records.dropFirst(orderedIDs.count).map { $0[keyPath: keyPath] })
        } else {
            orderedIDs = []
            positions = [:]
            appendIDs(records.map { $0[keyPath: keyPath] })
        }
        self.currentID = currentID
        guard waitsForNextPage, let position = currentPosition,
              orderedIDs.indices.contains(position + 1) else { return nil }
        waitsForNextPage = false
        let next = orderedIDs[position + 1]
        self.currentID = next
        return next
    }

    private mutating func appendIDs(_ ids: [String]) {
        for id in ids where positions[id] == nil {
            positions[id] = orderedIDs.count
            orderedIDs.append(id)
        }
    }

    mutating func move(forward: Bool, hasMore: Bool) -> Move {
        // A reversal cancels an in-flight forward intention before moving.
        waitsForNextPage = false
        guard let position = currentPosition else { return .boundary }
        let next = position + (forward ? 1 : -1)
        if orderedIDs.indices.contains(next) {
            let id = orderedIDs[next]
            currentID = id
            return .photo(id)
        }
        if forward, hasMore {
            waitsForNextPage = true
            return .loadMore
        }
        return .boundary
    }

    mutating func cancelPendingAdvance() { waitsForNextPage = false }

    mutating func select(_ id: String) { currentID = id }

    var neighborIDs: [String] {
        guard let position = currentPosition else { return [] }
        return [position - 1, position + 1].compactMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil }
    }
}
