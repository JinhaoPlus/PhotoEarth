nonisolated enum MemoryPhotoSelection {
    static let candidateLimit = 144
    static let resultLimit = 18
}

/// The native projection belongs to one stationary map state. Keep it on the
/// main actor; the database only receives the Sendable geographic viewport.
@MainActor
struct PhotoViewportSnapshot {
    let viewport: EarthViewport
    let isCurrent: () -> Bool
    let containsCoordinate: (GeoCoordinate) -> Bool
    private let wallProjectionCache: PhotoWallProjectionCache

    init(viewport: EarthViewport, isCurrent: @escaping () -> Bool,
         containsCoordinate: @escaping (GeoCoordinate) -> Bool) {
        self.viewport = viewport
        self.isCurrent = isCurrent
        self.containsCoordinate = containsCoordinate
        wallProjectionCache = PhotoWallProjectionCache()
    }

    /// This cache is owned by this frozen projection identity, and shared only
    /// by copies of this snapshot. Coordinates are never rounded to a grid.
    func containsForPhotoWall(_ coordinate: GeoCoordinate) -> Bool {
        if let cached = wallProjectionCache.value(for: coordinate) { return cached }
        let visible = viewport.contains(coordinate) && containsCoordinate(coordinate)
        wallProjectionCache.insert(visible, for: coordinate)
        return visible
    }

    var cachedWallProjectionCount: Int { wallProjectionCache.count }

    func visibleCandidates(from candidates: [PhotoAssetRecord]) -> [PhotoAssetRecord]? {
        guard isCurrent() else { return nil }
        let visible = candidates.prefix(MemoryPhotoSelection.candidateLimit).filter {
            viewport.contains($0.coordinate) && containsCoordinate($0.coordinate)
        }
        // A stale snapshot is different from an empty part of the world. The
        // caller must discard it rather than cache an empty successful query.
        return isCurrent() ? visible : nil
    }
}

/// Fixed-size FIFO: duplicate GPS values are common within a visit, while a
/// long walk must not turn an exact-count pass into a whole-library cache.
@MainActor
private final class PhotoWallProjectionCache {
    static let capacity = 1_024
    private var values: [GeoCoordinate: Bool] = [:]
    private var order: [GeoCoordinate] = []
    private var replacementIndex = 0
    var count: Int { values.count }

    func value(for coordinate: GeoCoordinate) -> Bool? { values[coordinate] }

    func insert(_ value: Bool, for coordinate: GeoCoordinate) {
        guard values[coordinate] == nil else { return }
        if order.count < Self.capacity {
            order.append(coordinate)
        } else {
            values.removeValue(forKey: order[replacementIndex])
            order[replacementIndex] = coordinate
            replacementIndex = (replacementIndex + 1) % Self.capacity
        }
        values[coordinate] = value
    }
}
