import Foundation
import SQLite3

nonisolated protocol TravelIndexStoring: Sendable {
    func load() async throws -> TravelIndex?
    func save(_ snapshot: TravelIndexSnapshot) async throws
    func photos(in viewport: EarthViewport, limit: Int) async throws -> [PhotoAssetRecord]
    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int
    ) async throws -> PhotoQueryPage
    func updatePlaceNames(_ places: [TravelPlace]) async throws
    func latestAssetID(for placeID: String) async throws -> String?
    func assetIDs(for placeID: String, offset: Int, limit: Int) async throws -> [String]
    func remove() async throws
}

nonisolated enum TravelIndexStoreError: LocalizedError {
    case incompatibleSchema
    case database(String)
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .incompatibleSchema:
            "照片索引版本不兼容，需要重新扫描。"
        case let .database(message):
            "照片索引数据库错误：\(message)"
        case .invalidSnapshot:
            "照片索引内容不完整，需要重新扫描。"
        }
    }
}

actor SQLiteTravelIndexStore: TravelIndexStoring {
    private static let cellSize = 10.0

    private let databaseURL: URL
    private let legacyJSONURLs: [URL]

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoEarth", isDirectory: true)
        databaseURL = directory.appendingPathComponent("travel-index-v3.sqlite")
        legacyJSONURLs = [1, 2].map { version in
            directory.appendingPathComponent("travel-index-v\(version).json")
        }
    }

    init(databaseURL: URL, legacyJSONURL: URL? = nil) {
        self.databaseURL = databaseURL
        legacyJSONURLs = [legacyJSONURL].compactMap { $0 }
    }

    func load() async throws -> TravelIndex? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        do {
            let index = try withDatabase(create: false) { database in
                let metadata = try readMetadata(database)
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
                    journeys: try readJourneys(database)
                )
            }
            removeLegacyFiles()
            return index
        } catch TravelIndexStoreError.incompatibleSchema {
            try removeDatabaseFiles()
            return nil
        } catch {
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

            try execute(database, "DELETE FROM photo_locations")
            try execute(database, "DELETE FROM photos")
            try execute(database, "DELETE FROM journey_places")
            try execute(database, "DELETE FROM journeys")
            try execute(database, "DELETE FROM places")
            try execute(database, "DELETE FROM metadata")

            try writeMetadata(snapshot.index, to: database)
            try writePlaces(snapshot.index.places, to: database)
            try writeJourneys(snapshot.index.journeys, to: database)
            try writePhotos(snapshot.photos, to: database)

            try execute(database, "COMMIT")
            committed = true
        }

        removeLegacyFiles()
    }

    func photos(in viewport: EarthViewport, limit: Int) async throws -> [PhotoAssetRecord] {
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        try Task.checkCancellation()
        let bounds = PhotoSpatialBounds(viewport: viewport)
        let representativesPerCell = representativeLimit(for: bounds, resultLimit: limit)

        let candidates = try withDatabase(create: false) { database in
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
                        limit: representativesPerCell
                    ))
                }
            }
            return candidates
        }

        try Task.checkCancellation()
        return PhotoSelection.photos(from: candidates, in: viewport, limit: limit)
    }

    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int
    ) async throws -> PhotoQueryPage {
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else {
            return PhotoQueryPage(records: [], nextOffset: nil)
        }
        let bounds = PhotoSpatialBounds(viewport: viewport)
        return try withDatabase(create: false) { database in
            var records: [PhotoAssetRecord] = []
            var databaseOffset = max(0, offset)
            let batchSize = max(128, limit * 2)

            while records.count < limit {
                let candidates = try readPhotoPageCandidates(
                    database,
                    bounds: bounds,
                    offset: databaseOffset,
                    limit: batchSize
                )
                guard !candidates.isEmpty else {
                    return PhotoQueryPage(records: records, nextOffset: nil)
                }

                for (candidateOffset, candidate) in candidates.enumerated() {
                    if GlobeMath.angularDistanceDegrees(
                        from: viewport.center,
                        to: candidate.coordinate
                    ) <= viewport.angularRadius {
                        records.append(candidate)
                    }
                    if records.count == limit {
                        return PhotoQueryPage(
                            records: records,
                            nextOffset: databaseOffset + candidateOffset + 1
                        )
                    }
                }
                databaseOffset += candidates.count
                if candidates.count < batchSize {
                    return PhotoQueryPage(records: records, nextOffset: nil)
                }
            }
            return PhotoQueryPage(records: records, nextOffset: databaseOffset)
        }
    }

    func assetIDs(for placeID: String, offset: Int, limit: Int) async throws -> [String] {
        guard limit > 0, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try withDatabase(create: false) { database in
            let statement = try prepare(
                database,
                """
                SELECT id
                FROM photos
                WHERE place_id = ?
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
                "UPDATE places SET name = ?, country = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            for place in places {
                try bind(place.name, to: statement, at: 1, database: database)
                try bind(place.country, to: statement, at: 2, database: database)
                try bind(place.id, to: statement, at: 3, database: database)
                try stepDone(statement, database: database)
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
                WHERE place_id = ?
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

    func remove() async throws {
        try removeDatabaseFiles()
        removeLegacyFiles()
    }

    private func withDatabase<T>(
        create: Bool,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        if create {
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
            throw TravelIndexStoreError.database("无法打开索引。")
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
                place_id TEXT REFERENCES places(id) ON DELETE SET NULL,
                latitude_cell INTEGER NOT NULL,
                longitude_cell INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS photos_place_date
                ON photos(place_id, creation_date, id);
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
            """
        )
    }

    private func writeMetadata(_ index: TravelIndex, to database: OpaquePointer) throws {
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
                favorite, place_id, latitude_cell, longitude_cell
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            try bind(photo.placeID, to: photoStatement, at: 8, database: database)
            sqlite3_bind_int64(
                photoStatement,
                9,
                Int64(floor((photo.coordinate.latitude + 90) / Self.cellSize))
            )
            sqlite3_bind_int64(
                photoStatement,
                10,
                Int64(floor((photo.coordinate.longitude + 180) / Self.cellSize))
            )
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
        let statement = try prepare(
            database,
            """
            SELECT id, name, country, latitude, longitude, start_date, end_date,
                   photo_count, cover_asset_id
            FROM places
            ORDER BY position ASC
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
                throw TravelIndexStoreError.database("地点摘要缺少必要字段。")
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
                throw TravelIndexStoreError.database("旅程摘要缺少必要字段。")
            }
            result.append(TravelJourney(
                id: id,
                title: title,
                startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                placeIDs: placeIDsByJourney[id] ?? []
            ))
        }
        return result
    }

    private func readPhotoCandidates(
        _ database: OpaquePointer,
        latitudeCell: Int,
        longitudeCell: Int,
        minimumLatitude: Double,
        maximumLatitude: Double,
        longitudeRange: ClosedRange<Double>,
        limit: Int
    ) throws -> [PhotoAssetRecord] {
        let statement = try prepare(
            database,
            """
            SELECT id, latitude, longitude, creation_date, pixel_width,
                   pixel_height, favorite, place_id
            FROM photos INDEXED BY photos_cell_quality
            WHERE latitude_cell = ?
              AND longitude_cell = ?
              AND latitude >= ?
              AND latitude <= ?
              AND longitude >= ?
              AND longitude <= ?
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
                throw TravelIndexStoreError.database("照片记录缺少标识。")
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
                placeID: textColumn(statement, at: 7)
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

    private func readPhotoPageCandidates(
        _ database: OpaquePointer,
        bounds: PhotoSpatialBounds,
        offset: Int,
        limit: Int
    ) throws -> [PhotoAssetRecord] {
        let longitudeClause = bounds.longitudeRanges
            .map { _ in
                "(location.maximum_longitude >= ? AND location.minimum_longitude <= ?)"
            }
            .joined(separator: " OR ")
        let statement = try prepare(
            database,
            """
            SELECT p.id, p.latitude, p.longitude, p.creation_date, p.pixel_width,
                   p.pixel_height, p.favorite, p.place_id
            FROM photos AS p
            JOIN photo_locations AS location ON p.rowid = location.photo_rowid
            WHERE location.maximum_latitude >= ?
              AND location.minimum_latitude <= ?
              AND (\(longitudeClause))
            ORDER BY p.creation_date DESC, p.id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, bounds.minimumLatitude)
        sqlite3_bind_double(statement, 2, bounds.maximumLatitude)
        var bindingIndex: Int32 = 3
        for range in bounds.longitudeRanges {
            sqlite3_bind_double(statement, bindingIndex, range.lowerBound)
            bindingIndex += 1
            sqlite3_bind_double(statement, bindingIndex, range.upperBound)
            bindingIndex += 1
        }
        sqlite3_bind_int64(statement, bindingIndex, Int64(limit))
        sqlite3_bind_int64(statement, bindingIndex + 1, Int64(offset))

        var result: [PhotoAssetRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(database) }
            result.append(try photoRecord(from: statement, database: database))
        }
        return result
    }

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
            throw TravelIndexStoreError.database("照片记录缺少标识。")
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
            placeID: textColumn(statement, at: 7)
        )
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorMessage)
            throw TravelIndexStoreError.database(message)
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
        TravelIndexStoreError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func removeDatabaseFiles() throws {
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
