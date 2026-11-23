import Foundation
import SQLite3

nonisolated protocol SlideshowPageReading: Sendable {
    var places: [TravelPlace]? { get }
    var journeys: [TravelJourney] { get }
    func visitIDs() -> Set<String>
    func page(_ request: SlideshowPageSequence.Request, limit: Int) async throws -> SlideshowSnapshot.Page
}

nonisolated struct IndexedSlideshowSnapshot: SlideshowPageReading {
    let reader: SQLiteTravelIndexStore
    let journeys: [TravelJourney]
    let places: [TravelPlace]?
    let members: Set<String>
    let excluding: Set<String>

    func visitIDs() -> Set<String> { members }

    func page(_ request: SlideshowPageSequence.Request, limit: Int) async throws -> SlideshowSnapshot.Page {
        guard members.contains(request.visit.id) else { return .init(records: [], next: nil) }
        return try await reader.slideshowPage(request, limit: limit, excluding: excluding)
    }
}

/// Keep reading in capture order from the wall's index version. The frozen
/// native projection, including the far side of the globe, decides visibility.
nonisolated struct ViewportSlideshowSnapshot: SlideshowPageReading {
    let source: any SlideshowPageReading
    let viewport: PhotoViewportSnapshot
    let members: Set<String>
    var places: [TravelPlace]? { source.places }
    var journeys: [TravelJourney] { source.journeys }
    func visitIDs() -> Set<String> { members }

    @MainActor func page(_ request: SlideshowPageSequence.Request, limit: Int) async throws -> SlideshowSnapshot.Page {
        guard members.contains(request.visit.id) else { return .init(records: [], next: nil) }
        let size = max(1, min(limit, 48))
        var read = request
        var visible: [PhotoAssetRecord] = []
        var slice = ContinuousClock.now
        repeat {
            let page = try await source.page(read, limit: 48)
            try Task.checkCancellation()
            guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
            for (index, record) in page.records.enumerated() {
                if slice.duration(to: .now) >= .milliseconds(3) {
                    await Task.yield()
                    try Task.checkCancellation()
                    guard viewport.isCurrent() else { throw PhotoWallSelectionError.changedViewport }
                    slice = .now
                }
                if viewport.containsForPhotoWall(record.coordinate) {
                    visible.append(record)
                    if visible.count == size {
                        let hasMore = index < page.records.count - 1 || page.next != nil
                        return .init(records: visible, next: hasMore ? .init(record) : nil)
                    }
                }
            }
            read.after = page.next
        } while read.after != nil
        return .init(records: visible, next: nil)
    }
}

/// A private temporary SQLite file owned by this show. Closing the handle
/// removes the file. The main index can advance while playback reads it.
nonisolated final class SlideshowSnapshot: SlideshowPageReading, @unchecked Sendable {
    struct Page: Sendable {
        let records: [PhotoAssetRecord]
        let next: SlideshowPageSequence.Cursor?
    }
    let journeys: [TravelJourney]
    let places: [TravelPlace]?
    private let db: OpaquePointer
    private let lock = NSLock()
    private var visits = Set<String>()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(places: [TravelPlace]? = nil, journeys: [TravelJourney] = []) throws {
        self.journeys = journeys
        self.places = places
        var handle: OpaquePointer?
        guard sqlite3_open("", &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw EarthSlideshowPlanError.unavailable
        }
        guard sqlite3_exec(handle, "CREATE TABLE media(visit TEXT, date REAL, id TEXT, payload BLOB, PRIMARY KEY(visit,date,id)) WITHOUT ROWID", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw EarthSlideshowPlanError.unavailable
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    @concurrent func appendBatch(_ records: [PhotoAssetRecord], visitID: String? = nil) async throws {
        try append(records, visitID: visitID)
    }

    func append(_ records: [PhotoAssetRecord], visitID: String? = nil) throws {
        try lock.withLock {
            guard !records.isEmpty else { return }
            let stmt = try statement("INSERT OR IGNORE INTO media VALUES(?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            try execute("BEGIN")
            do {
                var addedVisits = Set<String>()
                let encoder = JSONEncoder()
                for record in records {
                    try Task.checkCancellation()
                    guard let placeID = visitID ?? record.placeID else { continue }
                    addedVisits.insert(placeID)
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, placeID, -1, transient)
                    sqlite3_bind_double(stmt, 2, record.creationDate.timeIntervalSince1970)
                    sqlite3_bind_text(stmt, 3, record.id, -1, transient)
                    let bytes = try encoder.encode(record)
                    _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw EarthSlideshowPlanError.unavailable }
                }
                try execute("COMMIT")
                visits.formUnion(addedVisits)
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func page(_ request: SlideshowPageSequence.Request, limit: Int) throws -> Page {
        try lock.withLock {
            let clause = request.after == nil ? "" : " AND (date,id) > (?,?)"
            let stmt = try statement("SELECT payload FROM media WHERE visit = ?" + clause + " ORDER BY date,id LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, request.visit.id, -1, transient)
            if let cursor = request.after {
                sqlite3_bind_double(stmt, 2, cursor.date.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, cursor.id, -1, transient)
            }
            let size = max(1, min(48, limit))
            sqlite3_bind_int(stmt, sqlite3_bind_parameter_count(stmt), Int32(size + 1))
            var rows: [PhotoAssetRecord] = []
            let decoder = JSONDecoder()
            while true {
                try Task.checkCancellation()
                switch sqlite3_step(stmt) {
                case SQLITE_DONE: return Page(records: rows, next: nil)
                case SQLITE_ROW:
                    if rows.count == size, let last = rows.last {
                        return Page(records: rows, next: .init(last))
                    }
                    guard let bytes = sqlite3_column_blob(stmt, 0) else { throw EarthSlideshowPlanError.unavailable }
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                    rows.append(try decoder.decode(PhotoAssetRecord.self, from: data))
                default: throw EarthSlideshowPlanError.unavailable
                }
            }
        }
    }

    func record(visitID: String, date: Date, id: String) throws -> PhotoAssetRecord {
        try lock.withLock {
            let stmt = try statement("SELECT payload FROM media WHERE visit = ? AND date = ? AND id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, visitID, -1, transient)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else {
                throw EarthSlideshowPlanError.unavailable
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            return try JSONDecoder().decode(PhotoAssetRecord.self, from: data)
        }
    }

    func visitIDs() -> Set<String> { lock.withLock { visits } }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw EarthSlideshowPlanError.unavailable }
        return value
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EarthSlideshowPlanError.unavailable }
    }
}
