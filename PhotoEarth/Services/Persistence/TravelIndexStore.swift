import Foundation
import SQLite3
import os

nonisolated protocol TravelIndexStoring: Sendable {
    func load() async throws -> TravelIndex?
    func save(_ snapshot: TravelIndexSnapshot) async throws
    func photos(in viewport: EarthViewport, limit: Int) async throws -> [PhotoAssetRecord]
    /// Offsets count spatial candidates, including rejected rows. An empty page
    /// with a nextOffset is a bounded continuation, not an exhausted viewport.
    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int
    ) async throws -> PhotoQueryPage
    func updatePlaceNames(_ places: [TravelPlace]) async throws
    func latestAssetID(for placeID: String) async throws -> String?
    func latestAssetIDs(for placeIDs: [String]) async throws -> [String: String]
    func latestPhotoPreviews(for placeIDs: [String]) async throws -> [String: PhotoPreviewMetadata]
    func assetIDs(for placeID: String, offset: Int, limit: Int) async throws -> [String]
    func photoPage(for placeIDs: [String], offset: Int, limit: Int) async throws -> PhotoQueryPage
    func remove() async throws
}

nonisolated extension TravelIndexStoring {
    func latestPhotoPreviews(for placeIDs: [String]) async throws -> [String: PhotoPreviewMetadata] {
        var result: [String: PhotoPreviewMetadata] = [:]
        for id in placeIDs.prefix(15) {
            try Task.checkCancellation()
            if let photo = try await photoPage(for: [id], offset: 0, limit: 1).records.first {
                result[id] = PhotoPreviewMetadata(photo)
            }
        }
        return result
    }
    func latestAssetIDs(for placeIDs: [String]) async throws -> [String: String] {
        try await latestPhotoPreviews(for: placeIDs).mapValues(\.assetID)
    }

}

nonisolated enum TravelIndexStoreError: LocalizedError {
    case incompatibleSchema
    case database(String)
    case invalidSnapshot
    case corrupt

    var errorDescription: String? {
        switch self {
        case .incompatibleSchema:
            AppLocalization.string("error.index.incompatible", defaultValue: "The photo index needs to be rebuilt.")
        case let .database(message):
            AppLocalization.format("error.index.database", defaultValue: "Photo index error: %@", message)
        case .invalidSnapshot:
            AppLocalization.string("error.index.invalid", defaultValue: "The photo index is incomplete and needs to be rebuilt.")
        case .corrupt:
            AppLocalization.string("error.index.corrupt", defaultValue: "The photo index needs to be rebuilt.")
        }
    }
}

actor SQLiteTravelIndexStore: TravelIndexStoring {
    private static let cellSize = 10.0
    // Bump the selection revision when sampling, ranking or fallback changes.
    private static let visitCoverStrategy = Int32(ScenicCoverAnalysis.version << 16 | 1)
    // A page can be short or empty while nextOffset still advances. Bounding
    // the geographic filter prevents sparse views from monopolizing this actor.
    nonisolated static let photoPageCandidateBudget = 512

    private let databaseURL: URL
    private let legacyJSONURLs: [URL]
    private let localeIdentifier: String
    private var readConnection: SQLiteReadConnection?
    private(set) var visitCoverGeneration: UInt64 = 0
    private var metadataRevision = 0 {
        didSet { coverSceneCache = nil; visitCoverGeneration &+= 1 }
    }
    // Only the current visit is retained between sampling and ranking.
    private var coverSceneCache: (visit: String, excluded: Set<String>, sampler: ScenicCoverSceneSampler)?
    private var transitFilterEnabled: Bool
    private var readerRevisions: [UUID: Int] = [:]
    // Each window stores at most one SQL batch of consumed ordering keys. It
    // also supports a strict page stopping halfway through a candidate batch.
    private var spatialPageKeys: SpatialPhotoPageKeys?
    private var spatialCandidateBatch: SpatialPhotoCandidateBatch?
    private var collectionPageKeys: CollectionPhotoPageKeys?

    init(fileManager: FileManager = .default, locale: Locale = AppLocalization.locale) {
        transitFilterEnabled = UserDefaults.standard.object(forKey: "photoEarth.hidesTransitPhotos") as? Bool ?? true
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoEarth", isDirectory: true)
        databaseURL = directory.appendingPathComponent("travel-index-v3.sqlite")
        legacyJSONURLs = [1, 2].map { version in
            directory.appendingPathComponent("travel-index-v\(version).json")
        }
        localeIdentifier = AppLocalization.supportedLocale(for: locale).identifier
    }

    /// Custom databases are also used for raw-index fixtures; callers explicitly enable the product filter.
    init(databaseURL: URL, legacyJSONURL: URL? = nil, locale: Locale = AppLocalization.locale, hidesTransitPhotos: Bool = false) {
        transitFilterEnabled = hidesTransitPhotos
        self.databaseURL = databaseURL
        legacyJSONURLs = [legacyJSONURL].compactMap { $0 }
        localeIdentifier = AppLocalization.supportedLocale(for: locale).identifier
    }

    private init(databaseURL: URL, connection: SQLiteReadConnection, localeIdentifier: String, hidesTransitPhotos: Bool) {
        transitFilterEnabled = hidesTransitPhotos
        self.databaseURL = databaseURL
        legacyJSONURLs = []
        self.localeIdentifier = localeIdentifier
        readConnection = connection
    }

    func load() async throws -> TravelIndex? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        do {
            let index: TravelIndex? = try withDatabase(create: false) { database in
                let metadata = try readMetadata(database)
                if metadata.isEmpty { return nil } // A durable first-scan checkpoint can precede the first index.
                guard let version = metadata["schema_version"].flatMap(Int.init),
                      version == TravelIndex.currentSchemaVersion,
                      let generatedAt = metadata["generated_at"].flatMap(Double.init),
                      let sourcePhotoCount = metadata["source_photo_count"].flatMap(Int.init),
                      let locatedPhotoCount = metadata["located_photo_count"].flatMap(Int.init) else {
                    throw TravelIndexStoreError.incompatibleSchema
                }

                return TravelIndex(
                    schemaVersion: version,
                    generatedAt: Date(timeIntervalSince1970: generatedAt),
                    sourcePhotoCount: sourcePhotoCount,
                    locatedPhotoCount: locatedPhotoCount,
                    places: try readPlaces(database),
                    journeys: try readJourneys(database),
                    hiddenTransitPhotoCount: try hiddenTransitCount(database),
                    transitFilteringApplied: transitFilterEnabled,
                    transitRevision: try transitRevision(database)
                )
            }
            removeLegacyFiles()
            return index
        } catch TravelIndexStoreError.incompatibleSchema {
            try removeDatabaseFiles()
            return nil
        } catch TravelIndexStoreError.corrupt {
            // The index is derived entirely from PhotoKit. A corrupt cache is safer to
            // discard than to keep retrying on every launch.
            try removeDatabaseFiles()
            return nil
        }
    }

    func save(_ snapshot: TravelIndexSnapshot) async throws {
        let placeIDs = Set(snapshot.index.places.map(\.id))
        guard snapshot.index.isCompatible,
              snapshot.index.locatedPhotoCount == snapshot.photos.count,
              snapshot.photos.allSatisfy({ photo in
                  photo.coordinate.isValid
                      && photo.placeID.map(placeIDs.contains) == true
              }) else {
            throw TravelIndexStoreError.invalidSnapshot
        }

        try withDatabase(create: true) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            var committed = false
            defer {
                if !committed { try? execute(database, "ROLLBACK") }
            }

            try execute(database, "DELETE FROM visit_covers")
            try execute(database, "DELETE FROM photo_locations")
            try execute(database, "DELETE FROM photos")
            try execute(database, "DELETE FROM journey_places")
            try execute(database, "DELETE FROM journeys")
            try execute(database, "DELETE FROM places")
            try execute(database, "DELETE FROM metadata")

            try writeMetadata(snapshot.index, to: database)
            try writePlaces(snapshot.index.places, to: database)
            try cacheLabels(snapshot.index.places, localeIdentifier: localeIdentifier, db: database)
            try writeJourneys(snapshot.index.journeys, to: database)
            try writePhotos(snapshot.photos, to: database)
            try rebuildTransitClassification(database)

            try execute(database, "COMMIT")
            committed = true
        }

        visitCoverGeneration &+= 1
        coverSceneCache = nil
        removeLegacyFiles()
    }

    func photos(in viewport: EarthViewport, limit: Int) async throws -> [PhotoAssetRecord] {
        try await photos(in: viewport, limit: limit, placeIDs: nil)
    }

    func photos(in viewport: EarthViewport, limit: Int, placeIDs: [String]?) async throws -> [PhotoAssetRecord] {
        if let placeIDs, placeIDs.isEmpty { return [] }
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        try Task.checkCancellation()
        let bounds = PhotoSpatialBounds(viewport: viewport)
        let resultLimit = min(limit, MemoryPhotoSelection.candidateLimit)
        let representativesPerCell = representativeLimit(for: bounds, resultLimit: resultLimit)

        let candidates = try withDatabase(create: false) { database in
            if let placeIDs {
                try prepareSelectedPlaces(placeIDs, table: "selected_preview_places", database: database)
            }
            var candidates: [PhotoAssetRecord] = []
            for longitudeRange in bounds.longitudeRanges {
                for cell in spatialCells(
                    minimumLatitude: bounds.minimumLatitude,
                    maximumLatitude: bounds.maximumLatitude,
                    longitudeRange: longitudeRange
                ) {
                    try Task.checkCancellation()
                    candidates.append(contentsOf: try readPhotoCandidates(
                        database,
                        latitudeCell: cell.latitude,
                        longitudeCell: cell.longitude,
                        minimumLatitude: bounds.minimumLatitude,
                        maximumLatitude: bounds.maximumLatitude,
                        longitudeRange: longitudeRange,
                        limit: representativesPerCell,
                        restrictsPlaces: placeIDs != nil
                    ))
                }
            }
            return candidates
        }

        try Task.checkCancellation()
        return PhotoSelection.photos(from: candidates, in: viewport, limit: resultLimit)
    }

    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int
    ) async throws -> PhotoQueryPage {
        try Task.checkCancellation()
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else {
            return PhotoQueryPage(records: [], nextOffset: nil)
        }
        let bounds = PhotoSpatialBounds(viewport: viewport)
        do {
            let page = try withDatabase(create: false) { database in
                try readPhotoPage(
                    database,
                    viewport: viewport,
                    bounds: bounds,
                    offset: max(0, offset),
                    limit: limit
                )
            }
            try Task.checkCancellation()
            return page
        } catch {
            // SQLite reports SQLITE_INTERRUPT for cancellation inside its sort;
            // callers must receive cancellation, not a retryable database error.
            try Task.checkCancellation()
            throw error
        }
    }

    /// Raw RTree candidates for strict native-screen paging. Returning at most
    /// 512 rows keeps projection on the main actor bounded. Offset is consumed
    /// by PhotoWallPageSelection, which may stop before this batch ends.
    func photoWallCandidates(in viewport: EarthViewport, offset: Int) async throws -> PhotoQueryPage {
        try Task.checkCancellation()
        let start = max(0, offset)
        if let batch = spatialCandidateBatch, batch.viewport == viewport,
           start >= batch.offset, start < batch.offset + batch.page.records.count {
            // A strict page can stop at its 48th hit before consuming the SQL
            // batch. Keep those unexamined candidates for subsequent pages.
            return PhotoQueryPage(records: Array(batch.page.records.dropFirst(start - batch.offset)),
                                  nextOffset: batch.page.nextOffset)
        }
        let bounds = PhotoSpatialBounds(viewport: viewport)
        do {
            let page = try withDatabase(create: false) { database in
                try readPhotoPage(database, viewport: viewport, bounds: bounds, offset: start,
                                  limit: PhotoWallPageSelection.candidateLimit, filtersSphericalBounds: false)
            }
            spatialCandidateBatch = SpatialPhotoCandidateBatch(viewport: viewport, offset: start, page: page)
            return page
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func photoPage(for placeIDs: [String], offset: Int, limit: Int) async throws -> PhotoQueryPage {
        try Task.checkCancellation()
        guard !placeIDs.isEmpty, limit > 0 else {
            return PhotoQueryPage(records: [], nextOffset: nil)
        }
        let pageSize = min(limit, PhotoWallPageSelection.pageSize)
        let start = max(0, offset)
        let members = Set(placeIDs)
        let singlePlaceID = members.count == 1 ? members.first : nil
        let previousKeys = collectionPageKeys?.placeIDs == members ? collectionPageKeys?.keys : nil
        let key = start > 0 ? previousKeys?[start] : nil
        do {
            return try withDatabase(create: false) { database in
                sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
                defer { sqlite3_progress_handler(database, 0, nil, nil) }
                // The membership belongs to the pinned WAL read session, so
                // thousands of cluster IDs are inserted only once per wall.
                if singlePlaceID == nil {
                    try prepareSelectedPlaces(placeIDs, table: "selected_places", database: database)
                }
                let legacySeek = start > 0 && key == nil
                let statement = try prepare(database, """
                    SELECT id, latitude, longitude, creation_date, pixel_width,
                           pixel_height, favorite, place_id, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                    FROM photos
                    WHERE \(transitPredicate()) AND \(singlePlaceID == nil ? "place_id IN (SELECT id FROM selected_places)" : "place_id = ?")
                    \(key == nil ? "" : "AND (creation_date < ? OR (creation_date = ? AND id > ?))")
                    ORDER BY creation_date DESC, id ASC
                    LIMIT ?\(legacySeek ? " OFFSET ?" : "")
                    """)
                defer { sqlite3_finalize(statement) }
                var binding: Int32 = 1
                if let singlePlaceID {
                    try bind(singlePlaceID, to: statement, at: binding, database: database)
                    binding += 1
                }
                if let key { try bindOrderingKey(key, statement: statement, index: &binding, database: database) }
                sqlite3_bind_int64(statement, binding, Int64(pageSize + 1))
                if legacySeek { sqlite3_bind_int64(statement, binding + 1, Int64(start)) }
                var records: [PhotoAssetRecord] = []
                var consumedKeys: [Int: PhotoOrderingKey] = [:]
                if let key { consumedKeys[start] = key }
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(statement)
                    guard status == SQLITE_DONE || status == SQLITE_ROW else { throw databaseError(database) }
                    if status == SQLITE_DONE || records.count == pageSize {
                        collectionPageKeys = CollectionPhotoPageKeys(placeIDs: members, keys: consumedKeys)
                        return PhotoQueryPage(records: records, nextOffset: status == SQLITE_ROW ? start + records.count : nil)
                    }
                    let photo = try photoRecord(from: statement, database: database)
                    records.append(photo)
                    consumedKeys[start + records.count] = PhotoOrderingKey(photo)
                }
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func removedPhotoCount(for placeIDs: Set<String>, assetIDs: Set<String>) throws -> Int {
        guard !placeIDs.isEmpty, !assetIDs.isEmpty else { return 0 }
        try Task.checkCancellation()
        return try withDatabase(create: false) { database in
            try prepareSelectedPlaces(Array(assetIDs), table: "collection_wall_removed", database: database)
            let statement = try prepare(database, """
                SELECT place_id FROM photos
                WHERE id IN (SELECT id FROM collection_wall_removed) AND \(transitPredicate())
                """)
            defer { sqlite3_finalize(statement) }
            var count = 0
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return count }
                guard status == SQLITE_ROW else { throw databaseError(database) }
                if let id = textColumn(statement, at: 0), placeIDs.contains(id) { count += 1 }
            }
        }
    }

    private func prepareSelectedPlaces(_ placeIDs: [String], table: String,
                                       database: OpaquePointer) throws {
        let members = Set(placeIDs)
        if readConnection?.selectedPlaceMembership[table] == members { return }
        // A cancelled replacement can leave only part of the new membership.
        readConnection?.selectedPlaceMembership[table] = nil
        // The table name is an internal constant, never caller-provided SQL.
        try execute(database, "CREATE TEMP TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY); DELETE FROM \(table)")
        let membership = try prepare(database, "INSERT OR IGNORE INTO \(table) VALUES (?)")
        defer { sqlite3_finalize(membership) }
        for id in members {
            try Task.checkCancellation()
            try bind(id, to: membership, at: 1, database: database)
            try stepDone(membership, database: database)
            reset(membership)
        }
        readConnection?.selectedPlaceMembership[table] = members
    }

    func assetIDs(for placeID: String, offset: Int, limit: Int) async throws -> [String] {
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try withDatabase(create: false) { database in
            let statement = try prepare(
                database,
                """
                SELECT id
                FROM photos
                WHERE \(transitPredicate()) AND place_id = ?
                ORDER BY creation_date ASC, id ASC
                LIMIT ? OFFSET ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(placeID, to: statement, at: 1, database: database)
            sqlite3_bind_int64(statement, 2, Int64(limit))
            sqlite3_bind_int64(statement, 3, Int64(max(0, offset)))

            var result: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError(database) }
                if let id = textColumn(statement, at: 0) { result.append(id) }
            }
            return result
        }
    }

    func updatePlaceNames(_ places: [TravelPlace]) async throws {
        guard !places.isEmpty,
              FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try withDatabase(create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            var committed = false
            defer {
                if !committed { try? execute(database, "ROLLBACK") }
            }

            let statement = try prepare(
                database,
                "UPDATE places SET name = ?, country = ? WHERE id = ? AND latitude = ? AND longitude = ?"
            )
            defer { sqlite3_finalize(statement) }
            for place in places {
                try bind(place.name, to: statement, at: 1, database: database)
                try bind(place.country, to: statement, at: 2, database: database)
                try bind(place.id, to: statement, at: 3, database: database)
                sqlite3_bind_double(statement, 4, place.coordinate.latitude)
                sqlite3_bind_double(statement, 5, place.coordinate.longitude)
                try stepDone(statement, database: database)
                if sqlite3_changes(database) > 0 {
                    try writeLabelCache(PlaceLabelBasis.key(place.coordinate), label: PlaceDisplayLabel(place: place),
                                        attempts: 0, retry: nil, db: database)
                }
                reset(statement)
            }

            try execute(database, "COMMIT")
            committed = true
        }
    }

    func latestAssetID(for placeID: String) async throws -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try withDatabase(create: false) { database in
            let statement = try prepare(
                database,
                """
                SELECT id
                FROM photos
                WHERE \(transitPredicate()) AND place_id = ?
                ORDER BY creation_date DESC, id ASC
                LIMIT 1
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(placeID, to: statement, at: 1, database: database)

            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            return textColumn(statement, at: 0)
        }
    }

    /// One connection and statement per bounded home batch, with index seeks
    /// per place. No full-library grouping/sort or per-photo materialization.
    func latestAssetIDs(for placeIDs: [String]) async throws -> [String: String] {
        try await latestPhotoPreviews(for: placeIDs).mapValues(\.assetID)
    }

    func latestPhotoPreviews(for placeIDs: [String]) async throws -> [String: PhotoPreviewMetadata] {
        guard !placeIDs.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        let interval = OverviewPerformance.begin("Home cover batch")
        defer { OverviewPerformance.end("Home cover batch", interval) }
        return try withDatabase(create: false) { database in
            let ownsTransaction = sqlite3_get_autocommit(database) != 0
            if ownsTransaction { try execute(database, "BEGIN DEFERRED TRANSACTION") }
            defer { if ownsTransaction { try? execute(database, "ROLLBACK") } }
            let statement = try prepare(database, "SELECT id, pixel_width, pixel_height FROM photos WHERE \(transitPredicate()) AND place_id = ? ORDER BY creation_date DESC, id ASC LIMIT 1")
            defer { sqlite3_finalize(statement) }
            var result: [String: PhotoPreviewMetadata] = [:]
            for id in placeIDs.prefix(15) {
                try Task.checkCancellation()
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(id, to: statement, at: 1, database: database)
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    guard let assetID = textColumn(statement, at: 0) else { throw TravelIndexStoreError.corrupt }
                    result[id] = PhotoPreviewMetadata(assetID: assetID,
                        pixelWidth: Int(sqlite3_column_int64(statement, 1)), pixelHeight: Int(sqlite3_column_int64(statement, 2)))
                }
                else if status != SQLITE_DONE { throw databaseError(database) }
            }
            return result
        }
    }

    func remove() async throws {
        try removeDatabaseFiles()
        removeLegacyFiles()
    }

    private func withDatabase<T>(
        create: Bool,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        if let readConnection { return try operation(readConnection.database) }
        if create {
            spatialPageKeys = nil
            spatialCandidateBatch = nil
            collectionPageKeys = nil
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | (create ? SQLITE_OPEN_CREATE : 0)
            | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw TravelIndexStoreError.database(AppLocalization.string("error.index.open", defaultValue: "Unable to open the index."))
        }
        defer { sqlite3_close_v2(database) }

        sqlite3_busy_timeout(database, 2_000)
        try execute(database, "PRAGMA foreign_keys = ON")
        try execute(database, "PRAGMA journal_mode = WAL")
        try execute(database, "PRAGMA synchronous = NORMAL")
        try createSchema(database)
        return try operation(database)
    }

    private func createSchema(_ database: OpaquePointer) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS places (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                name TEXT NOT NULL,
                country TEXT,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                start_date REAL NOT NULL,
                end_date REAL NOT NULL,
                photo_count INTEGER NOT NULL,
                cover_asset_id TEXT
            );
            CREATE TABLE IF NOT EXISTS journeys (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                title TEXT NOT NULL,
                start_date REAL NOT NULL,
                end_date REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS journey_places (
                journey_id TEXT NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                place_id TEXT NOT NULL REFERENCES places(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                PRIMARY KEY (journey_id, place_id)
            );
            CREATE TABLE IF NOT EXISTS photos (
                id TEXT PRIMARY KEY NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                creation_date REAL NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                favorite INTEGER NOT NULL,
                media_kind INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                place_id TEXT REFERENCES places(id) ON DELETE SET NULL,
                latitude_cell INTEGER NOT NULL,
                longitude_cell INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS photos_place_date
                ON photos(place_id, creation_date, id);
            CREATE INDEX IF NOT EXISTS photos_place_newest
                ON photos(place_id, creation_date DESC, id ASC);
            CREATE INDEX IF NOT EXISTS photos_place_favorite
                ON photos(place_id, favorite DESC, creation_date DESC, id ASC);
            CREATE TABLE IF NOT EXISTS visit_covers (
                place_id TEXT PRIMARY KEY NOT NULL,
                asset_id TEXT NOT NULL,
                filter_transit INTEGER NOT NULL,
                strategy INTEGER NOT NULL,
                expires REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cover_analysis (
                asset_id TEXT PRIMARY KEY NOT NULL,
                source_revision TEXT NOT NULL,
                strategy_version INTEGER NOT NULL,
                scenery REAL NOT NULL,
                aesthetics REAL,
                utility INTEGER NOT NULL,
                largest_face REAL NOT NULL,
                landmark REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS photos_cell
                ON photos(latitude_cell, longitude_cell);
            CREATE INDEX IF NOT EXISTS photos_cell_quality
                ON photos(
                    latitude_cell, longitude_cell,
                    favorite DESC, creation_date DESC, id ASC
                );
            CREATE INDEX IF NOT EXISTS photos_date
                ON photos(creation_date DESC, id ASC);
            CREATE VIRTUAL TABLE IF NOT EXISTS photo_locations USING rtree(
                photo_rowid,
                minimum_latitude, maximum_latitude,
                minimum_longitude, maximum_longitude
            );
            CREATE TABLE IF NOT EXISTS preparation_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS library_sync (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS place_label_cache (
                basis TEXT NOT NULL, locale TEXT NOT NULL,
                city TEXT NOT NULL, country TEXT, region_code TEXT,
                source TEXT, source_version TEXT, offline_place_id TEXT,
                attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL,
                updated_at REAL NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
                terminal INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (basis, locale)
            );
            CREATE TABLE IF NOT EXISTS scan_photos (
                id TEXT PRIMARY KEY, latitude REAL NOT NULL, longitude REAL NOT NULL,
                creation_date REAL NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
                favorite INTEGER NOT NULL, media_kind INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0, group_number INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS scan_photos_date ON scan_photos(creation_date, id);
            CREATE TABLE IF NOT EXISTS scan_cover_updates (asset_id TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;
            CREATE TRIGGER IF NOT EXISTS record_staged_cover_edit AFTER UPDATE OF latitude ON scan_photos
            BEGIN
                INSERT OR IGNORE INTO scan_cover_updates(asset_id) VALUES (NEW.id);
            END;
            """
        )
        try ensureLocalizedPlaceLabelSchema(database)
        // Version 4 changes only the derived place-label cache. Photo rows and
        // clustering remain valid, so upgrading must not trigger a PhotoKit scan.
        try execute(database, "UPDATE metadata SET value = '4' WHERE key = 'schema_version' AND value = '3'")
        try ensureMediaSchema(database)
        try ensureTransitSchema(database)
    }

    private func ensureMediaSchema(_ database: OpaquePointer) throws {
        let photoNeedsKind = try !hasColumn("media_kind", in: "photos", database: database)
        let photoNeedsDuration = try !hasColumn("duration", in: "photos", database: database)
        let scanNeedsKind = try !hasColumn("media_kind", in: "scan_photos", database: database)
        let scanNeedsDuration = try !hasColumn("duration", in: "scan_photos", database: database)
        let coverNeedsLandmark = try !hasColumn("landmark", in: "cover_analysis", database: database)
        let needsMigration = photoNeedsKind || photoNeedsDuration || scanNeedsKind || scanNeedsDuration || coverNeedsLandmark
        let upgradesVersionFour = try stateValue("schema_version", table: "metadata", db: database) == "4"

        if needsMigration || upgradesVersionFour {
            try transaction(database) {
                if photoNeedsKind { try execute(database, "ALTER TABLE photos ADD COLUMN media_kind INTEGER NOT NULL DEFAULT 0") }
                if photoNeedsDuration { try execute(database, "ALTER TABLE photos ADD COLUMN duration REAL NOT NULL DEFAULT 0") }
                if scanNeedsKind { try execute(database, "ALTER TABLE scan_photos ADD COLUMN media_kind INTEGER NOT NULL DEFAULT 0") }
                if scanNeedsDuration { try execute(database, "ALTER TABLE scan_photos ADD COLUMN duration REAL NOT NULL DEFAULT 0") }
                if coverNeedsLandmark, try !hasColumn("landmark", in: "cover_analysis", database: database) {
                    try execute(database, "ALTER TABLE cover_analysis ADD COLUMN landmark REAL NOT NULL DEFAULT 0")
                }
                if upgradesVersionFour {
                    // Existing rows remain usable as still-photo placeholders while
                    // a full metadata pass discovers Live Photos and older videos.
                    try execute(database, "DELETE FROM scan_photos; DELETE FROM library_sync; DELETE FROM preparation_state WHERE key = 'run'")
                    try execute(database, "UPDATE metadata SET value = '5' WHERE key = 'schema_version' AND value = '4'")
                }
            }
        }
    }

    private func hasColumn(_ column: String, in table: String, database: OpaquePointer) throws -> Bool {
        let statement = try prepare(database, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return false }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            if textColumn(statement, at: 1) == column { return true }
        }
    }

    private func ensureLocalizedPlaceLabelSchema(_ database: OpaquePointer) throws {
        let statement = try prepare(database, "PRAGMA table_info(place_label_cache)")
        defer { sqlite3_finalize(statement) }
        var hasTerminal = false
        var hasLocale = false
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            if textColumn(statement, at: 1) == "terminal" { hasTerminal = true }
            if textColumn(statement, at: 1) == "locale" { hasLocale = true }
        }
        if hasLocale { return }
        if !hasTerminal {
            try execute(database, "ALTER TABLE place_label_cache ADD COLUMN terminal INTEGER NOT NULL DEFAULT 0")
        }

        try execute(database, """
            ALTER TABLE place_label_cache RENAME TO place_label_cache_v3;
            CREATE TABLE place_label_cache (
                basis TEXT NOT NULL, locale TEXT NOT NULL,
                city TEXT NOT NULL, country TEXT, region_code TEXT,
                source TEXT, source_version TEXT, offline_place_id TEXT,
                attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL,
                updated_at REAL NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
                terminal INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (basis, locale)
            );
            INSERT INTO place_label_cache(
                basis, locale, city, country, attempts, retry_at, updated_at, complete, terminal
            )
            SELECT basis, 'zh-Hans', city, country, attempts, retry_at, updated_at, complete, terminal
            FROM place_label_cache_v3;
            """)

        // V3 wrote the Chinese display label into `places`. Seed it under the
        // new coordinate basis so it remains immediately usable after upgrade.
        for place in try readPlacesRaw(database) {
            let label = PlaceDisplayLabel(place: place)
            guard label.hasCity || label.hasCountry else { continue }
            try writeLabelCache(
                PlaceLabelBasis.key(place.coordinate),
                localeIdentifier: AppLocalization.SupportedLanguage.simplifiedChinese.rawValue,
                label: label,
                attempts: 0,
                retry: nil,
                db: database
            )
        }
        try execute(database, "DROP TABLE place_label_cache_v3")
    }

    private func writeMetadata(_ index: TravelIndex, to database: OpaquePointer) throws {
        // Image edits are invalidated by PhotoKit notices; a rebuilt index also
        // conservatively discards scores from every earlier metadata generation.
        try execute(database, "DELETE FROM cover_analysis")
        let values = [
            ("schema_version", String(index.schemaVersion)),
            ("generated_at", String(index.generatedAt.timeIntervalSince1970)),
            ("source_photo_count", String(index.sourcePhotoCount)),
            ("located_photo_count", String(index.locatedPhotoCount)),
        ]
        let statement = try prepare(database, "INSERT INTO metadata(key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        for (key, value) in values {
            try bind(key, to: statement, at: 1, database: database)
            try bind(value, to: statement, at: 2, database: database)
            try stepDone(statement, database: database)
            reset(statement)
        }
    }

    private func writePlaces(_ places: [TravelPlace], to database: OpaquePointer) throws {
        let statement = try prepare(
            database,
            """
            INSERT INTO places(
                id, position, name, country, latitude, longitude,
                start_date, end_date, photo_count, cover_asset_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        for (position, place) in places.enumerated() {
            try bind(place.id, to: statement, at: 1, database: database)
            sqlite3_bind_int64(statement, 2, Int64(position))
            try bind(place.name, to: statement, at: 3, database: database)
            try bind(place.country, to: statement, at: 4, database: database)
            sqlite3_bind_double(statement, 5, place.coordinate.latitude)
            sqlite3_bind_double(statement, 6, place.coordinate.longitude)
            sqlite3_bind_double(statement, 7, place.startDate.timeIntervalSince1970)
            sqlite3_bind_double(statement, 8, place.endDate.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 9, Int64(place.photoCount))
            try bind(place.coverAssetID, to: statement, at: 10, database: database)
            try stepDone(statement, database: database)
            reset(statement)
        }
    }

    private func writeJourneys(_ journeys: [TravelJourney], to database: OpaquePointer) throws {
        let journeyStatement = try prepare(
            database,
            "INSERT INTO journeys(id, position, title, start_date, end_date) VALUES (?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(journeyStatement) }
        let placeStatement = try prepare(
            database,
            "INSERT INTO journey_places(journey_id, place_id, position) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(placeStatement) }

        for (position, journey) in journeys.enumerated() {
            try bind(journey.id, to: journeyStatement, at: 1, database: database)
            sqlite3_bind_int64(journeyStatement, 2, Int64(position))
            try bind(journey.title, to: journeyStatement, at: 3, database: database)
            sqlite3_bind_double(journeyStatement, 4, journey.startDate.timeIntervalSince1970)
            sqlite3_bind_double(journeyStatement, 5, journey.endDate.timeIntervalSince1970)
            try stepDone(journeyStatement, database: database)
            reset(journeyStatement)

            for (placePosition, placeID) in journey.placeIDs.enumerated() {
                try bind(journey.id, to: placeStatement, at: 1, database: database)
                try bind(placeID, to: placeStatement, at: 2, database: database)
                sqlite3_bind_int64(placeStatement, 3, Int64(placePosition))
                try stepDone(placeStatement, database: database)
                reset(placeStatement)
            }
        }
    }

    private func writePhotos(_ photos: [PhotoAssetRecord], to database: OpaquePointer) throws {
        let photoStatement = try prepare(
            database,
            """
            INSERT INTO photos(
                id, latitude, longitude, creation_date, pixel_width, pixel_height,
                favorite, media_kind, duration, place_id, latitude_cell, longitude_cell,
                altitude, horizontal_accuracy, vertical_accuracy
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(photoStatement) }
        let locationStatement = try prepare(
            database,
            """
            INSERT INTO photo_locations(
                photo_rowid, minimum_latitude, maximum_latitude,
                minimum_longitude, maximum_longitude
            ) VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(locationStatement) }

        for photo in photos {
            try bind(photo.id, to: photoStatement, at: 1, database: database)
            sqlite3_bind_double(photoStatement, 2, photo.coordinate.latitude)
            sqlite3_bind_double(photoStatement, 3, photo.coordinate.longitude)
            sqlite3_bind_double(photoStatement, 4, photo.creationDate.timeIntervalSince1970)
            sqlite3_bind_int64(photoStatement, 5, Int64(photo.pixelWidth))
            sqlite3_bind_int64(photoStatement, 6, Int64(photo.pixelHeight))
            sqlite3_bind_int(photoStatement, 7, photo.isFavorite ? 1 : 0)
            sqlite3_bind_int(photoStatement, 8, Int32(photo.mediaKind.rawValue))
            sqlite3_bind_double(photoStatement, 9, photo.duration)
            try bind(photo.placeID, to: photoStatement, at: 10, database: database)
            sqlite3_bind_int64(
                photoStatement,
                11,
                Int64(floor((photo.coordinate.latitude + 90) / Self.cellSize))
            )
            sqlite3_bind_int64(
                photoStatement,
                12,
                Int64(floor((photo.coordinate.longitude + 180) / Self.cellSize))
            )
            bindOptional(photo.altitudeMeters, to: photoStatement, at: 13)
            bindOptional(photo.horizontalAccuracyMeters, to: photoStatement, at: 14)
            bindOptional(photo.verticalAccuracyMeters, to: photoStatement, at: 15)
            try stepDone(photoStatement, database: database)
            let rowID = sqlite3_last_insert_rowid(database)
            reset(photoStatement)

            sqlite3_bind_int64(locationStatement, 1, rowID)
            sqlite3_bind_double(locationStatement, 2, photo.coordinate.latitude)
            sqlite3_bind_double(locationStatement, 3, photo.coordinate.latitude)
            sqlite3_bind_double(locationStatement, 4, photo.coordinate.longitude)
            sqlite3_bind_double(locationStatement, 5, photo.coordinate.longitude)
            try stepDone(locationStatement, database: database)
            reset(locationStatement)
        }
    }

    private func readMetadata(_ database: OpaquePointer) throws -> [String: String] {
        let statement = try prepare(database, "SELECT key, value FROM metadata")
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            if let key = textColumn(statement, at: 0),
               let value = textColumn(statement, at: 1) {
                result[key] = value
            }
        }
        return result
    }

    private func readPlaces(_ database: OpaquePointer) throws -> [TravelPlace] {
        try reuseLabels(readPlacesRaw(database, visible: transitFilterEnabled), db: database)
    }

    private func readPlacesRaw(_ database: OpaquePointer, visible: Bool = false) throws -> [TravelPlace] {
        let statement = try prepare(
            database,
            """
            SELECT p.id, p.name, p.country, p.latitude, p.longitude,
                   \(visible ? "v.start_date, v.end_date, v.photo_count, v.cover_asset_id" : "p.start_date, p.end_date, p.photo_count, p.cover_asset_id")
            FROM places p
            \(visible ? "JOIN transit_place_summaries v ON v.place_id = p.id" : "")
            ORDER BY p.position ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [TravelPlace] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            guard let id = textColumn(statement, at: 0),
                  let name = textColumn(statement, at: 1) else {
                throw TravelIndexStoreError.database(AppLocalization.string("error.index.place_fields", defaultValue: "A place record is incomplete."))
            }
            result.append(TravelPlace(
                id: id,
                name: name,
                country: textColumn(statement, at: 2),
                coordinate: GeoCoordinate(
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4)
                ),
                startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                photoCount: Int(sqlite3_column_int64(statement, 7)),
                coverAssetID: textColumn(statement, at: 8)
            ))
        }
        return result
    }

    private func readJourneys(_ database: OpaquePointer) throws -> [TravelJourney] {
        let placeStatement = try prepare(
            database,
            "SELECT journey_id, place_id FROM journey_places ORDER BY journey_id, position ASC"
        )
        defer { sqlite3_finalize(placeStatement) }
        var placeIDsByJourney: [String: [String]] = [:]
        while true {
            let status = sqlite3_step(placeStatement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            if let journeyID = textColumn(placeStatement, at: 0),
               let placeID = textColumn(placeStatement, at: 1) {
                placeIDsByJourney[journeyID, default: []].append(placeID)
            }
        }

        let statement = try prepare(
            database,
            "SELECT id, title, start_date, end_date FROM journeys ORDER BY position ASC"
        )
        defer { sqlite3_finalize(statement) }
        var result: [TravelJourney] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            guard let id = textColumn(statement, at: 0),
                  let title = textColumn(statement, at: 1) else {
                throw TravelIndexStoreError.database(AppLocalization.string("error.index.journey_fields", defaultValue: "A journey record is incomplete."))
            }
            result.append(TravelJourney(
                id: id,
                title: title,
                startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                placeIDs: placeIDsByJourney[id] ?? []
            ))
        }
        guard transitFilterEnabled else { return result }
        let visible = Dictionary(uniqueKeysWithValues: try readPlaces(database).map { ($0.id, $0) })
        return result.compactMap { journey in
            let members = journey.placeIDs.compactMap { visible[$0] }
            guard let first = members.first, let last = members.last else { return nil }
            return TravelJourney(id: journey.id, title: journey.title, startDate: first.startDate,
                                 endDate: last.endDate, placeIDs: members.map(\.id))
        }
    }

    private func readPhotoCandidates(
        _ database: OpaquePointer,
        latitudeCell: Int,
        longitudeCell: Int,
        minimumLatitude: Double,
        maximumLatitude: Double,
        longitudeRange: ClosedRange<Double>,
        limit: Int,
        restrictsPlaces: Bool = false
    ) throws -> [PhotoAssetRecord] {
        let statement = try prepare(
            database,
            """
            SELECT id, latitude, longitude, creation_date, pixel_width,
                   pixel_height, favorite, place_id, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
            FROM photos INDEXED BY photos_cell_quality
            WHERE \(transitPredicate()) AND latitude_cell = ?
              AND longitude_cell = ?
              AND latitude >= ?
              AND latitude <= ?
              AND longitude >= ?
              AND longitude <= ?
              \(restrictsPlaces ? "AND place_id IN (SELECT id FROM selected_preview_places)" : "")
            ORDER BY favorite DESC, creation_date DESC, id ASC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(latitudeCell))
        sqlite3_bind_int64(statement, 2, Int64(longitudeCell))
        sqlite3_bind_double(statement, 3, minimumLatitude)
        sqlite3_bind_double(statement, 4, maximumLatitude)
        sqlite3_bind_double(statement, 5, longitudeRange.lowerBound)
        sqlite3_bind_double(statement, 6, longitudeRange.upperBound)
        sqlite3_bind_int64(statement, 7, Int64(max(1, limit)))

        var result: [PhotoAssetRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            guard let id = textColumn(statement, at: 0) else {
                throw TravelIndexStoreError.database(AppLocalization.string("error.index.photo_id", defaultValue: "A photo record has no identifier."))
            }
            result.append(PhotoAssetRecord(
                id: id,
                coordinate: GeoCoordinate(
                    latitude: sqlite3_column_double(statement, 1),
                    longitude: sqlite3_column_double(statement, 2)
                ),
                creationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                pixelWidth: Int(sqlite3_column_int64(statement, 4)),
                pixelHeight: Int(sqlite3_column_int64(statement, 5)),
                isFavorite: sqlite3_column_int(statement, 6) != 0,
                mediaKind: PhotoMediaKind(rawValue: Int(sqlite3_column_int(statement, 8))) ?? .photo,
                duration: sqlite3_column_double(statement, 9),
                placeID: textColumn(statement, at: 7),
                altitudeMeters: optionalDouble(statement, at: 10),
                horizontalAccuracyMeters: optionalDouble(statement, at: 11),
                verticalAccuracyMeters: optionalDouble(statement, at: 12)
            ))
        }
        return result
    }

    private func spatialCells(
        minimumLatitude: Double,
        maximumLatitude: Double,
        longitudeRange: ClosedRange<Double>
    ) -> [(latitude: Int, longitude: Int)] {
        let latitudeCellCount = Int(ceil(180 / Self.cellSize))
        let longitudeCellCount = Int(ceil(360 / Self.cellSize))
        let minimumLatitudeCell = min(
            max(Int(floor((minimumLatitude + 90) / Self.cellSize)), 0),
            latitudeCellCount - 1
        )
        let maximumLatitudeCell = min(
            max(Int(floor((maximumLatitude + 90) / Self.cellSize)), 0),
            latitudeCellCount - 1
        )
        let minimumLongitudeCell = min(
            max(Int(floor((longitudeRange.lowerBound + 180) / Self.cellSize)), 0),
            longitudeCellCount - 1
        )
        let maximumLongitudeCell = min(
            max(Int(floor((longitudeRange.upperBound + 180) / Self.cellSize)), 0),
            longitudeCellCount - 1
        )

        var cells: [(latitude: Int, longitude: Int)] = []
        cells.reserveCapacity(
            (maximumLatitudeCell - minimumLatitudeCell + 1)
                * (maximumLongitudeCell - minimumLongitudeCell + 1)
        )
        for latitude in minimumLatitudeCell...maximumLatitudeCell {
            for longitude in minimumLongitudeCell...maximumLongitudeCell {
                cells.append((latitude, longitude))
            }
        }
        return cells
    }

    private func readPhotoPage(
        _ database: OpaquePointer,
        viewport: EarthViewport,
        bounds: PhotoSpatialBounds,
        offset: Int,
        limit: Int,
        filtersSphericalBounds: Bool = true
    ) throws -> PhotoQueryPage {
        try Task.checkCancellation()
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let key = spatialPageKeys?.viewport == viewport ? spatialPageKeys?.keys[offset] : nil
        let statement = try prepareSpatialPhotoStatement(database, bounds: bounds, offset: offset,
                                                        key: offset > 0 ? key : nil,
                                                        limit: Self.photoPageCandidateBudget + 1)
        defer { sqlite3_finalize(statement) }
        var records: [PhotoAssetRecord] = []
        records.reserveCapacity(min(limit, Self.photoPageCandidateBudget))
        var consumedKeys: [Int: PhotoOrderingKey] = [:]
        if let key { consumedKeys[offset] = key }
        var examinedCount = 0
        while examinedCount < Self.photoPageCandidateBudget, records.count < limit {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                spatialPageKeys = SpatialPhotoPageKeys(viewport: viewport, keys: consumedKeys)
                return PhotoQueryPage(records: records, nextOffset: nil)
            }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            let candidate = try photoRecord(from: statement, database: database)
            examinedCount += 1
            consumedKeys[offset + examinedCount] = PhotoOrderingKey(candidate)
            if !filtersSphericalBounds || viewport.contains(candidate.coordinate) { records.append(candidate) }
        }
        try Task.checkCancellation()
        // The lookahead never advances a key. Strict projection may consume
        // only 48 of these 512 candidates; its next offset addresses that exact
        // examined row, not the end of the SQL batch.
        let nextStatus = sqlite3_step(statement)
        guard nextStatus == SQLITE_ROW || nextStatus == SQLITE_DONE else { throw databaseError(database) }
        spatialPageKeys = SpatialPhotoPageKeys(viewport: viewport, keys: consumedKeys)
        return PhotoQueryPage(records: records, nextOffset: nextStatus == SQLITE_ROW ? offset + examinedCount : nil)
    }

    private func prepareSpatialPhotoStatement(_ database: OpaquePointer, bounds: PhotoSpatialBounds,
                                              offset: Int, key: PhotoOrderingKey?, limit: Int?,
                                              restrictsCountPlaces: Bool = false) throws -> OpaquePointer {
        let longitudeClause = bounds.longitudeRanges
            .map { _ in "(location.maximum_longitude >= ? AND location.minimum_longitude <= ?)" }
            .joined(separator: " OR ")
        // Ordinary sequential paging uses the mixed-direction key predicate.
        // OFFSET remains only for a legacy random seek whose bounded checkpoint
        // has expired, never for sequential wall paging or a count continuation.
        let legacySeek = offset > 0 && key == nil
        let limitClause = limit != nil ? "LIMIT ?" : (legacySeek ? "LIMIT -1" : "")
        let statement = try prepare(database, """
            SELECT p.id, p.latitude, p.longitude, p.creation_date, p.pixel_width,
                   p.pixel_height, p.favorite, p.place_id, p.media_kind, p.duration, p.altitude, p.horizontal_accuracy, p.vertical_accuracy
            FROM photos AS p
            JOIN photo_locations AS location ON p.rowid = location.photo_rowid
            WHERE \(transitPredicate(alias: "p"))
              \(restrictsCountPlaces ? "AND p.place_id IN (SELECT id FROM selected_count_places)" : "")
              AND location.maximum_latitude >= ?
              AND location.minimum_latitude <= ?
              AND (\(longitudeClause))
              \(key == nil ? "" : "AND (p.creation_date < ? OR (p.creation_date = ? AND p.id > ?))")
            ORDER BY p.creation_date DESC, p.id ASC
            \(limitClause)\(legacySeek ? " OFFSET ?" : "")
            """)
        do {
            sqlite3_bind_double(statement, 1, bounds.minimumLatitude)
            sqlite3_bind_double(statement, 2, bounds.maximumLatitude)
            var binding: Int32 = 3
            for range in bounds.longitudeRanges {
                sqlite3_bind_double(statement, binding, range.lowerBound)
                sqlite3_bind_double(statement, binding + 1, range.upperBound)
                binding += 2
            }
            if let key { try bindOrderingKey(key, statement: statement, index: &binding, database: database) }
            if let limit { sqlite3_bind_int64(statement, binding, Int64(limit)); binding += 1 }
            if legacySeek { sqlite3_bind_int64(statement, binding, Int64(offset)) }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func bindOrderingKey(_ key: PhotoOrderingKey, statement: OpaquePointer,
                                 index: inout Int32, database: OpaquePointer) throws {
        sqlite3_bind_double(statement, index, key.creationTime)
        sqlite3_bind_double(statement, index + 1, key.creationTime)
        try bind(key.id, to: statement, at: index + 2, database: database)
        index += 3
    }

    /// One prepared statement owns the entire count scan. It is stepped at most
    /// 512 times per call, retaining a single undecoded lookahead row. The WAL
    /// reader bounds its lifetime; pagination has independent key checkpoints.
    func photoWallCountingCandidates(in viewport: EarthViewport, offset: Int, operationID: UUID? = nil,
                                     placeIDs: Set<String>? = nil) async throws -> PhotoQueryPage {
        guard let connection = readConnection else {
            // Non-session callers retain the existing bounded API. Product
            // walls always supply their pinned reader to the exact count path.
            if let placeIDs {
                let reader = try photoReadSnapshot()
                return try await reader.photoWallCountingCandidates(in: viewport, offset: offset,
                                                                    operationID: operationID, placeIDs: placeIDs)
            }
            return try await photoWallCandidates(in: viewport, offset: offset)
        }
        let start = max(0, offset)
        let database = connection.database
        do {
            try Task.checkCancellation()
            sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            if connection.countCursor?.viewport != viewport || connection.countCursor?.nextOffset != start
                || connection.countCursor?.operationID != operationID || connection.countCursor?.placeIDs != placeIDs {
                connection.countCursor = nil
                if let placeIDs {
                    if placeIDs.isEmpty { return .init(records: [], nextOffset: nil) }
                    try prepareSelectedPlaces(Array(placeIDs), table: "selected_count_places", database: database)
                }
                let key = placeIDs == nil && spatialPageKeys?.viewport == viewport ? spatialPageKeys?.keys[start] : nil
                let statement = try prepareSpatialPhotoStatement(database, bounds: PhotoSpatialBounds(viewport: viewport),
                                                                offset: start, key: start > 0 ? key : nil, limit: nil,
                                                                restrictsCountPlaces: placeIDs != nil)
                connection.countCursor = SQLitePhotoCountCursor(statement: statement, viewport: viewport, nextOffset: start,
                                                                operationID: operationID, placeIDs: placeIDs)
            }
            guard let cursor = connection.countCursor else { throw PhotoWallSelectionError.unavailableViewport }
            var records: [PhotoAssetRecord] = []
            records.reserveCapacity(Self.photoPageCandidateBudget)
            let interval = PhotoWallPerformance.begin("WallCountSQLBatch")
            defer { PhotoWallPerformance.end("WallCountSQLBatch", interval, records: records.count) }
            while records.count < Self.photoPageCandidateBudget {
                try Task.checkCancellation()
                let status = cursor.hasLookahead ? SQLITE_ROW : sqlite3_step(cursor.statement)
                cursor.hasLookahead = false
                if status == SQLITE_DONE {
                    connection.countCursor = nil
                    return PhotoQueryPage(records: records, nextOffset: nil)
                }
                guard status == SQLITE_ROW else { throw databaseError(database) }
                records.append(try photoRecord(from: cursor.statement, database: database))
                cursor.recordsRead += 1
            }
            let status = sqlite3_step(cursor.statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError(database) }
            cursor.hasLookahead = status == SQLITE_ROW
            cursor.nextOffset = start + records.count
            if status == SQLITE_DONE { connection.countCursor = nil }
            return PhotoQueryPage(records: records, nextOffset: status == SQLITE_ROW ? cursor.nextOffset : nil)
        } catch {
            if connection.countCursor?.operationID == operationID { connection.countCursor = nil }
            try Task.checkCancellation()
            throw error
        }
    }

    func finishPhotoWallCounting(operationID: UUID? = nil) {
        // A cancelled old viewport must not finalize the next viewport's
        // prepared statement after its async cleanup reaches this actor.
        if readConnection?.countCursor?.operationID == operationID { readConnection?.countCursor = nil }
    }

    var activePhotoCountOperationID: UUID? { readConnection?.countCursor?.operationID }

    private func representativeLimit(
        for bounds: PhotoSpatialBounds,
        resultLimit: Int
    ) -> Int {
        let latitudeCells = max(
            1,
            Int(ceil((bounds.maximumLatitude - bounds.minimumLatitude) / Self.cellSize)) + 1
        )
        let longitudeCells = bounds.longitudeRanges.reduce(0) { count, range in
            count + max(1, Int(ceil((range.upperBound - range.lowerBound) / Self.cellSize)) + 1)
        }
        let cellCount = max(1, latitudeCells * longitudeCells)
        let desired = Int(ceil(Double(resultLimit * 2) / Double(cellCount)))
        let upperBound = min(max(resultLimit, 24), 128)
        return min(max(desired, 1), upperBound)
    }

    private func photoRecord(
        from statement: OpaquePointer,
        database: OpaquePointer
    ) throws -> PhotoAssetRecord {
        guard let id = textColumn(statement, at: 0) else {
            throw TravelIndexStoreError.database(AppLocalization.string("error.index.photo_id", defaultValue: "A photo record has no identifier."))
        }
        return PhotoAssetRecord(
            id: id,
            coordinate: GeoCoordinate(
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2)
            ),
            creationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            pixelWidth: Int(sqlite3_column_int64(statement, 4)),
            pixelHeight: Int(sqlite3_column_int64(statement, 5)),
            isFavorite: sqlite3_column_int(statement, 6) != 0,
            mediaKind: PhotoMediaKind(rawValue: Int(sqlite3_column_int(statement, 8))) ?? .photo,
            duration: sqlite3_column_double(statement, 9),
            placeID: textColumn(statement, at: 7),
                altitudeMeters: optionalDouble(statement, at: 10),
                horizontalAccuracyMeters: optionalDouble(statement, at: 11),
                verticalAccuracyMeters: optionalDouble(statement, at: 12)
        )
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            sqlite3_free(errorMessage)
            throw databaseError(database)
        }
    }

    private func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        return statement
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32,
        database: OpaquePointer
    ) throws {
        let status: Int32
        if let value {
            status = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    index,
                    pointer,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw databaseError(database) }
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func textColumn(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func databaseError(_ database: OpaquePointer) -> TravelIndexStoreError {
        let code = sqlite3_errcode(database)
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .corrupt }
        return .database(AppLocalization.string("error.index.io", defaultValue: "The local index is temporarily unavailable."))
    }

    private func removeDatabaseFiles() throws {
        visitCoverGeneration &+= 1
        coverSceneCache = nil
        spatialPageKeys = nil
        spatialCandidateBatch = nil
        collectionPageKeys = nil
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func removeLegacyFiles() {
        for url in legacyJSONURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private nonisolated struct PhotoOrderingKey {
    let creationTime: Double
    let id: String
    init(_ photo: PhotoAssetRecord) {
        creationTime = photo.creationDate.timeIntervalSince1970
        id = photo.id
    }
}

private nonisolated struct SpatialPhotoPageKeys {
    let viewport: EarthViewport
    let keys: [Int: PhotoOrderingKey]
}

private nonisolated struct SpatialPhotoCandidateBatch {
    let viewport: EarthViewport
    let offset: Int
    let page: PhotoQueryPage
}

private nonisolated struct CollectionPhotoPageKeys {
    let placeIDs: Set<String>
    let keys: [Int: PhotoOrderingKey]
}

/// Accessed only on the owning SQLiteTravelIndexStore actor. The statement is
/// finalized before that reader rolls back and releases its WAL lease.
private nonisolated final class SQLitePhotoCountCursor: @unchecked Sendable {
    let statement: OpaquePointer
    let viewport: EarthViewport
    let operationID: UUID?
    let placeIDs: Set<String>?
    var nextOffset: Int
    var hasLookahead = false
    var recordsRead = 0
    private let interval: OSSignpostIntervalState?
    init(statement: OpaquePointer, viewport: EarthViewport, nextOffset: Int, operationID: UUID?, placeIDs: Set<String>?) {
        self.statement = statement
        self.viewport = viewport
        self.operationID = operationID
        self.placeIDs = placeIDs
        self.nextOffset = nextOffset
        interval = PhotoWallPerformance.begin("WallCountSQLCursor")
    }
    deinit {
        sqlite3_finalize(statement)
        PhotoWallPerformance.end("WallCountSQLCursor", interval, records: recordsRead)
    }
}

/// A WAL read transaction pins the actual SQLite snapshot for a photo wall.
/// No whole-library decoding, file renaming, or copy without WAL is involved.
private nonisolated final class SQLiteReadConnection: @unchecked Sendable {
    let database: OpaquePointer
    let onClose: @Sendable () -> Void
    let pinsLiveIndex: Bool
    var selectedPlaceMembership: [String: Set<String>] = [:]
    var countCursor: SQLitePhotoCountCursor?
    init(_ database: OpaquePointer, pinsLiveIndex: Bool = true, onClose: @escaping @Sendable () -> Void) {
        self.database = database
        self.pinsLiveIndex = pinsLiveIndex
        self.onClose = onClose
    }
    deinit {
        countCursor = nil
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(database)
        onClose()
    }
}

extension SQLiteTravelIndexStore {
    func photoReadSnapshot() throws -> SQLiteTravelIndexStore {
        guard readerRevisions.count < 2 else { throw TravelIndexStoreError.database(AppLocalization.string("error.index.close_wall", defaultValue: "Close the current photo list first.")) }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw TravelIndexStoreError.database(AppLocalization.string("error.index.snapshot", defaultValue: "Unable to read the photo snapshot.")) }
        do {
            try execute(database, "BEGIN DEFERRED TRANSACTION")
            _ = try readMetadata(database) // Establish the read version now, before the first page.
            // Initialized through an isolated factory below, never shared as a raw pointer.
            let lease = UUID()
            readerRevisions[lease] = metadataRevision
            return SQLiteTravelIndexStore(databaseURL: databaseURL, connection: SQLiteReadConnection(database) { [weak self] in
                Task { await self?.releaseReader(lease) }
            }, localeIdentifier: localeIdentifier, hidesTransitPhotos: transitFilterEnabled)
        } catch { sqlite3_close_v2(database); throw error }
    }

    private func releaseReader(_ id: UUID) { readerRevisions[id] = nil }

    func canActivateMetadata() -> Bool {
        // At most one full replacement while an older wall is open. Sparse
        // label writes continue, but repeated scans cannot grow the WAL by
        // another whole photo library indefinitely.
        readerRevisions.values.allSatisfy { $0 >= metadataRevision }
    }


    func loadPreparationProgress() throws -> LibraryPreparationProgress? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try withDatabase(create: false) { db in
            guard let value = try stateValue("progress", table: "preparation_state", db: db),
                  let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(LibraryPreparationProgress.self, from: data)
        }
    }

    func savePreparationProgress(_ progress: LibraryPreparationProgress) throws {
        let data = try JSONEncoder().encode(progress)
        try withDatabase(create: true) { db in
            try setState("progress", value: String(decoding: data, as: UTF8.self), table: "preparation_state", db: db)
        }
    }

    /// Publish new display labels against the same visits and permission scope in one transaction.
    func refreshLocale(from previous: String, to key: ScanPublicationKey, catalog: JourneyPlaceCatalog) throws -> Bool {
        guard key.changesOnlyLocale(from: previous), key.catalog == catalog.version,
              AppLocalization.supportedLocale(for: Locale(identifier: key.locale)).identifier == localeIdentifier else { return false }
        return try withDatabase(create: false) { db in
            try transaction(db) {
                guard try stateValue("authorization", table: "library_sync", db: db) == previous else { return false }
                let locale = Locale(identifier: key.locale)
                for place in try readPlacesRaw(db) {
                    try Task.checkCancellation()
                    let label = try catalog.label(place.coordinate, locale: locale)
                    try writeLabelCache(PlaceLabelBasis.key(place.coordinate), label: label,
                                        attempts: 0, retry: nil, terminal: !label.isComplete, db: db)
                }
                try setState("authorization", value: key.serialized(), table: "library_sync", db: db)
                return true
            }
        }
    }

    func loadSyncState() throws -> LibrarySyncState {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return LibrarySyncState() }
        return try withDatabase(create: false) { db in
            let token = try stateValue("token", table: "library_sync", db: db).flatMap { Data(base64Encoded: $0) }
            let full = try stateValue("full_check", table: "library_sync", db: db).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let check = try stateValue("last_check", table: "library_sync", db: db).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            return LibrarySyncState(token: token, lastFullCheck: full, lastCheck: check,
                                    authorization: try stateValue("authorization", table: "library_sync", db: db))
        }
    }

    func commitUnchanged(from baseline: LibrarySyncState, changes: LibraryChangeResult, authorization: String) throws -> Bool {
        guard changes.changedAssetCount == 0, let token = baseline.token, baseline.authorization == authorization else { return false }
        return try withDatabase(create: false) { db in
            try transaction(db) {
                guard try stateValue("run", table: "preparation_state", db: db) == nil,
                      try stateValue("token", table: "library_sync", db: db) == token.base64EncodedString(),
                      try stateValue("authorization", table: "library_sync", db: db) == authorization,
                      try stateValue("source_photo_count", table: "metadata", db: db) == String(changes.sourcePhotoCount)
                else { return false }
                try saveSync(token: changes.token, fullCheck: false, authorization: authorization, db: db)
                return true
            }
        }
    }

    func matchesSourcePhotoCount(_ count: Int) throws -> Bool {
        try withDatabase(create: false) { db in
            try stateValue("source_photo_count", table: "metadata", db: db) == String(count)
        }
    }

    func beginMetadataScan(copyCurrent: Bool) throws -> UUID {
        let run = UUID()
        try withDatabase(create: true) { db in
            try transaction(db) {
                try cacheExistingLabels(db)
                try execute(db, "DELETE FROM scan_photos; DELETE FROM scan_cover_updates")
                if copyCurrent {
                    try execute(db, """
                        INSERT INTO scan_photos(
                            id, latitude, longitude, creation_date, pixel_width, pixel_height,
                            favorite, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                        )
                        SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height,
                               favorite, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                        FROM photos
                        """)
                }
                try setState("run", value: run.uuidString, table: "preparation_state", db: db)
            }
        }
        return run
    }

    /// Returns whether geography/time/membership changed (as opposed to a favorite or image edit).
    func stageMetadata(_ batch: PhotoMetadataBatch, run: UUID) throws -> Bool {
        try Task.checkCancellation()
        return try withDatabase(create: true) { db in
            try checkRun(run, db: db)
            return try transaction(db) {
                let read = try prepare(db, "SELECT latitude, longitude, creation_date FROM scan_photos WHERE id = ?")
                let delete = try prepare(db, "DELETE FROM scan_photos WHERE id = ?")
                let insert = try prepare(db, """
                    INSERT INTO scan_photos(
                        id, latitude, longitude, creation_date, pixel_width, pixel_height,
                        favorite, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                    latitude=excluded.latitude, longitude=excluded.longitude, creation_date=excluded.creation_date,
                    pixel_width=excluded.pixel_width, pixel_height=excluded.pixel_height, favorite=excluded.favorite,
                    media_kind=excluded.media_kind, duration=excluded.duration,
                    altitude=excluded.altitude, horizontal_accuracy=excluded.horizontal_accuracy, vertical_accuracy=excluded.vertical_accuracy
                    """)
                defer { sqlite3_finalize(read); sqlite3_finalize(delete); sqlite3_finalize(insert) }
                var structural = false
                let replacements = Set(batch.records.map(\.id))
                for id in batch.removedIDs where !replacements.contains(id) {
                    try bind(id, to: delete, at: 1, database: db)
                    try stepDone(delete, database: db)
                    structural = structural || sqlite3_changes(db) > 0
                    reset(delete)
                }
                for photo in batch.records {
                    try Task.checkCancellation()
                    guard photo.coordinate.isValid else { throw TravelIndexStoreError.invalidSnapshot }
                    try bind(photo.id, to: read, at: 1, database: db)
                    let status = sqlite3_step(read)
                    guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError(db) }
                    if status == SQLITE_DONE || sqlite3_column_double(read, 0) != photo.coordinate.latitude
                        || sqlite3_column_double(read, 1) != photo.coordinate.longitude
                        || sqlite3_column_double(read, 2) != photo.creationDate.timeIntervalSince1970 { structural = true }
                    reset(read)
                    try bind(photo.id, to: insert, at: 1, database: db)
                    sqlite3_bind_double(insert, 2, photo.coordinate.latitude)
                    sqlite3_bind_double(insert, 3, photo.coordinate.longitude)
                    sqlite3_bind_double(insert, 4, photo.creationDate.timeIntervalSince1970)
                    sqlite3_bind_int64(insert, 5, Int64(photo.pixelWidth)); sqlite3_bind_int64(insert, 6, Int64(photo.pixelHeight))
                    sqlite3_bind_int(insert, 7, photo.isFavorite ? 1 : 0)
                    sqlite3_bind_int(insert, 8, Int32(photo.mediaKind.rawValue))
                    sqlite3_bind_double(insert, 9, photo.duration)
                    bindOptional(photo.altitudeMeters, to: insert, at: 10)
                    bindOptional(photo.horizontalAccuracyMeters, to: insert, at: 11)
                    bindOptional(photo.verticalAccuracyMeters, to: insert, at: 12)
                    try stepDone(insert, database: db); reset(insert)
                }
                return structural
            }
        }
    }

    func stagedPhotoCount(run: UUID) throws -> Int {
        try withDatabase(create: false) { db in
            try checkRun(run, db: db)
            let statement = try prepare(db, "SELECT COUNT(*) FROM scan_photos")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(db) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func removedStagedAssets(run: UUID, after id: String = "", limit: Int = 256) throws -> [String] {
        try withDatabase(create: false) { db in
            try checkRun(run, db: db)
            let statement = try prepare(db, """
                SELECT id FROM photos WHERE id > ? AND NOT EXISTS (SELECT 1 FROM scan_photos s WHERE s.id = photos.id)
                ORDER BY id LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id, to: statement, at: 1, database: db)
            sqlite3_bind_int64(statement, 2, Int64(min(256, limit)))
            var ids: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return ids }
                guard status == SQLITE_ROW else { throw databaseError(db) }
                if let id = textColumn(statement, at: 0) { ids.append(id) }
            }
        }
    }

    /// Scan input is already durable. Build derived tables and activate them in
    /// one transaction; existing WAL readers keep their old, consistent snapshot.
    func activateMetadata(run: UUID, sourcePhotoCount: Int, token: Data, fullCheck: Bool,
                          authorization: String, configuration: TravelClusteringConfiguration, catalog: JourneyPlaceCatalog? = nil,
                          progress: @Sendable (Int, [TravelPlace]) -> Void) throws -> TravelIndex {
        try Task.checkCancellation()
        let activated = try withDatabase(create: false) { db in
            try checkRun(run, db: db)
            return try transaction(db) {
                var clusterer = StreamingTravelClusterer(configuration: configuration)
                var places: [TravelPlace] = []
                let locale = Locale(identifier: localeIdentifier)
                var labels: [GeoCoordinate: PlaceDisplayLabel] = [:]
                var previousLabels: [GeoCoordinate: PlaceDisplayLabel] = [:]
                if let catalog,
                   let key = try? JSONDecoder().decode(ScanPublicationKey.self, from: Data(authorization.utf8)),
                   key.visitGroupingVersion == StreamingTravelClusterer.publicationVersion,
                   try key.canReuseGeography(from: stateValue("authorization", table: "library_sync", db: db)) {
                    // Each published photo was resolved independently before it
                    // joined its visit. An unchanged GPS can reuse that identity.
                    for place in try readPlacesRaw(db) {
                        try Task.checkCancellation()
                        let label = try cachedLabel(PlaceLabelBasis.key(place.coordinate), db: db)
                        if label?.sourceVersion == catalog.version { previousLabels[place.coordinate] = label }
                    }
                }
                let previousCoordinateColumns = previousLabels.isEmpty ? "NULL, NULL" : "p.latitude, p.longitude"
                let previousMembership = previousLabels.isEmpty ? "" : """
                    LEFT JOIN photos old ON old.id = s.id AND old.latitude = s.latitude AND old.longitude = s.longitude
                    LEFT JOIN places p ON p.id = old.place_id
                    """
                let read = try prepare(db, """
                    SELECT s.id, s.latitude, s.longitude, s.creation_date, s.pixel_width, s.pixel_height,
                           s.favorite, NULL, s.media_kind, s.duration, s.altitude, s.horizontal_accuracy, s.vertical_accuracy,
                           \(previousCoordinateColumns)
                    FROM scan_photos s
                    \(previousMembership)
                    ORDER BY s.creation_date, s.id
                    """)
                let member = try prepare(db, "UPDATE scan_photos SET group_number = ? WHERE id = ?")
                defer { sqlite3_finalize(read); sqlite3_finalize(member) }
                var count = 0
                var lastEmission = Date.distantPast
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(read)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw databaseError(db) }
                    let photo = try photoRecord(from: read, database: db)
                    if let catalog, labels[photo.coordinate] == nil {
                        let previousLabel: PlaceDisplayLabel?
                        if sqlite3_column_type(read, 13) != SQLITE_NULL {
                            let previousCoordinate = GeoCoordinate(latitude: sqlite3_column_double(read, 13),
                                                                  longitude: sqlite3_column_double(read, 14))
                            previousLabel = previousLabels[previousCoordinate]
                        } else {
                            previousLabel = nil
                        }
                        labels[photo.coordinate] = try previousLabel ?? catalog.label(photo.coordinate, locale: locale)
                    }
                    if let place = clusterer.append(photo, label: labels[photo.coordinate]) { places.append(place) }
                    sqlite3_bind_int64(member, 1, Int64(clusterer.position))
                    try bind(photo.id, to: member, at: 2, database: db)
                    try stepDone(member, database: db); reset(member)
                    count += 1
                    if Date().timeIntervalSince(lastEmission) >= 0.5 {
                        progress(count, Array(places.suffix(24)))
                        lastEmission = Date()
                    }
                }
                if let place = clusterer.place { places.append(place) }
                // The persisted labels are the same ones that formed the visit
                // memberships. Publish both atomically within this transaction.
                if catalog != nil {
                    try execute(db, "DELETE FROM place_label_cache")
                    for place in places {
                        try Task.checkCancellation()
                        guard let label = labels[place.coordinate] else { throw LibraryPreparationError.saveFailed }
                        let basis = PlaceLabelBasis.key(place.coordinate)
                        try writeLabelCache(basis, label: label, attempts: 0, retry: nil,
                                            terminal: !label.isComplete, db: db)
                    }
                } else {
                    try cacheExistingLabels(db)
                    places = try reuseLabels(places, db: db)
                }
                let index = TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
                                        generatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                                        sourcePhotoCount: sourcePhotoCount, locatedPhotoCount: count, places: places,
                                        journeys: StreamingTravelClusterer.journeys(places, configuration: configuration))
                _ = try invalidateStagedCoverUpdates(db)
                if fullCheck {
                    // Without a continuous change history even a metadata-identical photo may be edited.
                    try execute(db, "DELETE FROM visit_covers")
                } else {
                    try captureCoverMembers(db)
                }
                try execute(db, "DELETE FROM photo_locations; DELETE FROM photos; DELETE FROM journey_places; DELETE FROM journeys; DELETE FROM places; DELETE FROM metadata")
                try writeMetadata(index, to: db)
                try writePlaces(places, to: db)
                try writeJourneys(index.journeys, to: db)
                try execute(db, """
                    INSERT INTO photos(
                        id, latitude, longitude, creation_date, pixel_width, pixel_height,
                        favorite, media_kind, duration, place_id, latitude_cell, longitude_cell,
                        altitude, horizontal_accuracy, vertical_accuracy
                    )
                    SELECT s.id, s.latitude, s.longitude, s.creation_date, s.pixel_width, s.pixel_height,
                           s.favorite, s.media_kind, s.duration, p.id,
                           CAST((s.latitude + 90) / 10 AS INTEGER), CAST((s.longitude + 180) / 10 AS INTEGER),
                           s.altitude, s.horizontal_accuracy, s.vertical_accuracy
                    FROM scan_photos s JOIN places p ON p.position = s.group_number;
                    INSERT INTO photo_locations SELECT rowid, latitude, latitude, longitude, longitude FROM photos;
                    DELETE FROM scan_photos;
                    """)
                try rebuildTransitClassification(db)
                if !fullCheck { try discardChangedVisitCovers(db) }
                try saveSync(token: token, fullCheck: fullCheck, authorization: authorization, db: db)
                try setState("run", value: nil, table: "preparation_state", db: db)
                progress(count, Array(places.suffix(24)))
                return index
            }
        }
        metadataRevision += 1
        return try readCurrentSummary() ?? activated
    }

    /// A delta without structural changes updates display metadata and the safe
    /// cursor atomically, preserving clustering and all current labels.
    func commitDisplayChanges(run: UUID, token: Data, sourcePhotoCount: Int, authorization: String) throws -> TravelIndex? {
        var changedPhotos = false
        var receivedPhotoEdits = false
        try withDatabase(create: false) { db in
            try checkRun(run, db: db)
            try transaction(db) {
                receivedPhotoEdits = try invalidateStagedCoverUpdates(db)
                try execute(db, """
                    UPDATE photos SET
                        pixel_width = (SELECT pixel_width FROM scan_photos s WHERE s.id = photos.id),
                        pixel_height = (SELECT pixel_height FROM scan_photos s WHERE s.id = photos.id),
                        favorite = (SELECT favorite FROM scan_photos s WHERE s.id = photos.id),
                        media_kind = (SELECT media_kind FROM scan_photos s WHERE s.id = photos.id),
                        duration = (SELECT duration FROM scan_photos s WHERE s.id = photos.id),
                        altitude = (SELECT altitude FROM scan_photos s WHERE s.id = photos.id),
                        horizontal_accuracy = (SELECT horizontal_accuracy FROM scan_photos s WHERE s.id = photos.id),
                        vertical_accuracy = (SELECT vertical_accuracy FROM scan_photos s WHERE s.id = photos.id)
                    WHERE EXISTS (SELECT 1 FROM scan_photos s WHERE s.id = photos.id
                        AND (s.pixel_width != photos.pixel_width OR s.pixel_height != photos.pixel_height
                            OR s.favorite != photos.favorite OR s.media_kind != photos.media_kind
                            OR s.duration != photos.duration OR s.altitude IS NOT photos.altitude
                            OR s.horizontal_accuracy IS NOT photos.horizontal_accuracy
                            OR s.vertical_accuracy IS NOT photos.vertical_accuracy));
                    """)
                changedPhotos = sqlite3_changes(db) > 0
                if changedPhotos {
                    try execute(db, """
                    UPDATE places SET cover_asset_id = (
                        SELECT id FROM photos WHERE place_id = places.id
                        ORDER BY ((CASE WHEN pixel_width >= pixel_height THEN 2000000000 ELSE 0 END)
                          + (CASE WHEN favorite = 1 THEN 4000000000 ELSE 0 END)
                          + MIN(pixel_width * pixel_height, 1999999999)) DESC,
                          creation_date ASC, id ASC LIMIT 1
                    );
                    """)
                    // A horizontal-accuracy edit can change a neighboring visit's transit eligibility.
                    // Snapshot only hidden IDs. The active members and their visit assignments are stable here.
                    try execute(db, "CREATE TEMP TABLE old_hidden_for_covers AS SELECT asset_id FROM transit_hidden")
                    try rebuildTransitClassification(db)
                    try execute(db, """
                        DELETE FROM visit_covers WHERE filter_transit = 1 AND place_id IN (
                            SELECT p.place_id FROM (
                                SELECT asset_id FROM old_hidden_for_covers EXCEPT SELECT asset_id FROM transit_hidden
                            ) h JOIN photos p ON p.id = h.asset_id
                            UNION ALL
                            SELECT p.place_id FROM (
                                SELECT asset_id FROM transit_hidden EXCEPT SELECT asset_id FROM old_hidden_for_covers
                            ) h JOIN photos p ON p.id = h.asset_id
                        )
                        """)
                }
                try execute(db, "DELETE FROM scan_photos")
                try setState("source_photo_count", value: String(sourcePhotoCount), table: "metadata", db: db)
                try saveSync(token: token, fullCheck: false, authorization: authorization, db: db)
                try setState("run", value: nil, table: "preparation_state", db: db)
            }
        }
        if changedPhotos {
            metadataRevision += 1
            spatialPageKeys = nil; spatialCandidateBatch = nil; collectionPageKeys = nil
        } else if receivedPhotoEdits {
            visitCoverGeneration &+= 1
        }
        // Reuse the summary reader without awaiting another actor operation.
        return try readCurrentSummary()
    }

    private func readCurrentSummary() throws -> TravelIndex? {
        try withDatabase(create: false) { db in
            let metadata = try readMetadata(db)
            guard let date = metadata["generated_at"].flatMap(Double.init) else { return nil }
            return TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(timeIntervalSince1970: date),
                               sourcePhotoCount: Int(metadata["source_photo_count"] ?? "0") ?? 0,
                               locatedPhotoCount: Int(metadata["located_photo_count"] ?? "0") ?? 0,
                               places: try readPlaces(db), journeys: try readJourneys(db),
                               hiddenTransitPhotoCount: try hiddenTransitCount(db), transitFilteringApplied: transitFilterEnabled, transitRevision: try transitRevision(db))
        }
    }

    func placeSummariesForReading() throws -> [TravelPlace] {
        try withDatabase(create: false) { try readPlaces($0) }
    }

    func invalidateLibraryBaseline() throws {
        try withDatabase(create: false) { db in try execute(db, "DELETE FROM library_sync") }
    }

    func placeLabelJobs(now: Date, limit: Int = 32) throws -> [PlaceLabelJob] {
        try withDatabase(create: false) { db in
            try cacheExistingLabels(db)
            let places = try readPlaces(db).sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate }
            let statement = try prepare(db, "SELECT attempts, retry_at, terminal FROM place_label_cache WHERE basis = ? AND locale = ?")
            defer { sqlite3_finalize(statement) }
            var jobs: [PlaceLabelJob] = []
            for place in places where !PlaceDisplayLabel(place: place).isComplete {
                try bind(PlaceLabelBasis.key(place.coordinate), to: statement, at: 1, database: db)
                try bind(localeIdentifier, to: statement, at: 2, database: db)
                let status = sqlite3_step(statement)
                guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError(db) }
                let attempts = status == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
                let retry = status == SQLITE_ROW && sqlite3_column_type(statement, 1) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)) : nil
                let terminal = status == SQLITE_ROW && sqlite3_column_int(statement, 2) != 0
                reset(statement)
                if !terminal, retry == nil || retry! <= now {
                    jobs.append(PlaceLabelJob(place: place, attempts: attempts, nextRetryAt: retry))
                }
                if jobs.count >= limit { break }
            }
            return jobs
        }
    }

    func recordLabelAttempt(
        _ place: TravelPlace,
        label: PlaceDisplayLabel?,
        attempts: Int,
        nextRetryAt: Date?,
        terminal: Bool = false
    ) throws -> TravelPlace? {
        try withDatabase(create: false) { db in
            try transaction(db) {
                let basis = PlaceLabelBasis.key(place.coordinate)
                let existing = try cachedLabel(basis, db: db)
                let old = existing ?? PlaceDisplayLabel(city: "", country: nil)
                let value = PlaceDisplayLabel(
                    city: label?.hasCity == true ? label!.city : old.city,
                    country: label?.hasCountry == true ? label!.country : old.country,
                    regionCode: label?.regionCode ?? old.regionCode,
                    source: label?.source ?? old.source,
                    sourceVersion: label?.sourceVersion ?? old.sourceVersion,
                    offlinePlaceID: label?.offlinePlaceID ?? old.offlinePlaceID
                )
                try writeLabelCache(
                    basis,
                    label: value,
                    attempts: attempts,
                    retry: nextRetryAt,
                    terminal: terminal,
                    db: db
                )
                let update = try prepare(db, "UPDATE places SET name = ?, country = ? WHERE id = ? AND latitude = ? AND longitude = ?")
                defer { sqlite3_finalize(update) }
                try bind(value.hasCity ? value.city : place.name, to: update, at: 1, database: db)
                try bind(value.country, to: update, at: 2, database: db)
                try bind(place.id, to: update, at: 3, database: db)
                sqlite3_bind_double(update, 4, place.coordinate.latitude); sqlite3_bind_double(update, 5, place.coordinate.longitude)
                try stepDone(update, database: db)
                guard sqlite3_changes(db) > 0 else { return nil }
                var result = place
                result.name = value.hasCity ? value.city : ""
                result.country = value.country
                result.regionCode = value.regionCode
                result.offlinePlaceID = value.offlinePlaceID
                return result
            }
        }
    }

    func nextLabelRetry() throws -> Date? {
        try withDatabase(create: false) { db in
            let statement = try prepare(db, "SELECT retry_at FROM place_label_cache WHERE basis = ? AND locale = ? AND complete = 0 AND terminal = 0")
            defer { sqlite3_finalize(statement) }
            var earliest: Date?
            for place in try readPlaces(db) where !PlaceDisplayLabel(place: place).isComplete {
                try bind(PlaceLabelBasis.key(place.coordinate), to: statement, at: 1, database: db)
                try bind(localeIdentifier, to: statement, at: 2, database: db)
                if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
                    let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                    earliest = min(earliest ?? date, date)
                }
                reset(statement)
            }
            return earliest
        }
    }

    func labelRetryDate(for place: TravelPlace) throws -> Date? {
        try withDatabase(create: false) { db in
            let statement = try prepare(db, "SELECT retry_at FROM place_label_cache WHERE basis = ? AND locale = ? AND complete = 0 AND terminal = 0")
            defer { sqlite3_finalize(statement) }
            try bind(PlaceLabelBasis.key(place.coordinate), to: statement, at: 1, database: db)
            try bind(localeIdentifier, to: statement, at: 2, database: db)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    func isLabelTerminal(for place: TravelPlace) throws -> Bool {
        try withDatabase(create: false) { db in
            let statement = try prepare(db, "SELECT terminal FROM place_label_cache WHERE basis = ? AND locale = ? AND complete = 0")
            defer { sqlite3_finalize(statement) }
            try bind(PlaceLabelBasis.key(place.coordinate), to: statement, at: 1, database: db)
            try bind(localeIdentifier, to: statement, at: 2, database: db)
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
        }
    }

    private func cachedLabel(_ basis: String, db: OpaquePointer) throws -> PlaceDisplayLabel? {
        try cachedLabel(basis, localeIdentifier: localeIdentifier, db: db)
    }

    private func cachedLabel(
        _ basis: String,
        localeIdentifier: String,
        db: OpaquePointer
    ) throws -> PlaceDisplayLabel? {
        let statement = try prepare(db, """
            SELECT city, country, region_code, source, source_version, offline_place_id
            FROM place_label_cache WHERE basis = ? AND locale = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(basis, to: statement, at: 1, database: db)
        try bind(localeIdentifier, to: statement, at: 2, database: db)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError(db) }
        return PlaceDisplayLabel(
            city: textColumn(statement, at: 0) ?? "",
            country: textColumn(statement, at: 1),
            regionCode: textColumn(statement, at: 2),
            source: textColumn(statement, at: 3),
            sourceVersion: textColumn(statement, at: 4),
            offlinePlaceID: textColumn(statement, at: 5)
        )
    }

    private func writeLabelCache(
        _ basis: String,
        label: PlaceDisplayLabel,
        attempts: Int,
        retry: Date?,
        terminal: Bool = false,
        db: OpaquePointer
    ) throws {
        try writeLabelCache(
            basis,
            localeIdentifier: localeIdentifier,
            label: label,
            attempts: attempts,
            retry: retry,
            terminal: terminal,
            db: db
        )
    }

    private func writeLabelCache(
        _ basis: String,
        localeIdentifier: String,
        label: PlaceDisplayLabel,
        attempts: Int,
        retry: Date?,
        terminal: Bool = false,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(db, """
            INSERT INTO place_label_cache(
                basis, locale, city, country, region_code, source, source_version,
                offline_place_id, attempts, retry_at, updated_at, complete, terminal
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(basis, locale) DO UPDATE SET city=excluded.city, country=excluded.country,
                region_code=excluded.region_code, source=excluded.source,
                source_version=excluded.source_version, offline_place_id=excluded.offline_place_id,
                attempts=MAX(place_label_cache.attempts, excluded.attempts), retry_at=excluded.retry_at,
                updated_at=excluded.updated_at, complete=excluded.complete, terminal=excluded.terminal
            WHERE place_label_cache.complete = 0 OR excluded.complete = 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(basis, to: statement, at: 1, database: db)
        try bind(localeIdentifier, to: statement, at: 2, database: db)
        try bind(label.hasCity ? label.city : "", to: statement, at: 3, database: db)
        try bind(label.country, to: statement, at: 4, database: db)
        try bind(label.regionCode, to: statement, at: 5, database: db)
        try bind(label.source, to: statement, at: 6, database: db)
        try bind(label.sourceVersion, to: statement, at: 7, database: db)
        try bind(label.offlinePlaceID, to: statement, at: 8, database: db)
        sqlite3_bind_int(statement, 9, Int32(attempts))
        if let retry, !label.isComplete { sqlite3_bind_double(statement, 10, retry.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 10) }
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 12, label.isComplete ? 1 : 0)
        sqlite3_bind_int(statement, 13, terminal && !label.isComplete ? 1 : 0)
        try stepDone(statement, database: db)
    }

    private func cacheLabels(
        _ places: [TravelPlace],
        localeIdentifier: String,
        db: OpaquePointer
    ) throws {
        for place in places {
            let label = PlaceDisplayLabel(place: place)
            guard label.hasCity || label.hasCountry else { continue }
            try writeLabelCache(
                PlaceLabelBasis.key(place.coordinate),
                localeIdentifier: localeIdentifier,
                label: PlaceDisplayLabel(
                    city: label.city,
                    country: label.country,
                    regionCode: place.regionCode
                ),
                attempts: 0,
                retry: nil,
                db: db
            )
        }
    }

    private func cacheExistingLabels(_ db: OpaquePointer) throws {
        for place in try readPlaces(db) where PlaceDisplayLabel(place: place).isComplete {
            let basis = PlaceLabelBasis.key(place.coordinate)
            if try cachedLabel(basis, db: db)?.isComplete != true {
                try writeLabelCache(basis, label: PlaceDisplayLabel(place: place), attempts: 0, retry: nil, db: db)
            }
        }
    }

    private func reuseLabels(_ places: [TravelPlace], db: OpaquePointer) throws -> [TravelPlace] {
        try places.map { place in
            var result = place
            // The legacy columns are retained only as a migration bridge. A
            // label from another language must never leak into this launch.
            result.name = ""
            result.country = nil
            result.regionCode = nil
            if let label = try cachedLabel(PlaceLabelBasis.key(place.coordinate), db: db) {
                if label.hasCity { result.name = label.city }
                if label.hasCountry { result.country = label.country }
                result.regionCode = label.regionCode
                result.offlinePlaceID = label.offlinePlaceID
            }
            return result
        }
    }

    private func saveSync(token: Data, fullCheck: Bool, authorization: String, db: OpaquePointer) throws {
        try setState("token", value: token.base64EncodedString(), table: "library_sync", db: db)
        try setState("last_check", value: String(Date().timeIntervalSince1970), table: "library_sync", db: db)
        if fullCheck { try setState("full_check", value: String(Date().timeIntervalSince1970), table: "library_sync", db: db) }
        try setState("authorization", value: authorization, table: "library_sync", db: db)
    }

    private func checkRun(_ run: UUID, db: OpaquePointer) throws {
        guard try stateValue("run", table: "preparation_state", db: db) == run.uuidString else { throw LibraryPreparationError.staleRun }
    }

    private func stateValue(_ key: String, table: String, db: OpaquePointer) throws -> String? {
        let statement = try prepare(db, "SELECT value FROM \(table) WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1, database: db)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError(db) }
        return status == SQLITE_ROW ? textColumn(statement, at: 0) : nil
    }

    private func setState(_ key: String, value: String?, table: String, db: OpaquePointer) throws {
        let statement = try prepare(db, value == nil ? "DELETE FROM \(table) WHERE key = ?" : "INSERT OR REPLACE INTO \(table)(key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1, database: db)
        if let value { try bind(value, to: statement, at: 2, database: db) }
        try stepDone(statement, database: db)
    }

    private func transaction<T>(_ db: OpaquePointer, _ work: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try work()
            try Task.checkCancellation()
            try execute(db, "COMMIT")
            return result
        } catch { try? execute(db, "ROLLBACK"); throw error }
    }
}

extension SQLiteTravelIndexStore {
    /// SQL counts every eligible photo, returning at most 20 × 12 aggregate rows.
    func mapReviewClusters(placeID: String, grid: MapReviewGrid,
                           excluding: Set<String> = []) throws -> [MapReviewCluster] {
        try mapReviewClusters(placeIDs: [placeID], grid: grid, excluding: excluding)
    }

    func mapReviewClusters(placeIDs: [String], grid: MapReviewGrid,
                           excluding: Set<String> = []) throws -> [MapReviewCluster] {
        try Task.checkCancellation()
        return try withDatabase(create: false) { db in
            try prepareSelectedPlaces(placeIDs, table: "review_places", database: db)
            try prepareSelectedPlaces(Array(excluding), table: "review_excluded", database: db)
            sqlite3_progress_handler(db, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            let statement = try prepare(db, mapReviewCTE + """
                , ranked AS (
                    SELECT *, ROW_NUMBER() OVER (
                        PARTITION BY cell_y, cell_x ORDER BY creation_date DESC, id ASC
                    ) AS cover_rank FROM review_cells
                )
                SELECT cell_x, cell_y, COUNT(*),
                       MAX(CASE WHEN cover_rank = 1 THEN latitude END),
                       MAX(CASE WHEN cover_rank = 1 THEN longitude END),
                       MIN(latitude), MAX(latitude), MIN(review_lon), MAX(review_lon),
                       MAX(CASE WHEN cover_rank = 1 THEN id END)
                FROM ranked GROUP BY cell_y, cell_x ORDER BY cell_y, cell_x
                """)
            defer { sqlite3_finalize(statement) }
            bindMapReview(grid: grid, statement: statement)
            var clusters: [MapReviewCluster] = []
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return clusters }
                guard status == SQLITE_ROW else { throw databaseError(db) }
                clusters.append(MapReviewCluster(
                    cell: MapReviewCell(column: Int(sqlite3_column_int(statement, 0)), row: Int(sqlite3_column_int(statement, 1))),
                    count: Int(sqlite3_column_int64(statement, 2)),
                    coordinate: GeoCoordinate(latitude: sqlite3_column_double(statement, 3),
                                              longitude: MapReviewGrid.normalizedLongitude(sqlite3_column_double(statement, 4))),
                    south: sqlite3_column_double(statement, 5), north: sqlite3_column_double(statement, 6),
                    west: sqlite3_column_double(statement, 7), east: sqlite3_column_double(statement, 8),
                    assetID: textColumn(statement, at: 9)))
            }
        }
    }

    func mapReviewPage(placeID: String, selection: MapReviewSelection?, offset: Int,
                       excluding: Set<String> = []) throws -> PhotoQueryPage {
        try Task.checkCancellation()
        return try withDatabase(create: false) { db in
            try prepareSelectedPlaces([placeID], table: "review_places", database: db)
            try prepareSelectedPlaces(Array(excluding), table: "review_excluded", database: db)
            sqlite3_progress_handler(db, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            // These are internal integer keys from a frozen grid.
            let cells = selection?.cells.sorted().map { "(cell_x = \($0.column) AND cell_y = \($0.row))" }.joined(separator: " OR ")
            let predicate = cells.map { $0.isEmpty ? "0" : "(\($0))" } ?? "1"
            let statement = try prepare(db, mapReviewCTE + """
                SELECT id, latitude, longitude, creation_date, pixel_width,
                       pixel_height, favorite, place_id, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM review_cells WHERE \(predicate)
                ORDER BY creation_date DESC, id ASC LIMIT 49 OFFSET ?8
                """)
            defer { sqlite3_finalize(statement) }
            bindMapReview(grid: selection?.grid ?? .world(around: 0), statement: statement)
            let start = max(0, offset)
            sqlite3_bind_int64(statement, 8, Int64(start))
            var records: [PhotoAssetRecord] = []
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return PhotoQueryPage(records: records, nextOffset: nil) }
                guard status == SQLITE_ROW else { throw databaseError(db) }
                if records.count == 48 { return PhotoQueryPage(records: records, nextOffset: start + 48) }
                records.append(try photoRecord(from: statement, database: db))
            }
        }
    }

    private var mapReviewCTE: String {
        """
        WITH review_source AS (
            SELECT *, CASE WHEN longitude - ?1 > 180 THEN longitude - 360
                           WHEN longitude - ?1 < -180 THEN longitude + 360
                           ELSE longitude END AS review_lon
            FROM photos WHERE place_id IN (SELECT id FROM review_places) AND \(transitPredicate())
                AND id NOT IN (SELECT id FROM review_excluded)
        ), review_cells AS (
            SELECT *, MIN(?6 - 1, CAST((review_lon - ?4) / (?5 - ?4) * ?6 AS INTEGER)) AS cell_x,
                      MIN(?7 - 1, CAST((latitude - ?2) / (?3 - ?2) * ?7 AS INTEGER)) AS cell_y
            FROM review_source WHERE latitude BETWEEN ?2 AND ?3 AND review_lon BETWEEN ?4 AND ?5
        )
        """
    }

    private func bindMapReview(grid: MapReviewGrid, statement: OpaquePointer) {
        sqlite3_bind_double(statement, 1, grid.referenceLongitude)
        for (position, value) in [grid.south, grid.north, grid.west, grid.east].enumerated() {
            sqlite3_bind_double(statement, Int32(position + 2), value)
        }
        sqlite3_bind_int(statement, 6, Int32(grid.columns))
        sqlite3_bind_int(statement, 7, Int32(grid.rows))
    }

    private func transitPredicate(alias: String = "photos") -> String {
        transitFilterEnabled
            ? "NOT EXISTS (SELECT 1 FROM transit_hidden h WHERE h.asset_id = \(alias).id)"
            : "1"
    }

    private func optionalDouble(_ statement: OpaquePointer, at column: Int32) -> Double? {
        guard column < sqlite3_column_count(statement), sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, column)
        return value.isFinite ? value : nil
    }

    private func bindOptional(_ value: Double?, to statement: OpaquePointer, at column: Int32) {
        if let value, value.isFinite { sqlite3_bind_double(statement, column, value) }
        else { sqlite3_bind_null(statement, column) }
    }

    private func ensureTransitSchema(_ db: OpaquePointer) throws {
        let upgrading = try stateValue("schema_version", table: "metadata", db: db) == "5"
        let missing = try !hasColumn("altitude", in: "photos", database: db)
        if missing || upgrading {
            try transaction(db) {
                for table in ["photos", "scan_photos"] {
                    for column in ["altitude", "horizontal_accuracy", "vertical_accuracy"] {
                        if try !hasColumn(column, in: table, database: db) {
                            try execute(db, "ALTER TABLE \(table) ADD COLUMN \(column) REAL")
                        }
                    }
                }
                if upgrading {
                    // Keep usable photos/labels. Refresh lightweight PhotoKit metadata later
                    // to discover altitude; sparse/speed rules work with the existing index now.
                    try execute(db, "DELETE FROM library_sync; DELETE FROM scan_photos; DELETE FROM preparation_state WHERE key = 'run'")
                    try execute(db, "UPDATE metadata SET value = '6' WHERE key = 'schema_version'")
                }
            }
        }
        try execute(db, """
            CREATE TABLE IF NOT EXISTS transit_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS transit_hidden (asset_id TEXT PRIMARY KEY, reason INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS transit_place_summaries (
                place_id TEXT PRIMARY KEY, start_date REAL NOT NULL, end_date REAL NOT NULL,
                photo_count INTEGER NOT NULL, cover_asset_id TEXT
            );
            """)
        if try stateValue("algorithm_version", table: "transit_state", db: db) != "1" {
            try transaction(db) { try rebuildTransitClassification(db) }
        }
    }

    /// Two linear metadata passes and indexed group/cover lookups; never loads all assets.
    /// Caller owns the write transaction, so all queries/counts see one coherent version.
    private func rebuildTransitClassification(_ db: OpaquePointer) throws {
        let classifier = TransitPhotoClassifier()
        let configuration = classifier.configuration
        try execute(db, """
            DELETE FROM transit_hidden;
            DELETE FROM transit_place_summaries;
            INSERT INTO transit_hidden(asset_id, reason)
            SELECT id, 1 FROM photos WHERE place_id IN (
                SELECT place_id FROM photos GROUP BY place_id
                HAVING COUNT(*) <= \(configuration.maximumSparseCount)
                    AND MAX(creation_date) - MIN(creation_date) BETWEEN 0 AND \(configuration.maximumSparseSpan)
                    AND MAX(favorite) = 0
            );
            """)
        let read = try prepare(db, """
            SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height,
                   favorite, place_id, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
            FROM photos ORDER BY creation_date ASC, id ASC
            """)
        let insert = try prepare(db, "INSERT OR REPLACE INTO transit_hidden(asset_id, reason) VALUES (?, ?)")
        defer { sqlite3_finalize(read); sqlite3_finalize(insert) }
        var previous: PhotoAssetRecord?
        var current: PhotoAssetRecord?
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(read)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(db) }
            let next = try photoRecord(from: read, database: db)
            if let previous, let current,
               let reason = classifier.reason(previous: previous, current: current, next: next) {
                try bind(current.id, to: insert, at: 1, database: db)
                sqlite3_bind_int(insert, 2, Int32(reason.rawValue))
                try stepDone(insert, database: db); reset(insert)
            }
            previous = current; current = next
        }
        try execute(db, """
            INSERT INTO transit_place_summaries(place_id, start_date, end_date, photo_count)
            SELECT place_id, MIN(creation_date), MAX(creation_date), COUNT(*) FROM photos
            WHERE NOT EXISTS (SELECT 1 FROM transit_hidden h WHERE h.asset_id = photos.id)
            GROUP BY place_id;
            UPDATE transit_place_summaries SET cover_asset_id = (
                SELECT id FROM photos WHERE place_id = transit_place_summaries.place_id
                AND NOT EXISTS (SELECT 1 FROM transit_hidden h WHERE h.asset_id = photos.id)
                ORDER BY creation_date DESC, id ASC LIMIT 1
            );
            """)
        try setState("algorithm_version", value: "1", table: "transit_state", db: db)
        try setState("revision", value: UUID().uuidString, table: "transit_state", db: db)
    }

    private func transitRevision(_ db: OpaquePointer) throws -> String? {
        guard transitFilterEnabled else { return nil }
        return try stateValue("revision", table: "transit_state", db: db)
    }

    private func hiddenTransitCount(_ db: OpaquePointer) throws -> Int {
        guard transitFilterEnabled else { return 0 }
        let query = try prepare(db, "SELECT COUNT(*) FROM transit_hidden")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError(db) }
        return Int(sqlite3_column_int64(query, 0))
    }

    func transitFilteringIsEnabled() -> Bool { transitFilterEnabled }

    func setTransitFiltering(_ enabled: Bool) throws -> TravelIndex? {
        guard readConnection == nil else { throw TravelIndexStoreError.invalidSnapshot }
        let previous = transitFilterEnabled
        transitFilterEnabled = enabled
        do {
            let summary = FileManager.default.fileExists(atPath: databaseURL.path) ? try readCurrentSummary() : nil
            spatialPageKeys = nil; spatialCandidateBatch = nil; collectionPageKeys = nil
            metadataRevision += 1
            return summary
        } catch {
            transitFilterEnabled = previous
            throw error
        }
    }
}

extension SQLiteTravelIndexStore: ScenicCoverStoring {
    // An upsert into the copy of the current library is a PhotoKit edit, even
    // when dates, size and favorites are identical. Process it at activation so
    // an edit received while the app was closed also invalidates pixel scores.
    private func invalidateStagedCoverUpdates(_ db: OpaquePointer) throws -> Bool {
        try execute(db, """
            DELETE FROM visit_covers WHERE place_id IN (
                SELECT p.place_id FROM scan_cover_updates u CROSS JOIN photos p ON p.id = u.asset_id);
            DELETE FROM cover_analysis WHERE asset_id IN (SELECT asset_id FROM scan_cover_updates);
            DELETE FROM scan_cover_updates;
            """)
        return sqlite3_changes(db) > 0
    }

    // Updated PhotoKit assets have already invalidated their old visits. A
    // regroup can also move unchanged photos between visits or change transit
    // membership. Compare only the visible IDs of visits that still have covers.
    private var coverMembersSQL: String {
        """
        SELECT p.place_id, p.id FROM visit_covers c CROSS JOIN photos p ON p.place_id = c.place_id
        WHERE c.filter_transit = 0 OR NOT EXISTS (SELECT 1 FROM transit_hidden h WHERE h.asset_id = p.id)
        """
    }

    private func captureCoverMembers(_ db: OpaquePointer) throws {
        try execute(db, """
            CREATE TEMP TABLE cover_members_before (
                place_id TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (place_id, id)
            ) WITHOUT ROWID;
            INSERT INTO cover_members_before \(coverMembersSQL);
            """)
    }

    private func discardChangedVisitCovers(_ db: OpaquePointer) throws {
        try execute(db, """
            DELETE FROM visit_covers WHERE place_id IN (
                SELECT p.place_id FROM (\(coverMembersSQL)) p
                WHERE NOT EXISTS (SELECT 1 FROM cover_members_before b WHERE b.place_id = p.place_id AND b.id = p.id)
                UNION ALL
                SELECT b.place_id FROM cover_members_before b JOIN visit_covers c ON c.place_id = b.place_id
                WHERE NOT EXISTS (SELECT 1 FROM photos p WHERE p.id = b.id AND p.place_id = b.place_id
                    AND (c.filter_transit = 0 OR NOT EXISTS (SELECT 1 FROM transit_hidden h WHERE h.asset_id = p.id)))
            )
            """)
    }

    func savedVisitCovers(for visits: [String], keeping displayed: [String: String] = [:], excluding excluded: Set<String>) throws -> [String: PhotoPreviewMetadata] {
        guard !visits.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        return try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT c.place_id, p.id, p.pixel_width, p.pixel_height, 0 AS displayed
                FROM visit_covers c JOIN photos p ON p.id = c.asset_id AND p.place_id = c.place_id
                WHERE c.place_id IN (SELECT value FROM json_each(?1))
                  AND c.strategy = ?2 AND c.filter_transit = ?3 AND c.expires > ?4 AND \(transitPredicate(alias: "p"))
                  AND c.place_id NOT IN (SELECT q.place_id FROM json_each(?5) e JOIN photos q ON q.id = e.value WHERE q.place_id IS NOT NULL)
                UNION ALL
                SELECT p.place_id, p.id, p.pixel_width, p.pixel_height, 1 AS displayed
                FROM json_each(?6) held JOIN photos p ON p.place_id = held.key AND p.id = held.value
                WHERE p.place_id IN (SELECT value FROM json_each(?1))
                  AND \(transitPredicate(alias: "p")) AND p.id NOT IN (SELECT value FROM json_each(?5))
                ORDER BY displayed
                """)
            defer { sqlite3_finalize(statement) }
            try bind(String(decoding: try JSONEncoder().encode(visits), as: UTF8.self), to: statement, at: 1, database: db)
            sqlite3_bind_int(statement, 2, Self.visitCoverStrategy)
            sqlite3_bind_int(statement, 3, transitFilterEnabled ? 1 : 0)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            try bind(String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self), to: statement, at: 5, database: db)
            try bind(String(decoding: try JSONEncoder().encode(displayed), as: UTF8.self), to: statement, at: 6, database: db)
            var result: [String: PhotoPreviewMetadata] = [:]
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let place = textColumn(statement, at: 0), let asset = textColumn(statement, at: 1) else { throw TravelIndexStoreError.corrupt }
                result[place] = PhotoPreviewMetadata(assetID: asset, pixelWidth: Int(sqlite3_column_int64(statement, 2)),
                                                     pixelHeight: Int(sqlite3_column_int64(statement, 3)))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError(db) }
            return result
        }
    }

    func saveVisitCover(_ asset: String, for visit: String, revision: String, generation: UInt64,
                        expires: Date, excluding excluded: Set<String>) throws {
        try Task.checkCancellation()
        guard generation == visitCoverGeneration else { return }
        try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                INSERT OR REPLACE INTO visit_covers(place_id,asset_id,filter_transit,strategy,expires)
                SELECT place_id, id, ?3, ?4, ?5 FROM photos
                WHERE place_id = ?1 AND id = ?2 AND \(transitPredicate())
                  AND (SELECT value FROM metadata WHERE key = 'generated_at') = ?6
                  AND NOT EXISTS (SELECT 1 FROM json_each(?7) e JOIN photos q ON q.id = e.value WHERE q.place_id = ?1)
                """)
            defer { sqlite3_finalize(statement) }
            try bind(visit, to: statement, at: 1, database: db)
            try bind(asset, to: statement, at: 2, database: db)
            sqlite3_bind_int(statement, 3, transitFilterEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 4, Self.visitCoverStrategy)
            sqlite3_bind_double(statement, 5, expires.timeIntervalSince1970)
            try bind(revision, to: statement, at: 6, database: db)
            try bind(String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self), to: statement, at: 7, database: db)
            try stepDone(statement, database: db)
        }
    }

    func journeyContainsChangedMembers(_ changed: Set<String>, places: [String]) throws -> Bool {
        guard !changed.isEmpty else { return false }
        return try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT 1 FROM json_each(?1) AS changed JOIN photos ON photos.id = changed.value
                WHERE photos.place_id IN (SELECT value FROM json_each(?2)) LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            try bind(String(decoding: try JSONEncoder().encode(changed), as: UTF8.self), to: statement, at: 1, database: db)
            try bind(String(decoding: try JSONEncoder().encode(places), as: UTF8.self), to: statement, at: 2, database: db)
            let status = sqlite3_step(statement)
            switch status {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw TravelIndexStoreError.invalidSnapshot
            }
        }
    }

    func visibleJourneyCover(_ assetID: String, in placeIDs: Set<String>) throws -> PhotoAssetRecord? {
        guard !placeIDs.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id,
                       media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM photos WHERE id = ? AND \(transitPredicate())
                """)
            defer { sqlite3_finalize(statement) }
            try bind(assetID, to: statement, at: 1, database: db)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let photo = try photoRecord(from: statement, database: db)
            guard let placeID = photo.placeID, placeIDs.contains(placeID) else { return nil }
            return photo
        }
    }
    /// The ordered index cursor stops on its first eligible row. A large transient
    /// exclusion set is shared by all seeks, without copying or sorting it per visit.
    private func firstCover(_ statement: OpaquePointer, in db: OpaquePointer, excluding excluded: Set<String>) throws -> PhotoAssetRecord? {
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if !excluded.isEmpty, let id = textColumn(statement, at: 0), excluded.contains(id) { continue }
                return try photoRecord(from: statement, database: db)
            case SQLITE_DONE: return nil
            default: throw databaseError(db)
            }
        }
    }

    /// One indexed latest-visible seek per member visit. Keep metadata for the visits,
    /// never walk or retain the full trip to discover its newest eligible capture.
    func journeyCoverWindow(for places: [TravelPlace], excluding excluded: Set<String>) throws -> JourneyCoverWindow? {
        guard !places.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id,
                       media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM photos WHERE place_id = ?1 AND \(transitPredicate())
                ORDER BY creation_date DESC, id ASC LIMIT ?2
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 2, Int64(excluded.count) + 1)
            let ownsTransaction = sqlite3_get_autocommit(db) != 0
            if ownsTransaction { try execute(db, "BEGIN DEFERRED TRANSACTION") }
            defer { if ownsTransaction { try? execute(db, "ROLLBACK") } }
            var latest: PhotoAssetRecord?
            var ends: [String: Date] = [:]
            for place in places {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                try bind(place.id, to: statement, at: 1, database: db)
                guard let photo = try firstCover(statement, in: db, excluding: excluded) else { continue }
                ends[place.id] = photo.creationDate
                if let previous = latest, previous.creationDate > photo.creationDate ||
                    (previous.creationDate == photo.creationDate && previous.id < photo.id) { continue }
                latest = photo
            }
            guard let latest else { return nil }
            let lower = latest.creationDate.addingTimeInterval(-JourneyCoverWindow.duration)
            return JourneyCoverWindow(latest: latest, visibleVisitEnds: ends.filter { $0.value >= lower })
        }
    }

    /// The single-visit city path adds a metadata pass for repeat shooting scenes.
    /// Country and multi-visit collections use only the bounded temporal index seeks.
    func scenicCoverCandidates(for places: [TravelPlace], journeyWindow: JourneyCoverWindow? = nil,
                              priorityVisitID: String? = nil,
                              excluding excluded: Set<String> = []) throws -> [PhotoAssetRecord] {
        guard let journeyWindow else {
            let dispersed = try variedScenicCoverCandidates(for: places, priorityVisitID: priorityVisitID, excluding: excluded)
            guard places.count == 1, let priorityVisitID, priorityVisitID == places[0].id, !dispersed.isEmpty else {
                return dispersed
            }
            return try sceneSampler(for: priorityVisitID, excluding: excluded).primaries(from: dispersed)
        }
        let visits = ScenicCoverPolicy.visits(from: places.filter { journeyWindow.visibleVisitEnds[$0.id] != nil })
        guard !visits.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try withDatabase(create: false) { db in
            let ownsTransaction = sqlite3_get_autocommit(db) != 0
            if ownsTransaction { try execute(db, "BEGIN DEFERRED TRANSACTION") }
            defer { if ownsTransaction { try? execute(db, "ROLLBACK") } }
            let fields = "id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id, media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy"
            let base = "SELECT \(fields) FROM photos WHERE \(transitPredicate()) AND place_id = ?1 AND creation_date BETWEEN ?3 AND ?4"
            let newest = try prepare(db, base + " AND creation_date <= ?2 ORDER BY creation_date DESC, id ASC LIMIT ?5")
            let favorite = try prepare(db, base + " AND favorite = 1 ORDER BY creation_date DESC, id ASC LIMIT ?5")
            defer { sqlite3_finalize(newest); sqlite3_finalize(favorite) }
            for statement in [newest, favorite] {
                sqlite3_bind_double(statement, 3, journeyWindow.dates.lowerBound.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, journeyWindow.dates.upperBound.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 5, Int64(excluded.count) + 1)
            }
            var output: [PhotoAssetRecord] = []
            var seen = Set<String>()
            for (index, place) in visits.enumerated() {
                let budget = ScenicCoverPolicy.candidateLimit / visits.count
                    + (index < ScenicCoverPolicy.candidateLimit % visits.count ? 1 : 0)
                for slot in 0..<budget {
                    try Task.checkCancellation()
                    let statement = slot == 1 ? favorite : newest
                    sqlite3_reset(statement)
                    try bind(place.id, to: statement, at: 1, database: db)
                    if slot != 1 {
                        // Include the latest and earliest visits/photos, not just
                        // a page of adjacent exposures from the latest burst.
                        let fraction = slot == 0 ? 1.0 : 1 - Double(slot - 1) / Double(budget - 2)
                        let start = max(place.startDate, journeyWindow.dates.lowerBound)
                        let end = journeyWindow.visibleVisitEnds[place.id] ?? place.endDate
                        let date = slot == 0 ? end.timeIntervalSince1970 :
                            start.timeIntervalSince1970 + max(0, end.timeIntervalSince(start)) * fraction
                        sqlite3_bind_double(statement, 2, date)
                    }
                    if let record = try firstCover(statement, in: db, excluding: excluded), seen.insert(record.id).inserted {
                        output.append(record)
                    }
                }
            }
            return output
        }
    }

    func sceneStrengths(for photos: [PhotoAssetRecord], excluding excluded: Set<String>) throws -> [String: Float] {
        guard let visit = photos.first?.placeID, photos.allSatisfy({ $0.placeID == visit }),
              FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        let sampler = try sceneSampler(for: visit, excluding: excluded)
        return Dictionary(photos.map { ($0.id, sampler.strength(for: $0.id)) }, uniquingKeysWith: max)
    }

    private func sceneSampler(for visit: String, excluding excluded: Set<String>) throws -> ScenicCoverSceneSampler {
        if let cached = coverSceneCache, cached.visit == visit, cached.excluded == excluded { return cached.sampler }
        let sampler = try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id,
                       media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM photos WHERE place_id = ?1 AND \(transitPredicate()) ORDER BY creation_date ASC, id ASC
                """)
            defer { sqlite3_finalize(statement) }
            try bind(visit, to: statement, at: 1, database: db)
            var sampler = ScenicCoverSceneSampler()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                let photo = try photoRecord(from: statement, database: db)
                if !excluded.contains(photo.id) { sampler.append(photo) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError(db) }
            return sampler
        }
        coverSceneCache = (visit, excluded, sampler)
        return sampler
    }

    private func variedScenicCoverCandidates(for places: [TravelPlace], priorityVisitID: String?,
                                           excluding excluded: Set<String>) throws -> [PhotoAssetRecord] {
        let priority = places.first { $0.id == priorityVisitID }
        let visits: [TravelPlace]
        if let priority {
            let older = places.filter { $0.id != priority.id && $0.endDate <= priority.endDate }
                .sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate }
            visits = [priority] + older.prefix(ScenicCoverPolicy.visitLimit - 1)
        } else {
            visits = ScenicCoverPolicy.visits(from: places)
        }
        guard !visits.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try withDatabase(create: false) { db in
            let ownsTransaction = sqlite3_get_autocommit(db) != 0
            if ownsTransaction { try execute(db, "BEGIN DEFERRED TRANSACTION") }
            defer { if ownsTransaction { try? execute(db, "ROLLBACK") } }
            let base = """
                SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id,
                       media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM photos WHERE \(transitPredicate()) AND place_id = ?1 AND media_kind != 2
                    AND creation_date BETWEEN ?2 AND ?3
                """
            let newest = try prepare(db, base + " ORDER BY creation_date DESC, id ASC LIMIT ?4")
            defer { sqlite3_finalize(newest) }
            let oldest = try prepare(db, base + " ORDER BY creation_date ASC, id ASC LIMIT ?4")
            defer { sqlite3_finalize(oldest) }
            let favorite = try prepare(db, base + " AND favorite = 1 ORDER BY creation_date DESC, id ASC LIMIT ?4")
            defer { sqlite3_finalize(favorite) }
            for statement in [newest, oldest, favorite] {
                sqlite3_bind_int64(statement, 4, Int64(excluded.count) + 1)
            }

            var samplers = visits.map { ScenicCoverVisitSampler(start: $0.startDate, end: $0.endDate) }
            var result: [PhotoAssetRecord] = []
            var seen = Set<String>()
            let limit = ScenicCoverPolicy.candidateLimit

            func append(from index: Int, store: isolated SQLiteTravelIndexStore) throws -> Bool {
                let id = visits[index].id
                while let candidate = try samplers[index].next(read: { range, order in
                    let statement: OpaquePointer
                    switch order {
                    case .newest: statement = newest
                    case .oldest: statement = oldest
                    case .favorite: statement = favorite
                    }
                    sqlite3_reset(statement)
                    try store.bind(id, to: statement, at: 1, database: db)
                    sqlite3_bind_double(statement, 2, range.lowerBound.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 3, range.upperBound.timeIntervalSince1970)
                    return try store.firstCover(statement, in: db, excluding: excluded)
                }) {
                    guard seen.insert(candidate.id).inserted else { continue }
                    result.append(candidate)
                    return true
                }
                return false
            }

            if priority != nil, visits.count > 1 {
                while result.count < ScenicCoverPolicy.recentVisitBudget, try append(from: 0, store: self) {}
            }
            let hasReservedVisit = priority != nil && visits.count > 1
            var remaining = Array(samplers.indices.dropFirst(hasReservedVisit ? 1 : 0))
            while result.count < limit, !remaining.isEmpty {
                let index = remaining.removeFirst()
                if try append(from: index, store: self) { remaining.append(index) }
            }
            if hasReservedVisit {
                while result.count < limit, try append(from: 0, store: self) {}
            }
            return result
        }
    }

    /// The Mac cover experiment measures proximity in hours plus distance in three-kilometer units.
    /// The first anchor wins an exact tie, preserving the primary sampler's order.
    private struct CoverBackup {
        let photo: PhotoAssetRecord
        let distance: Double

        func precedes(_ other: Self) -> Bool {
            if distance != other.distance { return distance < other.distance }
            if photo.isFavorite != other.photo.isFavorite { return photo.isFavorite }
            return photo.id < other.photo.id
        }
    }

    /// Cursor through only visits with unreadable primary previews. Keep two alternatives per
    /// missing primary. Every primary participates in ownership so a filled scene cannot donate its burst.
    func scenicCoverBackups(for primaries: [PhotoAssetRecord], missing: Set<String>,
                           excluding excluded: Set<String>) throws -> [String: [PhotoAssetRecord]] {
        guard !missing.isEmpty, !primaries.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        let anchors = Dictionary(grouping: primaries, by: \.placeID)
        let primaryIDs = Set(primaries.map(\.id))
        return try withDatabase(create: false) { db in
            let ownsTransaction = sqlite3_get_autocommit(db) != 0
            if ownsTransaction { try execute(db, "BEGIN DEFERRED TRANSACTION") }
            defer { if ownsTransaction { try? execute(db, "ROLLBACK") } }
            let statement = try prepare(db, """
                SELECT id, latitude, longitude, creation_date, pixel_width, pixel_height, favorite, place_id,
                       media_kind, duration, altitude, horizontal_accuracy, vertical_accuracy
                FROM photos WHERE place_id = ?1 AND media_kind != 2 AND \(transitPredicate())
                """)
            defer { sqlite3_finalize(statement) }

            var backups: [String: [CoverBackup]] = [:]
            for (placeID, visit) in anchors {
                guard let placeID, visit.contains(where: { missing.contains($0.id) }) else { continue }
                sqlite3_reset(statement)
                try bind(placeID, to: statement, at: 1, database: db)
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    defer { status = sqlite3_step(statement) }
                    guard let id = textColumn(statement, at: 0), !primaryIDs.contains(id), !excluded.contains(id) else { continue }
                    let latitude = sqlite3_column_double(statement, 1)
                    let longitude = sqlite3_column_double(statement, 2)
                    let date = sqlite3_column_double(statement, 3)
                    let longitudeScale = cos(latitude * .pi / 180)
                    var closest: PhotoAssetRecord?
                    var bestDistance = Double.infinity
                    for anchor in visit {
                        let hours = abs(date - anchor.creationDate.timeIntervalSince1970) / 3_600
                        guard hours < bestDistance else { continue }
                        let kilometers = 111 * hypot(latitude - anchor.coordinate.latitude,
                            (longitude - anchor.coordinate.longitude) * longitudeScale)
                        let distance = hours + kilometers / 3
                        if distance < bestDistance { closest = anchor; bestDistance = distance }
                    }
                    guard let anchor = closest, missing.contains(anchor.id) else { continue }
                    var top = backups[anchor.id, default: []]
                    if top.count == 2, bestDistance > top[1].distance { continue }
                    let candidate = CoverBackup(photo: try photoRecord(from: statement, database: db), distance: bestDistance)
                    let position = top.firstIndex { candidate.precedes($0) } ?? top.endIndex
                    guard position < 2 else { continue }
                    top.insert(candidate, at: position)
                    if top.count > 2 { top.removeLast() }
                    backups[anchor.id] = top
                }
                guard status == SQLITE_DONE else { throw databaseError(db) }
            }
            return backups.mapValues { $0.map(\.photo) }
        }
    }

    func coverAnalyses(for ids: [String], revision: String) throws -> [String: ScenicCoverAnalysis] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        return try withDatabase(create: false) { db in
            let statement = try prepare(db, """
                SELECT scenery, aesthetics, utility, largest_face, landmark
                FROM cover_analysis WHERE asset_id = ? AND source_revision = ? AND strategy_version = ?
                """)
            defer { sqlite3_finalize(statement) }
            var result: [String: ScenicCoverAnalysis] = [:]
            for id in ids.prefix(ScenicCoverPolicy.candidateLimit) {
                try Task.checkCancellation()
                reset(statement)
                try bind(id, to: statement, at: 1, database: db)
                try bind(revision, to: statement, at: 2, database: db)
                sqlite3_bind_int(statement, 3, Int32(ScenicCoverAnalysis.version))
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    result[id] = ScenicCoverAnalysis(scenery: Float(sqlite3_column_double(statement, 0)),
                        aesthetics: optionalDouble(statement, at: 1).map(Float.init),
                        isUtility: sqlite3_column_int(statement, 2) != 0,
                        largestFace: Float(sqlite3_column_double(statement, 3)),
                        landmark: Float(sqlite3_column_double(statement, 4)))
                } else if status != SQLITE_DONE { throw databaseError(db) }
            }
            return result
        }
    }

    func saveCoverAnalysis(_ analysis: ScenicCoverAnalysis, assetID: String, revision: String) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try withDatabase(create: false) { db in
            // A result from an old scan cannot repopulate a rebuilt database.
            guard try readMetadata(db)["generated_at"] == revision else { return }
            let statement = try prepare(db, """
                INSERT OR REPLACE INTO cover_analysis
                    (asset_id, source_revision, strategy_version, scenery, aesthetics, utility, largest_face, landmark)
                SELECT id, ?, ?, ?, ?, ?, ?, ? FROM photos WHERE id = ?
                """)
            defer { sqlite3_finalize(statement) }
            try bind(revision, to: statement, at: 1, database: db)
            sqlite3_bind_int(statement, 2, Int32(ScenicCoverAnalysis.version))
            sqlite3_bind_double(statement, 3, Double(analysis.scenery))
            if let score = analysis.aesthetics { sqlite3_bind_double(statement, 4, Double(score)) }
            else { sqlite3_bind_null(statement, 4) }
            sqlite3_bind_int(statement, 5, analysis.isUtility ? 1 : 0)
            sqlite3_bind_double(statement, 6, Double(analysis.largestFace))
            sqlite3_bind_double(statement, 7, Double(analysis.landmark))
            try bind(assetID, to: statement, at: 8, database: db)
            try stepDone(statement, database: db)
        }
    }

    func invalidateCoverAnalyses(for ids: Set<String>) throws {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        visitCoverGeneration &+= 1
        try withDatabase(create: false) { db in
            try transaction(db) {
                let visits = try prepare(db, """
                    DELETE FROM visit_covers WHERE place_id IN (
                        SELECT p.place_id FROM json_each(?1) e JOIN photos p ON p.id = e.value)
                    """)
                defer { sqlite3_finalize(visits) }
                try bind(String(decoding: try JSONEncoder().encode(ids), as: UTF8.self), to: visits, at: 1, database: db)
                try stepDone(visits, database: db)
                let statement = try prepare(db, "DELETE FROM cover_analysis WHERE asset_id = ?")
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    reset(statement)
                    try bind(id, to: statement, at: 1, database: db)
                    try stepDone(statement, database: db)
                }
            }
        }
    }
}

extension SQLiteTravelIndexStore {
    /// A wall must still page through its original snapshot after the show.
    /// Detach its pinned read transaction to a private, automatically deleted
    /// SQLite file so hours of playback cannot hold back the live index.
    func detachWallForSlideshow() throws {
        guard let source = readConnection, source.pinsLiveIndex else { return }
        var handle: OpaquePointer?
        guard sqlite3_open("", &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw EarthSlideshowPlanError.unavailable
        }
        do {
            guard let backup = sqlite3_backup_init(handle, "main", source.database, "main") else {
                throw databaseError(handle)
            }
            do {
                defer { sqlite3_backup_finish(backup) }
                while true {
                    try Task.checkCancellation()
                    let result = sqlite3_backup_step(backup, 256)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_OK else { throw databaseError(handle) }
                }
            }
            try Task.checkCancellation()
            readConnection = SQLiteReadConnection(handle, pinsLiveIndex: false, onClose: {})
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    /// A private read version already contains the date/ID index. Page it directly
    /// so the opening does not wait for all photos to be decoded and re-encoded.
    func slideshowSnapshot(for places: [TravelPlace]?, excluding: Set<String>) throws -> IndexedSlideshowSnapshot {
        guard readConnection != nil else { throw TravelIndexStoreError.invalidSnapshot }
        try detachWallForSlideshow()
        let visits = try places ?? placeSummariesForReading()
        return IndexedSlideshowSnapshot(reader: self, places: visits,
            members: Set(visits.map(\.id)), excluding: excluding)
    }

    func slideshowPage(_ request: SlideshowPageSequence.Request, limit: Int,
                       excluding: Set<String>) throws -> SlideshowSnapshot.Page {
        let size = min(48, max(1, limit))
        return try withDatabase(create: false) { db in
            let hasExclusions = !excluding.isEmpty
            if hasExclusions, readConnection?.selectedPlaceMembership["slideshow_excluded"] != excluding {
                try prepareSelectedPlaces(Array(excluding), table: "slideshow_excluded", database: db)
            }
            sqlite3_progress_handler(db, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            let stmt = try prepare(db, """
                SELECT id,latitude,longitude,creation_date,pixel_width,pixel_height,favorite,place_id,
                       media_kind,duration,altitude,horizontal_accuracy,vertical_accuracy FROM photos
                WHERE place_id = ? AND \(transitPredicate())
                \(hasExclusions ? "AND id NOT IN (SELECT id FROM slideshow_excluded)" : "")
                \(request.after == nil ? "" : "AND (creation_date,id) > (?,?)")
                ORDER BY creation_date,id LIMIT ?
                """)
            defer { sqlite3_finalize(stmt) }
            try bind(request.visit.id, to: stmt, at: 1, database: db)
            if let cursor = request.after {
                sqlite3_bind_double(stmt, 2, cursor.date.timeIntervalSince1970)
                try bind(cursor.id, to: stmt, at: 3, database: db)
            }
            sqlite3_bind_int(stmt, sqlite3_bind_parameter_count(stmt), Int32(size + 1))
            var rows: [PhotoAssetRecord] = []
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return .init(records: rows, next: nil) }
                guard status == SQLITE_ROW else { throw databaseError(db) }
                if rows.count == size, let last = rows.last { return .init(records: rows, next: .init(last)) }
                rows.append(try photoRecord(from: stmt, database: db))
            }
        }
    }
}
