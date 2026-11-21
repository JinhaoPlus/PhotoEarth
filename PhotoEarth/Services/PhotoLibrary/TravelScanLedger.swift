import Foundation
import SQLite3

/// Evidence and accounting belong to this Photos library. Media bytes are never stored.
actor TravelScanLedger {
    private let url: URL
    private var db: OpaquePointer?
    private var scope = TravelScanScope()
    private var ledgerIdentity = ""
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoEarth/scan-evidence-v3.sqlite")) { self.url = url }

    isolated deinit { sqlite3_close_v2(db) }

    func prepare(_ newScope: TravelScanScope) throws -> (scope: String, revision: Int) {
        scope = newScope
        return try publicationState(for: newScope)
    }

    func publicationState(for selected: TravelScanScope) throws -> (scope: String, revision: Int) {
        try open()
        return (selected.fingerprint + ":" + ledgerIdentity, try scalar("PRAGMA user_version"))
    }

    func counts() throws -> [TravelScanDecision: Int] {
        try open()
        let query = try statement("SELECT decision,COUNT(*) FROM evidence GROUP BY decision")
        defer { sqlite3_finalize(query) }
        var result: [TravelScanDecision: Int] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            if let reason = TravelScanDecision(rawValue: Int(sqlite3_column_int(query, 0))) { result[reason] = Int(sqlite3_column_int(query, 1)) }
        }
        return result
    }

    func filter(_ batch: [ScanAssetMetadata], sweep: String? = nil) throws -> [PhotoAssetRecord] {
        try open()
        let get = try statement("SELECT camera, modified, checked, media, sweep FROM evidence WHERE id=?")
        defer { sqlite3_finalize(get) }
        let put = try statement("""
            INSERT INTO evidence(id, modified, camera, decision, checked, sweep, media) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET modified=excluded.modified,camera=excluded.camera,
            decision=excluded.decision,checked=excluded.checked,media=excluded.media,sweep=COALESCE(excluded.sweep,evidence.sweep)
            """)
        defer { sqlite3_finalize(put) }
        var records: [PhotoAssetRecord] = []
        var seen = Set<String>()
        try transaction {
            for asset in batch {
                try Task.checkCancellation()
                guard seen.insert(asset.id).inserted else { continue }
                let modified = asset.modified?.timeIntervalSinceReferenceDate
                var camera = CameraEvidence.unknown
                var checked = 0.0
                bind(asset.id, to: get, at: 1)
                let getStatus = sqlite3_step(get)
                guard getStatus == SQLITE_DONE || getStatus == SQLITE_ROW else { throw LibraryPreparationError.saveFailed }
                if let sweep, getStatus == SQLITE_ROW, let saved = sqlite3_column_text(get, 4), String(cString: saved) == sweep {
                    sqlite3_reset(get)
                    continue
                }
                let cachedModification: Double? = sqlite3_column_type(get, 1) == SQLITE_NULL ? nil : sqlite3_column_double(get, 1)
                let media = Int32(asset.record?.mediaKind.rawValue ?? -1)
                if getStatus == SQLITE_ROW, cachedModification == modified, sqlite3_column_int(get, 3) == media {
                    camera = CameraEvidence(rawValue: Int(sqlite3_column_int(get, 0))) ?? .unknown
                    checked = sqlite3_column_double(get, 2)
                }
                sqlite3_reset(get)
                let decision = TravelScanDecision.decide(available: asset.available, excluded: scope.members.contains(asset.id),
                    screen: asset.screen, dated: asset.dated, located: asset.located, evidence: camera,
                    excludesMissingCamera: scope.preferences.excludesMissingCamera)
                bind(asset.id, to: put, at: 1)
                if let modified { sqlite3_bind_double(put, 2, modified) } else { sqlite3_bind_null(put, 2) }
                sqlite3_bind_int(put, 3, Int32(camera.rawValue))
                sqlite3_bind_int(put, 4, Int32(decision.rawValue))
                sqlite3_bind_double(put, 5, checked)
                bind(sweep, to: put, at: 6)
                sqlite3_bind_int(put, 7, media)
                try done(put)
                if decision.included, let record = asset.record { records.append(record) }
            }
        }
        return records
    }

    func sourceCount() throws -> Int {
        try open()
        return try scalar("SELECT COUNT(*) FROM evidence")
    }

    func finishSweep(_ sweep: String) throws {
        let query = try statement("DELETE FROM evidence WHERE sweep IS NULL OR sweep != ?")
        defer { sqlite3_finalize(query) }; bind(sweep, to: query, at: 1); try done(query)
    }

    func remove(_ ids: [String]) throws {
        try open()
        let query = try statement("DELETE FROM evidence WHERE id=?")
        defer { sqlite3_finalize(query) }
        try transaction { for id in ids { bind(id, to: query, at: 1); try done(query) } }
    }

    struct Pending: Sendable { let id: String; let modified: Double?; let media: Int32 }

    func pending() throws -> [Pending] {
        try open()
        let query = try statement("""
            SELECT id, modified, media FROM evidence WHERE decision=? AND checked<? ORDER BY checked,id LIMIT 32
            """)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int(query, 1, Int32(TravelScanDecision.pendingCamera.rawValue))
        sqlite3_bind_double(query, 2, Date().addingTimeInterval(-86400).timeIntervalSince1970)
        var result: [Pending] = []
        while sqlite3_step(query) == SQLITE_ROW {
            result.append(Pending(id: String(cString: sqlite3_column_text(query, 0)), modified: sqlite3_column_type(query, 1) == SQLITE_NULL ? nil : sqlite3_column_double(query, 1), media: sqlite3_column_int(query, 2)))
        }
        return result
    }

    func record(_ evidence: CameraEvidence, for item: Pending) throws -> Bool {
        try Task.checkCancellation()
        let evidence = item.modified == nil ? CameraEvidence.unknown : evidence
        let decision = TravelScanDecision.decide(available: true, excluded: false, screen: false, dated: true, located: true,
                                                  evidence: evidence, excludesMissingCamera: scope.preferences.excludesMissingCamera)
        let query = try statement("UPDATE evidence SET camera=?, decision=?,checked=? WHERE id=? AND modified IS ? AND decision=? AND media=?")
        defer { sqlite3_finalize(query) }
        var removed = false
        try transaction {
            sqlite3_bind_int(query, 1, Int32(evidence.rawValue))
            sqlite3_bind_int(query, 2, Int32(decision.rawValue))
            sqlite3_bind_double(query, 3, Date().timeIntervalSince1970)
            bind(item.id, to: query, at: 4)
            if let modified = item.modified { sqlite3_bind_double(query, 5, modified) } else { sqlite3_bind_null(query, 5) }
            sqlite3_bind_int(query, 6, Int32(TravelScanDecision.pendingCamera.rawValue))
            sqlite3_bind_int(query, 7, item.media)
            try done(query)
            removed = sqlite3_changes(db) > 0 && !decision.included
            if removed {
                let revision = try scalar("PRAGMA user_version") + 1
                let update = try statement("UPDATE evidence SET excluded_revision=? WHERE id=?")
                defer { sqlite3_finalize(update) }
                sqlite3_bind_int64(update, 1, Int64(revision))
                bind(item.id, to: update, at: 2)
                try done(update)
                try exec("PRAGMA user_version = \(revision)")
            }
        }
        return removed
    }

    func removals(after revision: Int, startingAfter id: String) throws -> [String] {
        let query = try statement("SELECT id FROM evidence WHERE decision=? AND excluded_revision>? AND id>? ORDER BY id LIMIT 256")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int(query, 1, Int32(TravelScanDecision.noCamera.rawValue))
        sqlite3_bind_int64(query, 2, Int64(revision))
        bind(id, to: query, at: 3)
        var result: [String] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else { throw LibraryPreparationError.saveFailed }
            result.append(String(cString: value))
        }
    }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            db = nil
            throw LibraryPreparationError.saveFailed
        }
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("CREATE TABLE IF NOT EXISTS scan_identity(id INTEGER PRIMARY KEY, identity TEXT NOT NULL)")
            try exec("INSERT OR IGNORE INTO scan_identity(id,identity) VALUES(1,lower(hex(randomblob(16))))")
            try exec("CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, modified REAL, camera INTEGER, decision INTEGER, checked REAL, sweep TEXT, media INTEGER, excluded_revision INTEGER DEFAULT 0)")
            try exec("CREATE INDEX IF NOT EXISTS scan_pending ON evidence(decision,checked,id)")
            try migrateVideoEvidence()
            let identity = try statement("SELECT identity FROM scan_identity WHERE id=1")
            defer { sqlite3_finalize(identity) }
            guard sqlite3_step(identity) == SQLITE_ROW, let value = sqlite3_column_text(identity, 0) else {
                throw LibraryPreparationError.saveFailed
            }
            ledgerIdentity = String(cString: value)
        } catch { sqlite3_close_v2(db); db = nil; throw error }
    }

    /// User-data camera tags and track metadata were overlooked by the first video
    /// reader. Its positives remain valid. Only old negative video inspections
    /// need another pass; images, Live Photos and existing unknowns stay intact.
    private func migrateVideoEvidence() throws {
        try exec("CREATE TABLE IF NOT EXISTS evidence_rules(kind TEXT PRIMARY KEY, version INTEGER NOT NULL)")
        let previousVersion = "SELECT COALESCE((SELECT version FROM evidence_rules WHERE kind='video'),1)"
        guard try scalar(previousVersion) < 2 else { return }
        try transaction {
            guard try scalar(previousVersion) < 2 else { return }
            let oldNegative = "media=\(PhotoMediaKind.video.rawValue) AND camera=\(CameraEvidence.confirmedMissing.rawValue)"
            let excluded = TravelScanDecision.noCamera.rawValue
            let admitted = TravelScanDecision.eligible.rawValue
            let restoresMembers = try scalar("SELECT EXISTS(SELECT 1 FROM evidence WHERE \(oldNegative) AND decision=\(excluded))") != 0
            try exec("""
                UPDATE evidence SET camera=\(CameraEvidence.unknown.rawValue),checked=0,excluded_revision=0,
                    decision=CASE WHEN decision IN (\(excluded),\(admitted)) THEN \(TravelScanDecision.pendingCamera.rawValue) ELSE decision END
                WHERE \(oldNegative)
                """)
            if restoresMembers {
                // New exclusions alone can use the removal journal. Restoring members
                // also requires a lightweight metadata reconciliation before publication.
                try exec("UPDATE scan_identity SET identity=lower(hex(randomblob(16))) WHERE id=1")
            }
            try exec("INSERT OR REPLACE INTO evidence_rules(kind,version) VALUES('video',2)")
        }
    }

    private func bind(_ s: String?, to stmt: OpaquePointer, at i: Int32) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, transient) } else { sqlite3_bind_null(stmt, i) }
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LibraryPreparationError.saveFailed }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw LibraryPreparationError.saveFailed }
        return result
    }
    private func scalar(_ sql: String) throws -> Int {
        let query = try statement(sql); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw LibraryPreparationError.saveFailed }
        return Int(sqlite3_column_int(query, 0))
    }
    private func done(_ query: OpaquePointer) throws {
        guard sqlite3_step(query) == SQLITE_DONE else { throw LibraryPreparationError.saveFailed }; sqlite3_reset(query)
    }
    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE"); do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
