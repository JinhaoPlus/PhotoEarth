import Foundation

nonisolated struct SlideshowTransitionDirector: Sendable {
    func transitions(for records: [PhotoAssetRecord]) -> [EarthSlideshowTransition] {
        guard !records.isEmpty else { return [] }
        var result = [EarthSlideshowTransition(kind: .dissolve, duration: duration(for: .dissolve))]
        for index in records.indices.dropFirst() {
            let kind = proposedKind(from: records[index - 1], to: records[index])
            result.append(EarthSlideshowTransition(kind: kind, duration: duration(for: kind)))
        }
        return result
    }

    private func proposedKind(from previous: PhotoAssetRecord, to next: PhotoAssetRecord) -> EarthSlideshowTransitionKind {
        if !Calendar(identifier: .gregorian).isDate(previous.creationDate, inSameDayAs: next.creationDate) {
            return .dateReveal
        }
        if previous.mediaKind.isPlayable || next.mediaKind.isPlayable { return .dissolve }
        let previousLandscape = previous.pixelWidth >= previous.pixelHeight
        let nextLandscape = next.pixelWidth >= next.pixelHeight
        if previousLandscape != nextLandscape { return .settle }
        if next.creationDate.timeIntervalSince(previous.creationDate) > 2 * 3_600 { return .directional }
        return .dissolve
    }

    private func duration(for kind: EarthSlideshowTransitionKind) -> TimeInterval {
        switch kind {
        // A television-sized image needs enough overlap for the eye to follow
        // the memory rather than notice a page change. Repeated dissolves are
        // intentional; semantic continuity matters more than effect variety.
        case .dissolve: return 0.72
        case .directional: return 0.78
        case .settle: return 0.82
        case .dateReveal: return 0.90
        }
    }
}
