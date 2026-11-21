import Foundation

/// The source wall determines only the opening view. Review then reads every
/// photo in its own current viewport from the wall's pinned database version.
nonisolated struct MapReviewOrigin: Hashable, Sendable {
    let placeIDs: [String]
    let reference: GeoCoordinate

    static func collection(placeIDs: [String], in places: [TravelPlace]) -> Self? {
        let membership = Set(placeIDs)
        guard let reference = places.first(where: { membership.contains($0.id) })?.coordinate else { return nil }
        return Self(placeIDs: membership.sorted(), reference: reference)
    }
}

/// A bounded screen-sized grid. Longitudes are unwrapped around the camera so
/// visits crossing the date line stay together. No photo records are retained.
nonisolated struct MapReviewGrid: Hashable, Sendable {
    let south: Double
    let north: Double
    let west: Double
    let east: Double
    let referenceLongitude: Double
    let columns: Int
    let rows: Int

    init(south: Double, north: Double, west: Double, east: Double,
         referenceLongitude: Double, columns: Int = 16, rows: Int = 10) {
        self.south = max(-90, min(south, north - 0.000001))
        self.north = min(90, max(north, south + 0.000001))
        self.west = west
        self.east = max(east, west + 0.000001)
        self.referenceLongitude = referenceLongitude
        self.columns = max(1, min(20, columns))
        self.rows = max(1, min(12, rows))
    }

    static func world(around longitude: Double) -> Self {
        Self(south: -90, north: 90, west: longitude - 180, east: longitude + 180,
             referenceLongitude: longitude, columns: 1, rows: 1)
    }

    func unwrappedLongitude(_ longitude: Double) -> Double {
        let difference = longitude - referenceLongitude
        return difference > 180 ? longitude - 360 : (difference < -180 ? longitude + 360 : longitude)
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result - 180
    }

    func cell(for coordinate: GeoCoordinate) -> MapReviewCell? {
        let longitude = unwrappedLongitude(coordinate.longitude)
        guard coordinate.isValid, coordinate.latitude >= south, coordinate.latitude <= north,
              longitude >= west, longitude <= east else { return nil }
        return MapReviewCell(column: min(columns - 1, Int((longitude - west) / (east - west) * Double(columns))),
                             row: min(rows - 1, Int((coordinate.latitude - south) / (north - south) * Double(rows))))
    }
}

nonisolated struct MapReviewCell: Hashable, Comparable, Sendable {
    let column: Int
    let row: Int
    var id: String { "\(column):\(row)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

nonisolated struct MapReviewCluster: Identifiable, Hashable, Sendable {
    let cell: MapReviewCell
    let count: Int
    /// The cover photo's actual GPS, never a centroid of multiple photos.
    let coordinate: GeoCoordinate
    let south: Double
    let north: Double
    /// Bounds in the grid's unwrapped longitude space.
    let west: Double
    let east: Double
    let assetID: String?
    var id: String { cell.id }

    /// Used only by the finite demo dataset, never by the real photo index.
    static func demo(records: [PhotoAssetRecord], grid: MapReviewGrid) -> [Self] {
        var groups: [MapReviewCell: [PhotoAssetRecord]] = [:]
        for record in records {
            if let cell = grid.cell(for: record.coordinate) { groups[cell, default: []].append(record) }
        }
        return groups.keys.sorted().map { cell in
            let photos = groups[cell]!.sorted {
                $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate
            }
            let latitudes = photos.map { $0.coordinate.latitude }
            let longitudes = photos.map { grid.unwrappedLongitude($0.coordinate.longitude) }
            return Self(cell: cell, count: photos.count,
                        coordinate: photos[0].coordinate,
                        south: latitudes.min()!, north: latitudes.max()!, west: longitudes.min()!, east: longitudes.max()!,
                        assetID: photos[0].id)
        }
    }
}

nonisolated struct MapReviewSelection: Hashable, Sendable {
    let grid: MapReviewGrid
    let cells: Set<MapReviewCell>
    func contains(_ coordinate: GeoCoordinate) -> Bool {
        grid.cell(for: coordinate).map(cells.contains) == true
    }
}

/// Streaming native-visible records: at most 240 cells, no whole-library IDs.
nonisolated struct MapReviewClusterAccumulator {
    let grid: MapReviewGrid
    private(set) var clusters: [MapReviewCell: MapReviewCluster] = [:]

    mutating func insert(_ photo: PhotoAssetRecord) {
        guard let cell = grid.cell(for: photo.coordinate) else { return }
        let lon = grid.unwrappedLongitude(photo.coordinate.longitude)
        let lat = photo.coordinate.latitude
        if let old = clusters[cell] {
            let count = old.count + 1
            clusters[cell] = MapReviewCluster(cell: cell, count: count,
                coordinate: old.coordinate,
                south: min(old.south, lat), north: max(old.north, lat), west: min(old.west, lon), east: max(old.east, lon),
                assetID: old.assetID)
        } else {
            clusters[cell] = MapReviewCluster(cell: cell, count: 1, coordinate: photo.coordinate,
                south: lat, north: lat, west: lon, east: lon, assetID: photo.id)
        }
    }
}
