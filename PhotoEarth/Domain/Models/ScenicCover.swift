import Foundation

/// A small, disposable summary; neither pixels nor the full classification taxonomy is persisted.
nonisolated struct ScenicCoverAnalysis: Equatable, Sendable {
    static let version = 4
    let scenery: Float
    let aesthetics: Float?
    let isUtility: Bool
    let largestFace: Float
    var landmark: Float = 0

    var hasAestheticScore: Bool { aesthetics?.isFinite == true }

    var isScenic: Bool {
        scenery.isFinite && scenery >= 0.45 && !isUtility
            && largestFace.isFinite && largestFace < 0.12
            && (aesthetics.map { $0.isFinite && $0 >= -0.4 } ?? true)
    }

    func score(for photo: PhotoAssetRecord) -> Float {
        scenery + (aesthetics ?? 0) * 0.25 - largestFace * 2
            + (photo.isFavorite ? 0.06 : 0)
            + (photo.pixelWidth >= photo.pixelHeight ? 0.04 : 0)
    }
}

nonisolated enum CityCoverPolicy {
    private static let distinctiveStructures: Set<String> = [
        "cathedral", "church", "temple", "mosque", "synagogue", "pagoda", "shrine",
        "castle", "palace", "monument", "obelisk", "lighthouse", "bridge",
    ]
    private static let architecturalFeatures: Set<String> = ["arch", "tower", "skyscraper"]

    static func landmarkConfidence(_ labels: [String: Float]) -> Float {
        let direct = distinctiveStructures.compactMap { labels[$0] }.max() ?? 0
        let feature = architecturalFeatures.compactMap { labels[$0] }.max() ?? 0
        // A distinctive exterior can read as an arch or tower even when Vision
        // has no more specific class for the building.
        let exterior = min(labels["structure"] ?? 0, labels["outdoor"] ?? 0, feature)
        return max(direct, exterior)
    }

    // At most the same influence as a 0.13 difference in full-frame aesthetics.
    // Compare scene interest only within the same full-frame quality tier.
    static let maximumSceneBonus: Float = 0.09

    static func best(in photos: [PhotoAssetRecord], analyses: [String: ScenicCoverAnalysis],
                     sceneStrengths: [String: Float] = [:]) -> PhotoAssetRecord? {
        let ranked = photos.compactMap { photo -> (PhotoAssetRecord, Int, Float)? in
            guard let analysis = analyses[photo.id], !analysis.isUtility, analysis.largestFace.isFinite,
                  let appeal = analysis.aesthetics, appeal.isFinite, appeal >= -0.4 else { return nil }
            let landmark = analysis.landmark >= 0.30 && analysis.largestFace < 0.12
            guard landmark || analysis.isScenic || appeal >= 0.35 else { return nil }
            let feature = landmark ? analysis.landmark : analysis.scenery
            let score = feature * 0.28 + appeal * 0.70 - analysis.largestFace
                + (photo.isFavorite ? 0.03 : 0)
            let strength = sceneStrengths[photo.id] ?? 0
            let bonus = strength.isFinite ? min(1, max(0, strength)) * maximumSceneBonus : 0
            return (photo, landmark ? 1 : 0, score + bonus)
        }
        return ranked.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            if lhs.0.creationDate != rhs.0.creationDate { return lhs.0.creationDate < rhs.0.creationDate }
            return lhs.0.id > rhs.0.id
        }?.0
    }
}

nonisolated enum ScenicCoverPolicy {
    static let candidateLimit = 24
    static let visitLimit = 6
    static let recentVisitBudget = 18
    // Exact identifiers, not substring matches (e.g. bernese_mountain is a dog).
    static let labels: Set<String> = [
        "beach", "mountain", "forest", "cityscape", "building", "skyscraper",
        "sunset_sunrise", "ocean", "lake", "river", "waterfall", "desert",
        "canyon", "island", "glacier", "garden", "park", "shore", "cliff",
        "bridge", "tower", "castle", "monument",
    ]

    static func visits(from places: [TravelPlace]) -> [TravelPlace] {
        let sorted = places.sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate }
        guard sorted.count > visitLimit else { return sorted }
        return (0..<visitLimit).map { sorted[$0 * (sorted.count - 1) / (visitLimit - 1)] }
    }

    static func best(in photos: [PhotoAssetRecord], analyses: [String: ScenicCoverAnalysis]) -> PhotoAssetRecord? {
        photos.filter { analyses[$0.id]?.isScenic == true }.sorted { lhs, rhs in
            let a = analyses[lhs.id]!.score(for: lhs), b = analyses[rhs.id]!.score(for: rhs)
            if a != b { return a > b }
            if lhs.creationDate != rhs.creationDate { return lhs.creationDate > rhs.creationDate }
            return lhs.id < rhs.id
        }.first
    }
}

/// Take both ends and a favorite first, then bisect the longest unexamined
/// intervals. Keep successful selections separated by at least two minutes.
nonisolated struct ScenicCoverVisitSampler {
    enum Order { case newest, oldest, favorite }

    static let minimumSeparation: TimeInterval = 120
    private var intervals: [ClosedRange<Date>]
    private var anchors: [Order] = [.newest, .favorite, .oldest]

    init(start: Date, end: Date) {
        intervals = start <= end ? [start...end] : []
    }

    mutating func next(read: (ClosedRange<Date>, Order) throws -> PhotoAssetRecord?) throws -> PhotoAssetRecord? {
        while !anchors.isEmpty {
            let order = anchors.removeFirst()
            let indices = order == .oldest ? Array(intervals.indices) : Array(intervals.indices.reversed())
            for index in indices {
                if let photo = try read(intervals[index], order) {
                    accept(photo, in: index)
                    return photo
                }
            }
        }

        while let index = intervals.indices.max(by: { width(intervals[$0]) < width(intervals[$1]) }) {
            let interval = intervals[index]
            let midpoint = interval.lowerBound.addingTimeInterval(width(interval) / 2)
            let earlier = try read(interval.lowerBound...midpoint, .newest)
            // An exact hit needs no second indexed lookup.
            let later = earlier?.creationDate == midpoint ? nil : try read(midpoint...interval.upperBound, .oldest)
            let nearest = [earlier, later].compactMap { $0 }.min {
                let a = abs($0.creationDate.timeIntervalSince(midpoint))
                let b = abs($1.creationDate.timeIntervalSince(midpoint))
                return a == b ? $0.id < $1.id : a < b
            }
            if let nearest {
                accept(nearest, in: index)
                return nearest
            }
            intervals.remove(at: index)
        }
        return nil
    }

    private func width(_ interval: ClosedRange<Date>) -> TimeInterval {
        interval.upperBound.timeIntervalSince(interval.lowerBound)
    }

    private mutating func accept(_ photo: PhotoAssetRecord, in index: Int) {
        let interval = intervals.remove(at: index)
        let before = photo.creationDate.addingTimeInterval(-Self.minimumSeparation)
        let after = photo.creationDate.addingTimeInterval(Self.minimumSeparation)
        var remaining: [ClosedRange<Date>] = []
        if interval.lowerBound <= before { remaining.append(interval.lowerBound...before) }
        if after <= interval.upperBound { remaining.append(after...interval.upperBound) }
        intervals.insert(contentsOf: remaining, at: index)
    }
}

nonisolated protocol ScenicCoverStoring: Sendable {
    func scenicCoverCandidates(for places: [TravelPlace], journeyWindow: JourneyCoverWindow?, priorityVisitID: String?,
                               excluding: Set<String>) async throws -> [PhotoAssetRecord]
    func scenicCoverBackups(for primaries: [PhotoAssetRecord], missing: Set<String>,
                           excluding: Set<String>) async throws -> [String: [PhotoAssetRecord]]
    func sceneStrengths(for photos: [PhotoAssetRecord], excluding: Set<String>) async throws -> [String: Float]
    func coverAnalyses(for ids: [String], revision: String) async throws -> [String: ScenicCoverAnalysis]
    func saveCoverAnalysis(_ analysis: ScenicCoverAnalysis, assetID: String, revision: String) async throws
}

/// Bounds are measured from this trip's newest currently eligible media, including video.
nonisolated struct JourneyCoverWindow: Sendable {
    static let duration: TimeInterval = 30 * 86_400
    let latest: PhotoAssetRecord
    let visibleVisitEnds: [String: Date]

    var dates: ClosedRange<Date> {
        latest.creationDate.addingTimeInterval(-Self.duration)...latest.creationDate
    }

    func contains(_ photo: PhotoAssetRecord) -> Bool {
        guard let placeID = photo.placeID, visibleVisitEnds[placeID] != nil else { return false }
        return dates.contains(photo.creationDate)
    }

    func incumbent(_ stored: PhotoAssetRecord?, excluding excluded: Set<String>) -> PhotoAssetRecord? {
        guard let stored, !excluded.contains(stored.id), contains(stored) else { return nil }
        return stored
    }

    static let preferenceKey = "journeyCoverSelections.v1"

    @MainActor func restore(_ stored: PhotoAssetRecord?, id: String, journeyID: String,
                            excluding excluded: Set<String>, defaults: UserDefaults) -> PhotoAssetRecord? {
        if let current = incumbent(stored, excluding: excluded), current.id == id { return current }
        var selections = defaults.dictionary(forKey: Self.preferenceKey) as? [String: String] ?? [:]
        if selections[journeyID] == id {
            selections.removeValue(forKey: journeyID)
            defaults.set(selections, forKey: Self.preferenceKey)
        }
        return nil
    }

}

/// The system shelf represents a whole trip. Portraits and family photos are eligible.
nonisolated enum JourneyCoverPolicy {
    // Keep a recognizable cover when scores on Vision's −1...1 scale are close.
    static let replacementMargin: Float = 0.12

    static func best(in photos: [PhotoAssetRecord], analyses: [String: ScenicCoverAnalysis],
                     incumbent: String?) -> PhotoAssetRecord? {
        func score(_ photo: PhotoAssetRecord) -> Float? {
            guard let analysis = analyses[photo.id], !analysis.isUtility,
                  let quality = analysis.aesthetics, quality.isFinite else { return nil }
            return quality + (photo.isFavorite ? 0.04 : 0)
        }
        if let current = photos.first(where: { $0.id == incumbent }),
           analyses[current.id]?.hasAestheticScore != true {
            return current
        }
        let ranked = photos.compactMap { photo in score(photo).map { (photo, $0) } }
        guard let best = ranked.sorted(by: { a, b in
            a.1 == b.1 ? a.0.id < b.0.id : a.1 > b.1
        }).first else { return nil }
        if let current = ranked.first(where: { $0.0.id == incumbent }),
           best.1 < current.1 + replacementMargin { return current.0 }
        return best.0
    }
}
