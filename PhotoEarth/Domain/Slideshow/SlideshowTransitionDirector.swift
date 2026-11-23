import CoreGraphics
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
    case panoramaGlide, focusPullback, centerOpen

    var isHighMotion: Bool {
        self == .panoramaGlide || self == .focusPullback || self == .centerOpen
    }

    var revealsTilesIndividually: Bool { self == .stagger || self == .centerOpen }

    var duration: TimeInterval {
        switch self {
        case .dissolve: 0.72
        case .settle, .focusPullback: 0.78
        case .reveal, .stagger, .panoramaGlide, .centerOpen: 0.82
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

    func openingRect(at progress: Double, in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: bounds.width * (1 - 1.06 * Self.smooth(progress)) / 2, dy: 0)
    }

    func visibleTiles(at progress: Double, ratios: [CGFloat], in canvas: CGSize) -> IndexSet {
        switch kind {
        case .stagger:
            return IndexSet(ratios.indices.prefix { tileOpacity(at: progress, index: $0, count: ratios.count) > 0 })
        case .centerOpen:
            let opening = openingRect(at: progress, in: CGRect(origin: .zero, size: canvas))
            let frames = SlideshowCollageLayout.frames(for: ratios, in: canvas)
            return IndexSet(frames.indices.filter { frames[$0].intersection(opening).width > 0 })
        default: return []
        }
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
    private static let highMotionSpacing = 15
    private var distinctQuietEdges = 0
    private var recent: [SlideshowEffect] = []

    mutating func transition(from a: SlideshowPageDescriptor, to b: SlideshowPageDescriptor,
                             manual: Bool, reduced: Bool) -> EarthSlideshowTransition {
        if manual || reduced { return .init(kind: .dissolve, duration: manual ? 0.16 : 0.20) }
        let edge = Boundary(from: a.ids, to: b.ids)
        let effect: SlideshowEffect
        if let previous = choices[edge] {
            // Replaying the same boundary never earns or repeats a high-motion cue.
            let justPlayedHighMotion = recent.suffix(2).contains(where: \.isHighMotion)
            effect = previous.isHighMotion || justPlayedHighMotion ? .dissolve : previous
        } else {
            effect = choose(from: a, to: b)
            choices[edge] = effect
            distinctQuietEdges = effect.isHighMotion ? 0 : min(Self.highMotionSpacing, distinctQuietEdges + 1)
        }
        recent = Array(recent.suffix(5)) + [effect]
        return .init(kind: effect, duration: effect.duration)
    }

    private func choose(from a: SlideshowPageDescriptor, to b: SlideshowPageDescriptor) -> SlideshowEffect {
        guard a.visitID == b.visitID, !a.dynamic, !b.dynamic,
              Calendar.current.isDate(a.lastDate, inSameDayAs: b.firstDate),
              recent.suffix(2).allSatisfy({ $0 == .dissolve }) else { return .dissolve }
        if distinctQuietEdges == Self.highMotionSpacing, a.ratios.count == 1 {
            if b.ratios.count > 1 { return .centerOpen }
            if let old = a.ratios.first, let new = b.ratios.first,
               b.ratios.count == 1, old > 0, new > 0, (old < 1) == (new < 1) {
                if b.favorite { return .focusPullback }
                if old >= 1, new >= 1.7 { return .panoramaGlide }
            }
        }
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
