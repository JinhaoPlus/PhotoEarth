import Foundation

/// Adapts the shared geographic database to Photo Earth's scan and shelf models.
nonisolated struct JourneyPlaceCatalog: Sendable {
    let atlas: WorldCityAtlas
    var version: String { WorldCityAtlas.revision }

    static var shared: Self {
        get throws {
            guard let atlas = WorldCityAtlas.bundled else { throw CocoaError(.fileReadCorruptFile) }
            return Self(atlas: atlas)
        }
    }

    static func removeRetiredDownloads(in caches: URL = .cachesDirectory) {
        let directory = caches.appendingPathComponent("JourneyCatalog", isDirectory: true)
        for name in ["installed.json", "status.json"] {
            let file = directory.appendingPathComponent(name)
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static let citySource = "natural-earth-city-offline-v2"
    static let countrySource = "natural-earth-country-estimate-v2"
    static let unknownSource = "natural-earth-unknown-offline-v1"

    func label(_ point: GeoCoordinate, locale: Locale) throws -> PlaceDisplayLabel {
        try Task.checkCancellation()
        guard point.isValid,
              let match = try atlas.resolve(latitude: point.latitude, longitude: point.longitude, locale: locale) else {
            return PlaceDisplayLabel(city: "", country: nil, source: Self.unknownSource, sourceVersion: version)
        }
        return PlaceDisplayLabel(
            city: match.city,
            country: JourneyRegionNames.name(code: match.region, locale: locale),
            regionCode: match.region,
            source: match.id == nil ? Self.countrySource : Self.citySource,
            sourceVersion: version,
            offlinePlaceID: match.id.map { "catalog:" + $0 }
        )
    }

    func shelfTitles(for ids: Set<String>, languages: [String]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let prefix = "catalog:"
        for id in ids where id.hasPrefix(prefix) {
            let titles = atlas.localizedNames(for: String(id.dropFirst(prefix.count)), languages: languages)
            if !titles.isEmpty { result[id] = titles }
        }
        return result
    }
}
