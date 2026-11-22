import CoreGraphics
import Foundation

/// PhotoKit/SQLite dimensions, available before image bytes or iCloud downloads.
nonisolated struct PhotoPreviewMetadata: Equatable, Sendable {
    let assetID: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(assetID: String, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.assetID = assetID; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
    init(_ photo: PhotoAssetRecord) {
        self.init(assetID: photo.id, pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight)
    }
    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1.5 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// Pure, metadata-only row composition. Existing rows can stay fixed while
/// appending pages or completing dimensions beyond the user's current view.
nonisolated enum PhotoRowLayout {
    static let mosaicGap = 4.0

    /// An append touches only the new page. Existing row geometry and position
    /// lookups survive, including the previous page's short final row.
    struct Accumulator {
        private(set) var rows: [Row] = []
        private(set) var rowPositions: [String: Int] = [:]
        private(set) var itemPositions: [String: Int] = [:]

        mutating func append(_ items: [Item], width: Double, spacing: Double = 34, mosaic: Bool = false) {
            var seen = Set<String>()
            let newItems = items.filter { itemPositions[$0.id] == nil && seen.insert($0.id).inserted }
            guard !newItems.isEmpty, width.isFinite, width > 0 else { return }
            let newRows: [Row]
            if mosaic {
                // A short page can end midway through a band. Reuse its slots
                // so the next page can fill the gaps without moving a photo.
                var page = newItems
                if let last = rows.last, last.items.count < mosaicSlots(band: rows.count - 1).count {
                    page = rows.removeLast().items + newItems
                }
                newRows = mosaicRows(for: page, width: width, startingAt: rows.count)
            } else {
                newRows = PhotoRowLayout.rows(for: newItems, width: width, spacing: spacing)
            }
            var position = itemPositions.count
            for row in newRows {
                let rowPosition = rows.count
                for item in row.items where itemPositions[item.id] == nil {
                    rowPositions[item.id] = rowPosition
                    itemPositions[item.id] = position
                    position += 1
                }
                rows.append(row)
            }
        }
    }

    private static func mosaicRows(for items: [Item], width: Double, startingAt firstBand: Int) -> [Row] {
        let gap = min(mosaicGap, width / 10)
        let stride = (width + gap) / 5
        var remaining = items[...]
        var bands: [Row] = []
        while !remaining.isEmpty {
            let slots = mosaicSlots(band: firstBand + bands.count).prefix(remaining.count)
            let frames = slots.map { slot in
                let side = Double(slot.span) * stride - gap
                return CGRect(x: Double(slot.column) * stride, y: Double(slot.row) * stride,
                              width: side, height: side)
            }
            let height = frames.reduce(0.0) { max($0, Double($1.maxY)) }
            bands.append(Row(items: Array(remaining.prefix(slots.count)), height: height, frames: frames))
            remaining = remaining.dropFirst(slots.count)
        }
        return bands
    }

    // Five columns alternate between a strip and a two-high band. Slots
    // follow reading order, including when the large square is on the right.
    private static func mosaicSlots(band: Int) -> [(column: Int, row: Int, span: Int)] {
        switch band % 4 {
        case 0: [(0, 0, 2), (2, 0, 1), (3, 0, 1), (4, 0, 1), (2, 1, 1), (3, 1, 1), (4, 1, 1)]
        case 2: [(0, 0, 1), (1, 0, 1), (2, 0, 1), (3, 0, 2), (0, 1, 1), (1, 1, 1), (2, 1, 1)]
        default: [(0, 0, 1), (1, 0, 1), (2, 0, 1), (3, 0, 1), (4, 0, 1)]
        }
    }

    struct Item: Equatable, Identifiable, Sendable {
        let id: String
        let aspectRatio: Double
        var group: Int? = nil

        // Extreme scans/panoramas remain completely visible using aspect-fit.
        // Bound their surrounding focus surface so it never becomes a sliver.
        var layoutRatio: Double { aspectRatio.isFinite && aspectRatio > 0 ? min(max(aspectRatio, 0.6), 6) : 1.5 }
    }

    struct Row: Equatable, Identifiable, Sendable {
        let items: [Item]
        let height: Double
        let frames: [CGRect]
        var widths: [Double] { frames.map { Double($0.width) } }
        var id: String { items[0].id }
    }

    static func rows(for items: [Item], width: Double, spacing: Double = 34,
                     preferredHeight: Double = 260, maximumItems: Int = 5,
                     preserving previous: [Row] = []) -> [Row] {
        guard !items.isEmpty, width.isFinite, width > 0 else { return [] }
        let gap = max(0, spacing)
        let limit = max(1, min(maximumItems, 5))
        var result: [Row] = []
        var start = 0
        // Preserve geometry, including a short final row. New pages cannot
        // resize a photo already on screen; edits still show fully inside it.
        for row in previous {
            let end = start + row.items.count
            guard end <= items.count,
                  zip(row.items, items[start..<end]).allSatisfy({ $0.id == $1.id && $0.group == $1.group }) else { break }
            result.append(row)
            start = end
        }
        while start < items.count {
            var count = 0
            var sum = 0.0
            var bestCount = 1
            var bestDistance = Double.infinity
            while count < limit, start + count < items.count,
                  items[start + count].group == items[start].group {
                sum += items[start + count].layoutRatio
                count += 1
                let available = width - Double(count - 1) * gap
                guard available > 0 else { break }
                let height = available / sum
                let distance = abs(log(height / preferredHeight))
                if distance < bestDistance { bestDistance = distance; bestCount = count }
                if height <= preferredHeight { break }
            }
            let end = start + bestCount
            let rowItems = Array(items[start..<end])
            let ratios = rowItems.map(\.layoutRatio)
            let fitted = (width - Double(bestCount - 1) * gap) / ratios.reduce(0, +)
            let endsGroup = end == items.count || items[end].group != items[start].group
            let height = min(fitted, endsGroup ? preferredHeight : 340)
            var x = 0.0
            let frames = ratios.map { ratio in
                let frame = CGRect(x: x, y: 0, width: ratio * height, height: height)
                x = frame.maxX + gap
                return frame
            }
            result.append(Row(items: rowItems, height: height, frames: frames))
            start = end
        }
        return result
    }
}
