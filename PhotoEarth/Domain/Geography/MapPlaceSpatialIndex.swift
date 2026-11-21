import Foundation

/// Built only for a new index revision. Keep all places in 20° spatial buckets;
/// each settled view admits the two newest actually visible places per 2° cell.
/// The drawing budget is then distributed across geography first.
nonisolated struct MapPlaceSpatialIndex {
    private struct Cell: Hashable, Comparable {
        let latitude: Int
        let longitude: Int
        static func < (lhs: Cell, rhs: Cell) -> Bool {
            lhs.latitude == rhs.latitude ? lhs.longitude < rhs.longitude : lhs.latitude < rhs.latitude
        }
        init(_ coordinate: GeoCoordinate, size: Double) {
            latitude = min(Int(floor((coordinate.latitude + 90) / size)), Int(180 / size) - 1)
            longitude = Int(floor(((coordinate.longitude == 180 ? -180 : coordinate.longitude) + 180) / size))
        }
        var center: GeoCoordinate {
            GeoCoordinate(latitude: Double(latitude) * 20 - 80, longitude: Double(longitude) * 20 - 170)
        }
    }
    private var buckets: [Cell: [TravelPlace]] = [:]
    private var placesByID: [String: TravelPlace] = [:]

    init(places: [TravelPlace] = []) {
        let sorted = places.filter { $0.coordinate.isValid }.sorted {
            $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate
        }
        for place in sorted where placesByID[place.id] == nil {
            placesByID[place.id] = place
            buckets[Cell(place.coordinate, size: 20), default: []].append(place)
        }
    }

    func representatives(in viewport: EarthViewport? = nil, limit: Int = 180,
                         preferredPlaceID: String? = nil) -> [TravelPlace] {
        guard limit > 0 else { return [] }
        let keys = buckets.keys.filter { cell in
            guard let viewport else { return true }
            // A 20° square fits inside a 15° spherical cap at every latitude.
            return GlobeMath.angularDistanceDegrees(from: viewport.center, to: cell.center)
                <= viewport.angularRadius + 15
        }.sorted()
        let lists = keys.map { key in
            // Density follows visibility. Newer points outside the viewport
            // cannot hide an older visible point in the same geographic cell.
            // Round robin sees at most two candidates per cell even when one
            // bucket contains thousands of visits at a single location.
            var counts: [Cell: Int] = [:]
            return buckets[key, default: []].filter { place in
                let cell = Cell(place.coordinate, size: 2)
                guard counts[cell, default: 0] < 2,
                      viewport?.contains(place.coordinate) ?? true else { return false }
                counts[cell, default: 0] += 1
                return true
            }
        }
        var selected: [TravelPlace] = []
        var seen = Set<String>()
        var cellCounts: [Cell: Int] = [:]
        func append(_ place: TravelPlace) {
            let cell = Cell(place.coordinate, size: 2)
            guard selected.count < limit, !seen.contains(place.id), cellCounts[cell, default: 0] < 2 else { return }
            selected.append(place); seen.insert(place.id); cellCounts[cell, default: 0] += 1
        }
        if let preferredPlaceID, let preferred = placesByID[preferredPlaceID] { append(preferred) }
        // Round robin avoids spending the entire budget on a recent continent.
        var position = 0
        while selected.count < limit {
            var advanced = false
            for list in lists where position < list.count {
                append(list[position]); advanced = true
            }
            if !advanced { break }
            position += 1
        }
        return selected
    }

    static func needsRefresh(from old: EarthViewport?, to new: EarthViewport) -> Bool {
        guard let old else { return true }
        let ratio = new.angularRadius / old.angularRadius
        return ratio < 0.77 || ratio > 1.3
            || GlobeMath.angularDistanceDegrees(from: old.center, to: new.center)
                > max(0.5, min(old.angularRadius, new.angularRadius) * 0.16)
    }
}
