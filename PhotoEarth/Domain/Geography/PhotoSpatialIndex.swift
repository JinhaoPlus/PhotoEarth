import Foundation

nonisolated struct PhotoSpatialBounds: Sendable {
    let minimumLatitude: Double
    let maximumLatitude: Double
    let longitudeRanges: [ClosedRange<Double>]

    init(viewport: EarthViewport) {
        let radius = min(max(viewport.angularRadius, 2), 94)
        minimumLatitude = max(-90, viewport.center.latitude - radius)
        maximumLatitude = min(90, viewport.center.latitude + radius)

        let longitudeRadius = min(
            180,
            radius / max(abs(cos(viewport.center.latitude * .pi / 180)), 0.2)
        )
        guard longitudeRadius < 180 else {
            longitudeRanges = [-180...180]
            return
        }

        let center = Self.normalizedLongitude(viewport.center.longitude)
        let minimum = center - longitudeRadius
        let maximum = center + longitudeRadius
        if minimum < -180 {
            longitudeRanges = [(minimum + 360)...180, -180...maximum]
        } else if maximum > 180 {
            longitudeRanges = [minimum...180, -180...(maximum - 360)]
        } else {
            longitudeRanges = [minimum...maximum]
        }
    }

    private static func normalizedLongitude(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

nonisolated enum PhotoSelection {
    private struct Cell: Hashable, Sendable {
        let latitude: Int
        let longitude: Int
    }

    private struct ScoredPhoto: Sendable {
        let record: PhotoAssetRecord
        let score: Double
    }

    static func photos(
        from candidates: [PhotoAssetRecord],
        in viewport: EarthViewport,
        limit: Int
    ) -> [PhotoAssetRecord] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        let radius = min(max(viewport.angularRadius, 2), 94)
        let newestDate = candidates.map(\.creationDate).max() ?? .distantPast
        var seen = Set<String>()

        var scored = candidates.compactMap { record -> ScoredPhoto? in
            guard seen.insert(record.id).inserted, record.coordinate.isValid else { return nil }
            let distance = GlobeMath.angularDistanceDegrees(
                from: viewport.center,
                to: record.coordinate
            )
            guard distance <= radius else { return nil }

            let centrality = distance / max(radius, 1)
            let favoriteBonus = record.isFavorite ? 0.2 : 0
            let landscapeBonus = record.pixelWidth >= record.pixelHeight ? 0.07 : 0
            let ageDays = max(0, newestDate.timeIntervalSince(record.creationDate) / 86_400)
            let recencyBonus = 0.05 / (1 + ageDays / 365)
            return ScoredPhoto(
                record: record,
                score: centrality - favoriteBonus - landscapeBonus - recencyBonus
            )
        }

        scored.sort {
            if $0.score == $1.score { return $0.record.id < $1.record.id }
            return $0.score < $1.score
        }

        let diversitySize = max(2, radius / 4)
        var selected: [PhotoAssetRecord] = []
        var deferred: [PhotoAssetRecord] = []
        var countByCell: [Cell: Int] = [:]

        for candidate in scored {
            let cell = cell(for: candidate.record.coordinate, cellSize: diversitySize)
            if countByCell[cell, default: 0] < 2 {
                selected.append(candidate.record)
                countByCell[cell, default: 0] += 1
            } else {
                deferred.append(candidate.record)
            }
            if selected.count == limit { return selected }
        }

        if selected.count < limit {
            selected.append(contentsOf: deferred.prefix(limit - selected.count))
        }
        return selected
    }

    private static func cell(for coordinate: GeoCoordinate, cellSize: Double) -> Cell {
        let latitudeCellCount = Int(ceil(180 / cellSize))
        let longitudeCellCount = Int(ceil(360 / cellSize))
        let latitude = min(
            max(Int(floor((coordinate.latitude + 90) / cellSize)), 0),
            latitudeCellCount - 1
        )
        var normalizedLongitude = coordinate.longitude.truncatingRemainder(dividingBy: 360)
        if normalizedLongitude >= 180 { normalizedLongitude -= 360 }
        if normalizedLongitude < -180 { normalizedLongitude += 360 }
        let longitude = min(
            max(Int(floor((normalizedLongitude + 180) / cellSize)), 0),
            longitudeCellCount - 1
        )
        return Cell(latitude: latitude, longitude: longitude)
    }
}

/// A compact in-memory implementation used only by fixtures and tests. Production
/// libraries use the SQLite RTree store so this structure never owns tens of thousands
/// of records during normal app launch.
nonisolated struct PhotoSpatialIndex: Sendable {
    private struct Cell: Hashable, Sendable {
        let latitude: Int
        let longitude: Int
    }

    private let cellSize: Double
    private let latitudeCellCount: Int
    private let longitudeCellCount: Int
    private let records: [PhotoAssetRecord]
    private let recordIndicesByCell: [Cell: [Int]]

    init(records: [PhotoAssetRecord], cellSize: Double = 10) {
        let safeCellSize = min(max(cellSize, 2), 30)
        self.cellSize = safeCellSize
        latitudeCellCount = Int(ceil(180 / safeCellSize))
        longitudeCellCount = Int(ceil(360 / safeCellSize))
        self.records = records

        var buckets: [Cell: [Int]] = [:]
        for (index, record) in records.enumerated() where record.coordinate.isValid {
            buckets[Self.cell(
                for: record.coordinate,
                cellSize: safeCellSize,
                latitudeCellCount: latitudeCellCount,
                longitudeCellCount: longitudeCellCount
            ), default: []].append(index)
        }
        recordIndicesByCell = buckets
    }

    func photos(in viewport: EarthViewport, limit: Int = 18) -> [PhotoAssetRecord] {
        guard limit > 0, !records.isEmpty else { return [] }
        let bounds = PhotoSpatialBounds(viewport: viewport)
        let latitudeCells = (0..<latitudeCellCount).filter { cellIndex in
            let center = -90 + (Double(cellIndex) + 0.5) * cellSize
            return center >= bounds.minimumLatitude - cellSize / 2
                && center <= bounds.maximumLatitude + cellSize / 2
        }
        let longitudeCells = (0..<longitudeCellCount).filter { cellIndex in
            let center = -180 + (Double(cellIndex) + 0.5) * cellSize
            return bounds.longitudeRanges.contains { range in
                center >= range.lowerBound - cellSize / 2
                    && center <= range.upperBound + cellSize / 2
            }
        }

        var candidates: [PhotoAssetRecord] = []
        for latitudeCell in latitudeCells {
            for longitudeCell in longitudeCells {
                for recordIndex in recordIndicesByCell[
                    Cell(latitude: latitudeCell, longitude: longitudeCell)
                ] ?? [] {
                    candidates.append(records[recordIndex])
                }
            }
        }
        return PhotoSelection.photos(from: candidates, in: viewport, limit: limit)
    }

    private func cell(for coordinate: GeoCoordinate) -> Cell {
        Self.cell(
            for: coordinate,
            cellSize: cellSize,
            latitudeCellCount: latitudeCellCount,
            longitudeCellCount: longitudeCellCount
        )
    }

    private static func cell(
        for coordinate: GeoCoordinate,
        cellSize: Double,
        latitudeCellCount: Int,
        longitudeCellCount: Int
    ) -> Cell {
        let latitude = min(
            max(Int(floor((coordinate.latitude + 90) / cellSize)), 0),
            latitudeCellCount - 1
        )
        var normalizedLongitude = coordinate.longitude.truncatingRemainder(dividingBy: 360)
        if normalizedLongitude >= 180 { normalizedLongitude -= 360 }
        if normalizedLongitude < -180 { normalizedLongitude += 360 }
        let longitude = min(
            max(Int(floor((normalizedLongitude + 180) / cellSize)), 0),
            longitudeCellCount - 1
        )
        return Cell(latitude: latitude, longitude: longitude)
    }
}
