import Foundation

/// Evidence of repeated deliberate shooting within one visit. GPS movement is the only
/// viewpoint signal available; camera heading isn't part of the photo index.
nonisolated struct ScenicCoverSceneSampler {
    private static let sceneRadius = 160.0
    private static let eventCap = 6
    private static let eventGap: TimeInterval = 120
    private static let movementGap: TimeInterval = 15
    private static let viewpointDistance = 40.0

    private struct Cell: Hashable {
        let x, y, z: Int
    }

    private struct Scene {
        let center: SIMD3<Double>
        var lastPhotoDate: Date
        var eventPosition: SIMD3<Double>
        var eventDate: Date
        var eventAccuracy: Double
        // One photograph per independent event. Retain the first five events plus
        // the most recent. Additional frames in a burst can only upgrade its favorite.
        var representatives: [PhotoAssetRecord?]
        var strength: Float { Float(representatives.count - 1) / Float(eventCap - 1) }
    }

    private var cells: [Cell: [Int]] = [:]
    private var scenes: [Scene] = []
    private var membership: [String: Int] = [:]

    init() {}

    init(photos: [PhotoAssetRecord]) {
        for photo in photos.sorted(by: {
            $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate < $1.creationDate
        }) { append(photo) }
    }

    private static func position(_ coordinate: GeoCoordinate) -> SIMD3<Double> {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let radius = 6_371_000.0
        let horizontal = radius * cos(latitude)
        return SIMD3(horizontal * cos(longitude), horizontal * sin(longitude), radius * sin(latitude))
    }

    private static func squaredLength(_ vector: SIMD3<Double>) -> Double {
        vector.x * vector.x + vector.y * vector.y + vector.z * vector.z
    }

    /// The SQLite path streams eligible records in (creationDate, id) order.
    mutating func append(_ photo: PhotoAssetRecord) {
        guard photo.coordinate.isValid,
              photo.creationDate.timeIntervalSince1970.isFinite, membership[photo.id] == nil else { return }
        let point = Self.position(photo.coordinate)
        let radius = Self.sceneRadius
        let cell = Cell(x: Int(floor(point.x / radius)), y: Int(floor(point.y / radius)), z: Int(floor(point.z / radius)))
        var nearest: Int?
        var best = radius * radius
        // Chord-space bins keep the same neighborhood across the date line and near the poles.
        for x in (cell.x - 1)...(cell.x + 1) {
            for y in (cell.y - 1)...(cell.y + 1) {
                for z in (cell.z - 1)...(cell.z + 1) {
                    guard let neighbors = cells[Cell(x: x, y: y, z: z)] else { continue }
                    for index in neighbors {
                        let distance = Self.squaredLength(scenes[index].center - point)
                        if distance < best || (distance == best && index < (nearest ?? .max)) {
                            best = distance
                            nearest = index
                        }
                    }
                }
            }
        }

        let cover = photo.mediaKind == .video ? nil : photo
        let accuracy = max(0, photo.horizontalAccuracyMeters ?? 0)
        guard let index = nearest else {
            let new = scenes.count
            scenes.append(Scene(center: point, lastPhotoDate: photo.creationDate, eventPosition: point,
                                eventDate: photo.creationDate, eventAccuracy: accuracy, representatives: [cover]))
            membership[photo.id] = new
            cells[cell, default: []].append(new)
            return
        }
        membership[photo.id] = index
        let pause = photo.creationDate.timeIntervalSince(scenes[index].lastPhotoDate) >= Self.eventGap
        let distance = max(Self.viewpointDistance, accuracy + scenes[index].eventAccuracy)
        let moved = photo.creationDate.timeIntervalSince(scenes[index].eventDate) >= Self.movementGap
            && Self.squaredLength(point - scenes[index].eventPosition) >= distance * distance
        scenes[index].lastPhotoDate = photo.creationDate
        if pause || moved {
            scenes[index].eventDate = photo.creationDate
            scenes[index].eventPosition = point
            scenes[index].eventAccuracy = accuracy
            if scenes[index].representatives.count == Self.eventCap { scenes[index].representatives.removeLast() }
            scenes[index].representatives.append(cover)
        } else if let cover {
            let last = scenes[index].representatives.count - 1
            if scenes[index].representatives[last] == nil || (cover.isFavorite && scenes[index].representatives[last]?.isFavorite == false) {
                scenes[index].representatives[last] = cover
            }
        }
    }

    func strength(for assetID: String) -> Float {
        membership[assetID].map { scenes[$0].strength } ?? 0
    }

    /// Preserve the original temporal anchors for three quarters of the slots.
    /// Reserve at most one quarter for scenes with repeat evidence, at most two
    /// representatives per scene from these additions. Return unused slots to the time sampler.
    func primaries(from dispersed: [PhotoAssetRecord], limit: Int = ScenicCoverPolicy.candidateLimit) -> [PhotoAssetRecord] {
        let limit = max(0, min(limit, ScenicCoverPolicy.candidateLimit))
        let reserved = limit / 4
        let base = Array(dispersed.prefix(limit))
        guard reserved > 0 else { return base }
        var selected = Array(base.prefix(limit - reserved))
        var tail = Array(base.dropFirst(selected.count))
        func separated(_ a: PhotoAssetRecord, _ b: PhotoAssetRecord) -> Bool {
            abs(a.creationDate.timeIntervalSince(b.creationDate)) >= ScenicCoverVisitSampler.minimumSeparation
        }
        var additions = 0
        let repeated = scenes.indices.filter { scenes[$0].strength > 0 }.sorted {
            let lhs = scenes[$0], rhs = scenes[$1]
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            return $0 < $1
        }
        for allowance in 1...2 {
            for index in repeated where additions < reserved && selected.count < limit {
                let represented = selected.filter { membership[$0.id] == index }
                guard represented.count < allowance else { continue }
                let eligible = scenes[index].representatives.compactMap { $0 }.filter { candidate in
                    // A replacement between two temporal anchors can displace both. Keep
                    // enough compatible anchors to fill every slot the original plan filled.
                    selected.allSatisfy { separated($0, candidate) }
                        && selected.count + 1 + tail.filter { separated($0, candidate) }.count >= base.count
                }
                let next = eligible.max { lhs, rhs in
                    if lhs.isFavorite != rhs.isFavorite { return !lhs.isFavorite }
                    // Spread extra angles in this scene when an earlier one is already present.
                    let left = represented.map { abs(lhs.creationDate.timeIntervalSince($0.creationDate)) }.min() ?? 0
                    let right = represented.map { abs(rhs.creationDate.timeIntervalSince($0.creationDate)) }.min() ?? 0
                    if left != right { return left < right }
                    return lhs.id > rhs.id
                }
                if let next {
                    selected.append(next)
                    tail.removeAll { !separated($0, next) }
                    additions += 1
                }
            }
        }
        selected.append(contentsOf: tail.prefix(limit - selected.count))
        return selected
    }
}
