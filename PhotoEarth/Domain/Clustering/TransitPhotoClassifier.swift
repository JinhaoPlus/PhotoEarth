import Foundation

/// Product heuristics, not a claim about transport mode. All inputs are metadata.
nonisolated struct TransitFilteringConfiguration: Sendable {
    var maximumSparseCount = 2
    var maximumSparseSpan: TimeInterval = 30 * 60
    var minimumSpeed = 400.0
    var maximumSpeed = 1_400.0
    var minimumInterval: TimeInterval = 60
    var maximumInterval: TimeInterval = 6 * 3_600
    var maximumHorizontalUncertainty = 1_000.0
    var highAltitude = 8_000.0
    var maximumVerticalUncertainty = 100.0
}

nonisolated enum TransitPhotoReason: Int, Sendable {
    case sparseVisit = 1
    case fastTransit = 2
    case highAltitudeFastTransit = 3
}

nonisolated struct TransitPhotoClassifier: Sendable {
    let configuration: TransitFilteringConfiguration
    init(configuration: TransitFilteringConfiguration = .init()) { self.configuration = configuration }

    func isSparseVisit(count: Int, start: Date, end: Date, hasFavorite: Bool) -> Bool {
        let span = end.timeIntervalSince(start)
        return !hasFavorite && count > 0 && count <= configuration.maximumSparseCount
            && span.isFinite && span >= 0 && span <= configuration.maximumSparseSpan
    }

    /// Only the middle record is classified; neither endpoint is assumed to be in transit.
    func reason(previous: PhotoAssetRecord, current: PhotoAssetRecord, next: PhotoAssetRecord) -> TransitPhotoReason? {
        guard !current.isFavorite,
              let first = fastLeg(previous, current), let second = fastLeg(current, next) else { return nil }
        // A jump to a remote GPS point followed by a return is not a credible route.
        let direct = GlobeMath.distanceKilometers(from: previous.coordinate, to: next.coordinate)
        guard direct >= max(first, second) else { return nil }
        if let altitude = current.altitudeMeters, let accuracy = current.verticalAccuracyMeters,
           altitude.isFinite, accuracy.isFinite, accuracy >= 0,
           accuracy <= configuration.maximumVerticalUncertainty,
           altitude - accuracy >= configuration.highAltitude {
            return .highAltitudeFastTransit
        }
        return .fastTransit
    }

    private func fastLeg(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Double? {
        let interval = rhs.creationDate.timeIntervalSince(lhs.creationDate)
        guard lhs.coordinate.isValid, rhs.coordinate.isValid, interval.isFinite,
              interval >= configuration.minimumInterval, interval <= configuration.maximumInterval else { return nil }
        var uncertainty = 0.0
        for record in [lhs, rhs] {
            if let accuracy = record.horizontalAccuracyMeters {
                guard accuracy.isFinite, accuracy >= 0,
                      accuracy <= configuration.maximumHorizontalUncertainty else { return nil }
                uncertainty += accuracy / 1_000
            }
        }
        let distance = GlobeMath.distanceKilometers(from: lhs.coordinate, to: rhs.coordinate)
        let lowerSpeed = max(0, distance - uncertainty) / interval * 3_600
        let upperSpeed = distance / interval * 3_600
        guard lowerSpeed >= configuration.minimumSpeed, upperSpeed <= configuration.maximumSpeed else { return nil }
        return distance
    }
}
