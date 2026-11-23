import Foundation

/// One equal-height row, preserving each photograph's complete composition.
nonisolated enum SlideshowCollageLayout {
    static let television = CGSize(width: 3_840, height: 2_160)

    static func gap(in canvas: CGSize) -> CGFloat { canvas.width / 320 }

    static func sizes(for ratios: [CGFloat], in canvas: CGSize) -> [CGSize] {
        guard !ratios.isEmpty, ratios.allSatisfy({ $0 > 0 }) else { return [] }
        let width = canvas.width - CGFloat(ratios.count - 1) * gap(in: canvas)
        let height = min(canvas.height, width / ratios.reduce(0, +))
        return ratios.map { CGSize(width: $0 * height, height: height) }
    }

    static func count(for ratios: [CGFloat], in canvas: CGSize = television) -> Int {
        guard let first = ratios.first, first > 0 else { return 1 }
        func coverage(_ prefix: [CGFloat]) -> CGFloat {
            sizes(for: prefix, in: canvas).reduce(0) { $0 + $1.width * $1.height }
                / (canvas.width * canvas.height)
        }
        let single = coverage([first])
        var best = 1
        var bestCoverage = single
        for length in [2, 3] where ratios.count >= length {
            let prefix = Array(ratios.prefix(length))
            let portraits = prefix.filter { $0 < 1 }.count
            guard prefix.allSatisfy({ $0 > 0 && $0 != 1 }),
                  length == 2 ? portraits >= 1 : portraits == 3 else { break }
            let area = coverage(prefix)
            if area >= 0.75, area > single, best == 1 || area - bestCoverage >= 0.03 {
                best = length
                bestCoverage = area
            }
        }
        return best
    }
}
