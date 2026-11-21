import CoreLocation
import Foundation
import SQLite3

/// Immutable offline reference data. The same reader and database ship in both apps.
nonisolated final class WorldCityAtlas: @unchecked Sendable {
    static let revision = "world-atlas-20261121.6"
    static let bundled = Bundle.main.url(forResource: "WorldCityAtlas", withExtension: "sqlite")
        .flatMap(WorldCityAtlas.init(url:))

    struct Match {
        let region: String
        let city: String
        let id: String?
    }

    private final class NameRules {
        var preferred: [String: String] = [:]
    }

    private let ruleCache = NSCache<NSString, NameRules>()
    private let db: OpaquePointer

    init?(url: URL) {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            return nil
        }
        var version: OpaquePointer?
        defer { sqlite3_finalize(version) }
        guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK,
              sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) == 4 else {
            sqlite3_close_v2(connection)
            return nil
        }
        ruleCache.countLimit = 512
        db = connection
    }

    deinit { sqlite3_close(db) }

    static func languageColumn(_ locale: Locale) -> Int {
        switch locale.language.languageCode?.identifier {
        case "de": return 2
        case "es": return 3
        case "fr": return 4
        case "it": return 5
        case "pt": return 6
        case "ja": return 7
        case "zh": return locale.language.script?.identifier == "Hant" ? 9 : 8
        default: return 1
        }
    }

    static func displayName(_ names: [String], locale: Locale) -> String {
        let name = names[languageColumn(locale)]
        return name.isEmpty ? (names[1].isEmpty ? names[0] : names[1]) : name
    }

    private func nameRules(for id: String) -> NameRules {
        let cacheKey = id as NSString
        if let cached = ruleCache.object(forKey: cacheKey) { return cached }
        let rules = NameRules()
        let sql = "SELECT locale,name FROM preferred WHERE id=?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return rules }
        let complete = id.withCString { value in
            sqlite3_bind_text(stmt, 1, value, -1, nil)
            defer { sqlite3_clear_bindings(stmt) }
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let language = string(stmt, 0)
                rules.preferred[language] = string(stmt, 1)
                status = sqlite3_step(stmt)
            }
            return status == SQLITE_DONE
        }
        if complete { ruleCache.setObject(rules, forKey: cacheKey) }
        return rules
    }

    func localizedNames(for id: String, languages: [String]) -> [String: String] {
        guard let place = record(for: id) else { return [:] }
        let rules = nameRules(for: place.id)
        let regional = rules.preferred.keys.filter { tag in
            languages.contains { tag.hasPrefix($0 + "-") }
        }
        return Dictionary(uniqueKeysWithValues: Set(languages + regional).map { tag in
            (tag, displayName(place.names, rules: rules, locale: Locale(identifier: tag)))
        })
    }

    func name(for id: String, locale: Locale) -> String? {
        place(id, locale: locale)?.city
    }

    private func displayName(_ names: [String], rules: NameRules, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let column = Self.languageColumn(locale)
        let key = language == "zh" ? (column == 9 ? "zh-Hant" : "zh-Hans") : language
        if let region = locale.region?.identifier, let regional = rules.preferred[key + "-" + region] {
            return regional
        }
        return rules.preferred[key] ?? Self.displayName(names, locale: locale)
    }

    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map(String.init(cString:)) ?? ""
    }

    private func record(for id: String) -> (id: String, region: String, names: [String])? {
        let sql = """
            SELECT id,region,names FROM place
            WHERE id=COALESCE((SELECT canonical_id FROM city_alias WHERE id=?1),?1)
            """
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { return nil }
        return id.withCString { value in
            sqlite3_bind_text(query, 1, value, -1, nil)
            defer { sqlite3_clear_bindings(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { return nil }
            let names = string(query, 2).components(separatedBy: "\t")
            guard names.count == 10 else { return nil }
            return (string(query, 0), string(query, 1), names)
        }
    }

    private func place(_ id: String, region: String? = nil, locale: Locale) -> Match? {
        guard let record = record(for: id) else { return nil }
        let title = displayName(record.names, rules: nameRules(for: record.id), locale: locale)
        return Match(region: region ?? record.region, city: title, id: record.id)
    }

    private struct Town: Hashable {
        let id: String
        let region: String
    }

    /// Each little-endian ring starts with a vertex count followed by longitude/latitude in 1e-5 degrees.
    private func contains(_ bytes: UnsafeRawBufferPointer, latitude: Double, longitude: Double) -> Bool {
        let x = longitude * 100_000, y = latitude * 100_000
        var inside = false
        var offset = 0
        func number(_ index: Int) -> Int {
            Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: Int32.self)))
        }
        while offset + 4 <= bytes.count {
            let count = number(offset)
            offset += 4
            guard count >= 3, count <= (bytes.count - offset) / 8 else { return false }
            var previous = offset + (count - 1) * 8
            for current in stride(from: offset, to: offset + count * 8, by: 8) {
                let y1 = Double(number(previous + 4)), y2 = Double(number(current + 4))
                if (y1 > y) != (y2 > y) {
                    let x1 = Double(number(previous)), x2 = Double(number(current))
                    if x < x1 + (y - y1) * (x2 - x1) / (y2 - y1) { inside.toggle() }
                }
                previous = current
            }
            offset += count * 8
        }
        return inside
    }

    private func areas(latitude: Double, longitude: Double) -> (regions: Set<String>, cities: Set<Town>, reviewed: Set<Town>) {
        let sql = """
            SELECT p.region,p.place,p.shape,p.reviewed FROM area_box b JOIN polygon p ON p.id=b.id
            WHERE b.west<=?1 AND b.east>=?1 AND b.south<=?2 AND b.north>=?2
            """
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { return ([], [], []) }
        sqlite3_bind_double(query, 1, longitude)
        sqlite3_bind_double(query, 2, latitude)
        var regions = Set<String>(), cities = Set<Town>(), reviewed = Set<Town>()
        while sqlite3_step(query) == SQLITE_ROW {
            guard let data = sqlite3_column_blob(query, 2) else { continue }
            let bytes = UnsafeRawBufferPointer(start: data, count: Int(sqlite3_column_bytes(query, 2)))
            guard contains(bytes, latitude: latitude, longitude: longitude) else { continue }
            if sqlite3_column_type(query, 1) == SQLITE_NULL { regions.insert(string(query, 0)) }
            else {
                let town = Town(id: string(query, 1), region: string(query, 0))
                if sqlite3_column_int(query, 3) == 1 { reviewed.insert(town) }
                else { cities.insert(town) }
            }
        }
        return (regions, cities, reviewed)
    }

    private struct NearbyPoint {
        let id: String
        let region: String
        let distance: Double
        let seat: Bool

        func isCloser(than other: NearbyPoint?) -> Bool {
            guard let other else { return true }
            return (distance, id) < (other.distance, other.id)
        }
    }

    private let localitySQL = """
        SELECT a.place,a.lat,a.lon,0,CASE WHEN a.has_region THEN p.region ELSE '' END FROM locality_box b
        JOIN locality a ON a.id=b.id JOIN place p ON p.id=a.place
        WHERE b.east>=? AND b.west<=? AND b.north>=? AND b.south<=?
        """
    private let settlementSQL = """
        SELECT a.place,a.lat,a.lon,a.seat,p.region FROM point_box b
        JOIN anchor a ON a.id=b.id JOIN place p ON p.id=a.place
        WHERE b.east>=? AND b.west<=? AND b.north>=? AND b.south<=?
        """

    private func nearbyPoints(
        sql: String, latitude: Double, longitude: Double, latitudeLimit: Double,
        longitudeLimit: Double, radius: Double
    ) throws -> [NearbyPoint] {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let west = longitude - longitudeLimit
        let east = longitude + longitudeLimit
        var windows = [(max(-180, west), min(180, east))]
        if west < -180 { windows.append((west + 360, 180)) }
        if east > 180 { windows.append((-180, east - 360)) }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { return [] }
        var points = [NearbyPoint]()
        for (west, east) in windows {
            sqlite3_reset(query)
            sqlite3_bind_double(query, 1, west)
            sqlite3_bind_double(query, 2, east)
            sqlite3_bind_double(query, 3, latitude - latitudeLimit)
            sqlite3_bind_double(query, 4, latitude + latitudeLimit)
            while sqlite3_step(query) == SQLITE_ROW {
                try Task.checkCancellation()
                let pointLatitude = sqlite3_column_double(query, 1)
                guard abs(pointLatitude - latitude) <= latitudeLimit else { continue }
                let point = CLLocation(latitude: pointLatitude, longitude: sqlite3_column_double(query, 2))
                let distance = location.distance(from: point)
                guard distance <= radius else { continue }
                points.append(NearbyPoint(id: string(query, 0), region: string(query, 4),
                                         distance: distance, seat: sqlite3_column_int(query, 3) != 0))
            }
        }
        return points
    }

    func resolve(latitude: Double, longitude: Double, locale: Locale) throws -> Match? {
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        try Task.checkCancellation()
        let areas = areas(latitude: latitude, longitude: longitude)
        let region = areas.regions.count == 1 ? areas.regions.first : nil
        for candidates in [areas.reviewed, areas.cities] {
            if candidates.count == 1, let town = candidates.first,
               areas.regions.isEmpty || areas.regions == [town.region] {
                return place(town.id, region: town.region, locale: locale)
            }
        }

        let localityLongitudeLimit = abs(latitude) < 87 ? min(180, 4 / cos((abs(latitude) + 2) * .pi / 180)) : 180
        let localities = try nearbyPoints(sql: localitySQL, latitude: latitude, longitude: longitude,
                                         latitudeLimit: 2, longitudeLimit: localityLongitudeLimit,
                                         radius: region == nil ? 200_000 : 45_000)
        let closest = localities.min { $0.isCloser(than: $1) }
        let locality = closest.flatMap { $0.distance <= 45_000 ? $0 : nil }
        let protected = locality.flatMap { region == nil || $0.region == region ? $0 : nil }
        if let protected, protected.distance <= 4_000 {
            return place(protected.id, locale: locale)
        }

        // Only a close independent seat can change the selected city around an established city center.
        let radius = protected == nil ? 18_000.0 : 6_000.0
        let latLimit = radius / 110_000
        let cosine = cos(min(90, abs(latitude) + latLimit) * .pi / 180)
        let lonLimit = min(180, latLimit / max(cosine, 0.000001))
        let nearCityCenter = (protected?.distance ?? .infinity) <= 12_000
        let settlements = try nearbyPoints(sql: settlementSQL, latitude: latitude, longitude: longitude,
                                           latitudeLimit: latLimit, longitudeLimit: lonLimit, radius: radius)
        let settlement = settlements.lazy.filter { candidate in
            (region == nil || region == candidate.region) &&
                (!nearCityCenter || (candidate.seat && candidate.distance <= 1_500))
        }.min { $0.isCloser(than: $1) }
        if let settlement { return place(settlement.id, region: settlement.region, locale: locale) }
        if let region, protected == nil { return Match(region: region, city: "", id: nil) }
        if let locality { return place(locality.id, locale: locale) }
        guard let closest, !closest.region.isEmpty else { return nil }
        let regions = Set(localities.lazy.filter { $0.distance <= closest.distance + 50_000 }.map(\.region))
        guard regions == [closest.region] else { return nil }
        return Match(region: closest.region, city: "", id: nil)
    }
}
