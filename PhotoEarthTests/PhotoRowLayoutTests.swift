import Foundation
import Testing
@testable import PhotoEarth

struct PhotoRowLayoutTests {
    @Test func incrementalPagesPreserveGeometryAndBuildConstantTimePositionLookups() {
        var layout = PhotoRowLayout.Accumulator()
        let items = (0..<144).map { PhotoRowLayout.Item(id: "photo-\($0)", aspectRatio: $0.isMultiple(of: 3) ? 2.0 / 3 : 1.5) }
        layout.append(Array(items.prefix(48)), width: 1_760)
        let original = layout.rows
        layout.append(Array(items[48..<96]), width: 1_760)
        layout.append(Array(items[96..<144]), width: 1_760)
        #expect(Array(layout.rows.prefix(original.count)) == original)
        #expect(layout.rows.flatMap(\.items).map(\.id) == items.map(\.id))
        for (position, item) in items.enumerated() {
            #expect(layout.itemPositions[item.id] == position)
            let row = layout.rowPositions[item.id]!
            #expect(layout.rows[row].items.contains { $0.id == item.id })
        }
        layout.append([items[0], items[143]], width: 1_760)
        #expect(layout.itemPositions.count == 144)
    }

    @Test func portraitLandscapeSquareAndPanoramaKeepTheirRatioAndReadingOrder() {
        let ratios = [1.5, 2.0 / 3, 1, 3, 16.0 / 9, 0.75, 1.5, 3]
        let items = ratios.enumerated().map { PhotoRowLayout.Item(id: "photo-\($0.offset)", aspectRatio: $0.element) }
        for width in [1_120.0, 1_712, 1_760] {
            let rows = PhotoRowLayout.rows(for: items, width: width)
            #expect(rows.flatMap(\.items).map(\.id) == items.map(\.id))
            for row in rows {
                #expect(row.items.count <= 5)
                #expect(row.height > 0 && row.height <= 340)
                #expect(row.widths.reduce(0, +) + Double(row.items.count - 1) * 34 <= width + 0.001)
                for (item, itemWidth) in zip(row.items, row.widths) {
                    #expect(abs(itemWidth / row.height - item.aspectRatio) < 0.00001)
                }
            }
        }
    }

    @Test func appendLeavesExistingRowsIncludingTheLastShortRowUnchanged() {
        let items = (0..<70).map { PhotoRowLayout.Item(id: "photo-\($0)", aspectRatio: $0.isMultiple(of: 3) ? 2.0 / 3 : 1.5) }
        let first = PhotoRowLayout.rows(for: Array(items.prefix(48)), width: 1_760)
        let next = PhotoRowLayout.rows(for: items, width: 1_760, preserving: first)
        #expect(Array(next.prefix(first.count)) == first)
        #expect(next.flatMap(\.items).map(\.id) == items.map(\.id))
    }

    @Test func groupingNeverMixesYearsAndRemovalDoesNotResurrectAnOldPhoto() {
        let items = (0..<30).map { PhotoRowLayout.Item(id: "photo-\($0)", aspectRatio: 1.5, group: $0 < 11 ? 2025 : 2024) }
        let rows = PhotoRowLayout.rows(for: items, width: 1_712)
        #expect(rows.allSatisfy { Set($0.items.map(\.group)).count == 1 })
        let remaining = items.filter { $0.id != "photo-6" }
        let refreshed = PhotoRowLayout.rows(for: remaining, width: 1_712, preserving: rows)
        #expect(refreshed.flatMap(\.items).map(\.id) == remaining.map(\.id))
    }

    @Test func invalidAndExtremeDimensionsProduceFiniteFocusableSurfaces() {
        #expect(PhotoPreviewMetadata(assetID: "unknown", pixelWidth: 0, pixelHeight: 0).aspectRatio == 1.5)
        let items = [Double.nan, .infinity, 0, -1, 0.01, 100].enumerated().map {
            PhotoRowLayout.Item(id: "edge-\($0.offset)", aspectRatio: $0.element)
        }
        let rows = PhotoRowLayout.rows(for: items, width: 1_712)
        #expect(rows.flatMap(\.items).count == items.count)
        #expect(rows.allSatisfy { $0.height.isFinite && $0.widths.allSatisfy { $0.isFinite && $0 > 0 } })
    }
}
