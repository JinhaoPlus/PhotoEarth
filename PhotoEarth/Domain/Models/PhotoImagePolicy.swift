import Foundation
import CoreGraphics

/// Layout and metadata can grow while the decoded image working set stays fixed.
nonisolated enum OverviewImageWindow {
    static let placesPerShelf = 5
    static let maximumResidentImages = 15
    static let collectionGridShelfRadius = 2
    static let collectionGridMaximumResidentImages = 20

    /// Calendar groups can end with a short row; use actual layout rows so
    /// returning focus and image preparation share the same bounded window.
    static func residentIndices(
        shelfRanges: [Range<Int>],
        focusedShelfIndex: Int?,
        shelfRadius: Int = 1,
        imageLimit: Int = maximumResidentImages
    ) -> Range<Int> {
        guard !shelfRanges.isEmpty else { return 0..<0 }
        let focus = min(max(focusedShelfIndex ?? 0, 0), shelfRanges.count - 1)
        let radius = min(max(0, shelfRadius), shelfRanges.count)
        let shelfCount = min(radius * 2 + 1, shelfRanges.count)
        let first = min(max(focus - radius, 0), shelfRanges.count - shelfCount)
        let last = first + shelfCount - 1
        let start = shelfRanges[first].lowerBound
        return start..<min(shelfRanges[last].upperBound, start + max(0, imageLimit))
    }

    static func residentIndices(placeCount: Int, focusedPlaceIndex: Int?) -> Range<Int> {
        guard placeCount > 0 else { return 0..<0 }
        let shelfCount = (placeCount + placesPerShelf - 1) / placesPerShelf
        let focusIndex = min(max(focusedPlaceIndex ?? 0, 0), placeCount - 1)
        let firstShelf = min(max(focusIndex / placesPerShelf - 1, 0), max(shelfCount - 3, 0))
        let start = firstShelf * placesPerShelf
        return start..<min(start + maximumResidentImages, placeCount)
    }

    static func residentIndices(nearby: Range<Int>, visible: Set<Int>, focused: Int?) -> [Int] {
        let focus = focused.map { [$0] } ?? []
        let visibleInOrder = visible.sorted().filter { $0 != focused }
        let neighbors = nearby.filter { !visible.contains($0) && $0 != focused }
        return Array((focus + visibleInOrder + neighbors).prefix(maximumResidentImages))
    }
}

nonisolated enum PhotoImageSizing {
    enum CoverAction { case display, requestNetworkRendition, requestOriginal }

    static func coverAction(deliveredEdge: Int, requiredEdge: Int, network: Bool) -> CoverAction {
        // PhotoKit can round an aspect-fit target down by one pixel.
        if deliveredEdge > 0, deliveredEdge >= requiredEdge - 1 { return .display }
        return network ? .requestOriginal : .requestNetworkRendition
    }

    /// Stable pixel buckets avoid refetching for tiny layout changes. Each wall
    /// cell fits its original ratio; only the focused cell receives an upgrade.
    static func wallTargetSize(pixelWidth: Int, pixelHeight: Int, cardSize: CGSize,
                               displayScale: CGFloat, isFocused: Bool) -> CGSize {
        let scale = displayScale.isFinite ? min(max(displayScale, 1), 3) : 1
        let display = requestSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  targetSize: CGSize(width: cardSize.width * scale, height: cardSize.height * scale),
                                  fillsTarget: false)
        let edge = max(display.width, display.height) * (isFocused ? 1.25 : 1)
        let bucket = [640, 960, 1_200, 1_600].first { CGFloat($0) >= edge } ?? 1_600
        return requestSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                           targetSize: CGSize(width: bucket, height: bucket), fillsTarget: false)
    }

    /// Pass an asset-shaped target to PhotoKit. A panorama must not become an
    /// enormous decoded image just to fill the height of a small card.
    static func requestSize(pixelWidth: Int, pixelHeight: Int, targetSize: CGSize, fillsTarget: Bool) -> CGSize {
        let width = Double(max(pixelWidth, 1))
        let height = Double(max(pixelHeight, 1))
        let targetWidth = targetSize.width.isFinite ? min(max(targetSize.width, 1), 3_840) : 1
        let targetHeight = targetSize.height.isFinite ? min(max(targetSize.height, 1), 3_840) : 1
        let horizontalScale = targetWidth / width
        let verticalScale = targetHeight / height
        let displayScale = fillsTarget ? max(horizontalScale, verticalScale) : min(horizontalScale, verticalScale)
        let longEdgeScale = max(targetWidth, targetHeight) / max(width, height)
        let scale = min(displayScale, longEdgeScale, 1)
        return CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
    }
}
