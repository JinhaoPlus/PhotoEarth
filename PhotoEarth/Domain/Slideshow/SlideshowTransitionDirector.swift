import Foundation

nonisolated struct SlideshowPageDescriptor: Equatable, Sendable {
    let ids: [String]
    let ratios: [CGFloat]
    let visitID: String
    let firstDate: Date
    let lastDate: Date
    let favorite: Bool
    let dynamic: Bool
}

nonisolated enum SlideshowEffect: String, Sendable {
    case dissolve, settle, reveal, backdrop, stagger

    var duration: TimeInterval {
        switch self {
        case .dissolve: 0.72
        case .settle: 0.78
        case .reveal, .stagger: 0.82
        case .backdrop: 0.80
        }
    }
}

nonisolated struct EarthSlideshowTransition: Equatable, Sendable {
    let kind: SlideshowEffect
    let duration: TimeInterval

    static func smooth(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    func visibleStaggeredTiles(at progress: Double, count: Int) -> Int {
        guard kind == .stagger else { return 0 }
        return (0..<count).prefix { tileOpacity(at: progress, index: $0, count: count) > 0 }.count
    }

    func tileOpacity(at progress: Double, index: Int, count: Int) -> Double {
        let offset = 0.085
        return Self.smooth((progress * duration - Double(index) * offset) / (duration - Double(count - 1) * offset))
    }
}

nonisolated struct SlideshowTransitionDirector {
    private struct Boundary: Hashable {
        let from: [String]
        let to: [String]
    }
    private var choices: [Boundary: SlideshowEffect] = [:]
    private var recent: [SlideshowEffect] = []

    mutating func transition(from a: SlideshowPageDescriptor, to b: SlideshowPageDescriptor,
                             manual: Bool, reduced: Bool) -> EarthSlideshowTransition {
        if manual || reduced { return .init(kind: .dissolve, duration: manual ? 0.16 : 0.20) }
        let edge = Boundary(from: a.ids, to: b.ids)
        let effect = choices[edge] ?? choose(from: a, to: b)
        choices[edge] = effect
        recent = Array(recent.suffix(5)) + [effect]
        return .init(kind: effect, duration: effect.duration)
    }

    private func choose(from a: SlideshowPageDescriptor, to b: SlideshowPageDescriptor) -> SlideshowEffect {
        guard a.visitID == b.visitID, !a.dynamic, !b.dynamic,
              Calendar.current.isDate(a.lastDate, inSameDayAs: b.firstDate),
              recent.suffix(2).allSatisfy({ $0 == .dissolve }) else { return .dissolve }
        if a.ratios.count > 1, a.ratios.count == b.ratios.count,
           zip(a.ratios, b.ratios).allSatisfy({ abs($0 - $1) < 0.001 }) { return .stagger }
        guard a.ratios.count == 1, b.ratios.count == 1,
              let old = a.ratios.first, let new = b.ratios.first, old > 0, new > 0 else { return .dissolve }
        if (old < 1) != (new < 1) { return .backdrop }
        if b.firstDate.timeIntervalSince(a.lastDate) >= 45 * 60 { return .reveal }
        if b.favorite, !recent.contains(.settle) { return .settle }
        return .dissolve
    }
}
