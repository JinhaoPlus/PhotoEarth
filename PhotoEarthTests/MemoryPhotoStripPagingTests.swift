import Foundation
import Testing
@testable import PhotoEarth

struct MemoryPhotoStripPagingTests {
    @Test func mixedOrientationsFitWithoutDroppingPhotos() {
        let ratios: [CGFloat] = [0.3, 0.75, 1, 1.33, 1.5, 4]
        let widths = (ratios + ratios + ratios).map(MemoryPhotoStripPaging.thumbnailWidth)
        #expect(widths[0] < widths[1] && widths[1] < widths[2])
        #expect(widths[0] >= 90 && widths[5] <= 240)
        let paging = MemoryPhotoStripPaging(widths: widths, availableWidth: 1_760)
        #expect(paging.pages.count == 2)
        #expect(Set(paging.pages.flatMap { $0 }) == Set(widths.indices))
        for page in paging.pages {
            let total = widths[page].reduce(0, +) + CGFloat(page.count - 1) * MemoryPhotoStripPaging.spacing
            #expect(total <= 1_760)
        }
    }

    @Test func sparseTailCarriesContextWithoutHidingItsNewPhoto() {
        let paging = MemoryPhotoStripPaging(widths: Array(repeating: 180, count: 10), availableWidth: 1_760)
        #expect(paging.pages == [0..<9, 5..<10])
    }

    @Test func narrowAndEmptyLayoutsRemainSafe() {
        let narrow = MemoryPhotoStripPaging(widths: [144, 200, 160, 144], availableWidth: 40)
        #expect(narrow.pages.count == 4)
        #expect(narrow.range(for: 99) == 3..<4)
        let empty = MemoryPhotoStripPaging(widths: [], availableWidth: .infinity)
        #expect(empty.range(for: 0).isEmpty)
    }
}
