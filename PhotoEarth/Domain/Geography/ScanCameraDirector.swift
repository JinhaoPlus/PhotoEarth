import Foundation

/// Camera storytelling is sampled independently of metadata throughput.
nonisolated struct ScanCameraDirector {
    struct Flight: Equatable {
        let place: TravelPlace
        let duration: TimeInterval
    }
    private struct Candidate {
        let place: TravelPlace
        let discoveredAt: TimeInterval
    }
    private struct Movement { let start: TimeInterval; let end: TimeInterval }
    private var startedAt: TimeInterval = 0
    private var candidates: [String: Candidate] = [:]
    private var seen: [String: String] = [:]
    private var visited: [String: TimeInterval] = [:]
    private var movements: [Movement] = []
    private var recentRegions: [String] = []
    var candidateCount: Int { candidates.count }

    mutating func begin(at time: TimeInterval, baseline: [TravelPlace] = []) {
        self = ScanCameraDirector()
        startedAt = time
        // Reopening the scene establishes a baseline, not a replay queue.
        for place in baseline {
            seen[place.id] = "\(place.photoCount):\(PlaceDisplayLabel(place: place).isComplete)"
        }
    }

    mutating func ingest(_ places: [TravelPlace], at time: TimeInterval) {
        candidates = candidates.filter { time - $0.value.discoveredAt <= 120 }
        for place in places {
            let signature = "\(place.photoCount):\(PlaceDisplayLabel(place: place).isComplete)"
            guard seen[place.id] != signature else { continue }
            seen[place.id] = signature
            let key = region(place.coordinate)
            if let old = candidates[key], old.place.photoCount > place.photoCount { continue }
            candidates[key] = Candidate(place: place, discoveredAt: time)
        }
        if candidates.count > 24 {
            let keep = candidates.sorted {
                if $0.value.discoveredAt == $1.value.discoveredAt { return $0.key < $1.key }
                return $0.value.discoveredAt > $1.value.discoveredAt
            }.prefix(24)
            candidates = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if seen.count > 512 { seen = Dictionary(uniqueKeysWithValues: candidates.values.map { ($0.place.id, "\($0.place.photoCount):\(PlaceDisplayLabel(place: $0.place).isComplete)") }) }
    }

    mutating func next(at time: TimeInterval, center: GeoCoordinate, viewport: EarthViewport?,
                       reduceMotion: Bool, enabled: Bool) -> Flight? {
        guard enabled, !reduceMotion, time - startedAt < 300 else { return nil }
        candidates = candidates.filter { time - $0.value.discoveredAt <= 120 }
        movements.removeAll { $0.end < time - 120 }
        let perMinute = time - startedAt >= 120 ? 1 : 2
        guard movements.filter({ $0.start > time - 60 }).count < perMinute else { return nil }
        if let last = movements.last {
            guard time - last.start >= 20, time - last.end >= 10 else { return nil }
        }
        let ranked = candidates.filter { key, value in
            let angle = Self.angle(center, value.place.coordinate)
            let cooldown: Double = recentRegions.dropLast().last == key ? 180 : 90
            return angle >= 12 && !(viewport?.contains(value.place.coordinate) ?? false)
                && time - (visited[key] ?? -.infinity) >= cooldown
        }.sorted { lhs, rhs in
            func score(_ item: (key: String, value: Candidate)) -> Double {
                let age = min(120, time - item.value.discoveredAt)
                let novelty = visited[item.key] == nil ? 200.0 : 0
                let density = min(20, Double(item.value.place.photoCount))
                return novelty + age + density - Self.angle(center, item.value.place.coordinate) * 0.15
            }
            let left = score(lhs), right = score(rhs)
            return left == right ? lhs.key < rhs.key : left > right
        }
        for (key, candidate) in ranked {
            let angle = Self.angle(center, candidate.place.coordinate)
            let duration = angle > 90 ? 8.0 : 5.0
            // Check every point at which the rolling-window slope changes,
            // including the proposed movement. All 30-second windows fit 10s.
            let proposed = Movement(start: time, end: time + duration)
            let all = movements + [proposed]
            let ends = all.flatMap { [$0.start, $0.end, $0.start + 30, $0.end + 30] }
            let fits = ends.allSatisfy { end in
                all.reduce(0.0) { $0 + max(0, min($1.end, end) - max($1.start, end - 30)) } <= 10.0001
            }
            guard fits else { continue }
            movements.append(proposed)
            visited[key] = time
            recentRegions.append(key)
            recentRegions = Array(recentRegions.suffix(3))
            candidates[key] = nil
            return Flight(place: candidate.place, duration: duration)
        }
        return nil
    }

    var hasRested: Bool { candidates.isEmpty }

    private func region(_ coordinate: GeoCoordinate) -> String {
        let longitude = coordinate.longitude == 180 ? -180 : coordinate.longitude
        return "\(Int(floor((coordinate.latitude + 90) / 12))):\(Int(floor((longitude + 180) / 12)))"
    }

    static func angle(_ lhs: GeoCoordinate, _ rhs: GeoCoordinate) -> Double {
        GlobeMath.distanceKilometers(from: lhs, to: rhs) / 6_371 * 180 / .pi
    }
}
