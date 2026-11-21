import Photos
import Testing
import UIKit
@testable import PhotoEarth

struct PhotoImageLoadingTests {
    @Test func walkingEveryShelfKeepsAFixedImageBudgetAndItsAdjacentRows() {
        for count in [0, 1, 5, 14, 15, 16, 762] {
            for focus in 0..<max(1, count) {
                let window = OverviewImageWindow.residentIndices(placeCount: count, focusedPlaceIndex: focus)
                #expect(window.count <= 15)
                #expect(window.lowerBound >= 0 && window.upperBound <= count)
                if count > 0 { #expect(window.contains(focus)) }
                if focus >= 5 { #expect(window.contains((focus / 5 - 1) * 5)) }
                let nextShelf = (focus / 5 + 1) * 5
                if nextShelf < count { #expect(window.contains(nextShelf)) }
            }
        }
        #expect(OverviewImageWindow.residentIndices(placeCount: 762, focusedPlaceIndex: nil) == 0..<15)
        #expect(!OverviewImageWindow.residentIndices(placeCount: 762, focusedPlaceIndex: 400).contains(0))
    }

    @Test func fourColumnLibraryKeepsTwoRowsOnEachSideWithoutUnboundedResidency() {
        let rows = stride(from: 0, to: 100, by: 4).map { $0..<min($0 + 4, 100) }
        for focusRow in rows.indices {
            let window = OverviewImageWindow.residentIndices(
                shelfRanges: rows,
                focusedShelfIndex: focusRow,
                shelfRadius: OverviewImageWindow.collectionGridShelfRadius,
                imageLimit: OverviewImageWindow.collectionGridMaximumResidentImages
            )
            #expect(window.count <= OverviewImageWindow.collectionGridMaximumResidentImages)
            #expect(window.contains(rows[focusRow].lowerBound))
            if focusRow >= 2 { #expect(window.contains(rows[focusRow - 2].lowerBound)) }
            if focusRow + 2 < rows.count { #expect(window.contains(rows[focusRow + 2].lowerBound)) }
        }

        let oldWindow = Set(OverviewImageWindow.residentIndices(
            shelfRanges: rows, focusedShelfIndex: 2,
            shelfRadius: OverviewImageWindow.collectionGridShelfRadius,
            imageLimit: OverviewImageWindow.collectionGridMaximumResidentImages
        ))
        let newWindow = Set(OverviewImageWindow.residentIndices(
            shelfRanges: rows, focusedShelfIndex: 20,
            shelfRadius: OverviewImageWindow.collectionGridShelfRadius,
            imageLimit: OverviewImageWindow.collectionGridMaximumResidentImages
        ))
        #expect(oldWindow.union(newWindow).count <= OverviewImageWindow.collectionGridMaximumResidentImages * 2,
                "A focus handoff may retain two bounded windows, never the full collection")
    }

    @Test func fitPreservesPortraitAndPanoramaWithinTheTelevisionFrame() {
        let television = CGSize(width: 3_840, height: 2_160)
        let portrait = PhotoImageSizing.requestSize(pixelWidth: 4_000, pixelHeight: 6_000,
                                                   targetSize: television, fillsTarget: false)
        #expect(portrait == CGSize(width: 1_440, height: 2_160))
        let panorama = PhotoImageSizing.requestSize(pixelWidth: 30_000, pixelHeight: 3_000,
                                                   targetSize: television, fillsTarget: false)
        #expect(panorama == CGSize(width: 3_840, height: 384))
    }

    @Test func fillingSmallCardsCannotDecodeAnUnboundedPanorama() {
        let target = CGSize(width: 640, height: 400)
        for dimensions in [(30_000, 300), (300, 30_000), (6_000, 4_000), (120, 80)] {
            let size = PhotoImageSizing.requestSize(pixelWidth: dimensions.0, pixelHeight: dimensions.1,
                                                   targetSize: target, fillsTarget: true)
            #expect(max(size.width, size.height) <= 640)
            #expect(size.width <= Double(dimensions.0) && size.height <= Double(dimensions.1))
        }
    }

    @Test @MainActor func detailStartsWithTheWallPreviewAndIgnoresSmallerDegradedImages() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        let preview = makeImage(width: 40)
        loader.load(assetID: "fixture-photo", targetSize: CGSize(width: 3_840, height: 2_160),
                    contentMode: .aspectFit, initialImage: preview)
        #expect(loader.image === preview)
        #expect(loader.isLoading)
        #expect(requester.requests[0].contentMode == .aspectFit)
        requester.deliver(0, image: makeImage(width: 20), isFinal: false)
        #expect(loader.image === preview)
        let fullImage = makeImage(width: 80)
        requester.deliver(0, image: fullImage, isFinal: true)
        #expect(loader.image === fullImage)
        #expect(!loader.isLoading)
    }

    @Test @MainActor func switchingPhotosCancelsTheRequestAndRejectsLateResults() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        let target = CGSize(width: 640, height: 400)
        loader.load(assetID: "fixture-a", targetSize: target, initialImage: makeImage(width: 40))
        loader.load(assetID: "fixture-b", targetSize: target)
        #expect(requester.cancelledRequests == [0])
        #expect(loader.image == nil)
        requester.deliver(0, image: makeImage(width: 80), isFinal: true)
        #expect(loader.image == nil && loader.isLoading)
        let current = makeImage(width: 60)
        requester.deliver(1, image: current, isFinal: true)
        #expect(loader.image === current)
    }

    @Test @MainActor func leavingAnImageWindowReleasesItsDecodedImageAndRejectsLateDelivery() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        var preview: UIImage? = makeImage(width: 40)
        weak var retainedImage = preview
        loader.load(assetID: "fixture", targetSize: CGSize(width: 640, height: 400), initialImage: preview)
        preview = nil
        #expect(retainedImage != nil)
        loader.cancel()
        #expect(retainedImage == nil)
        #expect(!loader.isLoading && loader.image == nil)
        #expect(requester.cancelledRequests == [0])
        requester.deliver(0, image: makeImage(width: 80), isFinal: true)
        #expect(loader.image == nil)
    }

    @Test @MainActor func suspendingAnOutgoingCellKeepsItsFrameButRejectsLateDelivery() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        let preview = makeImage(width: 40)
        loader.load(assetID: "fixture", targetSize: CGSize(width: 640, height: 400), initialImage: preview)

        loader.suspend()

        #expect(loader.image === preview)
        #expect(loader.loadedAssetID == "fixture")
        #expect(!loader.isLoading)
        #expect(requester.cancelledRequests == [0])
        requester.deliver(0, image: makeImage(width: 80), isFinal: true)
        #expect(loader.image === preview)

        loader.cancel()
        #expect(loader.image == nil && loader.loadedAssetID == nil)
    }

    @Test @MainActor func failedFullImageKeepsTheAlreadyVisiblePreview() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        let preview = makeImage(width: 40)
        loader.load(assetID: "fixture", targetSize: CGSize(width: 3_840, height: 2_160), initialImage: preview)
        requester.requests[0].completion(PhotoImageDelivery(image: nil, isFinal: true, failed: true))
        #expect(loader.image === preview)
        #expect(!loader.isLoading)
    }

    @Test @MainActor func retryBelongsOnlyToTheCurrentFailedPhotoAndClearsOnReloadOrExit() {
        let requester = ControlledPhotoImageRequester()
        let loader = PhotoImageLoader(requester: requester)
        let target = CGSize(width: 3_840, height: 2_160)
        loader.load(assetID: "fixture-a", targetSize: target)
        #expect(!loader.shouldOfferRetry(for: "fixture-a"))
        requester.requests[0].completion(PhotoImageDelivery(image: nil, isFinal: true, failed: true))
        #expect(loader.shouldOfferRetry(for: "fixture-a"))
        #expect(!loader.shouldOfferRetry(for: "fixture-b"))
        loader.load(assetID: "fixture-b", targetSize: target)
        requester.requests[0].completion(PhotoImageDelivery(image: nil, isFinal: true, failed: true))
        #expect(!loader.shouldOfferRetry(for: "fixture-b"))
        requester.requests[1].completion(PhotoImageDelivery(image: nil, isFinal: true, failed: true))
        #expect(loader.shouldOfferRetry(for: "fixture-b"))
        loader.load(assetID: "fixture-b", targetSize: target)
        #expect(!loader.shouldOfferRetry(for: "fixture-b"))
        requester.requests[2].completion(PhotoImageDelivery(image: nil, isFinal: true, failed: true))
        loader.cancel()
        #expect(!loader.shouldOfferRetry(for: "fixture-b"))
    }

    @Test func boundedEmptyPageOffersContinuationUntilCandidatesAreExhausted() {
        #expect(ViewportPhotoWallContentState.resolve(recordCount: 0, isLoading: false, hasMore: true, hasError: false) == .continuation)
        #expect(ViewportPhotoWallContentState.resolve(recordCount: 0, isLoading: false, hasMore: false, hasError: false) == .empty)
        #expect(ViewportPhotoWallContentState.resolve(recordCount: 0, isLoading: true, hasMore: true, hasError: false) == .loading)
        #expect(ViewportPhotoWallContentState.resolve(recordCount: 0, isLoading: false, hasMore: true, hasError: true) == .failed)
        #expect(ViewportPhotoWallContentState.resolve(recordCount: 3, isLoading: false, hasMore: true, hasError: false) == .photos)
    }

    @MainActor private func makeImage(width: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width / 2), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: width / 2))
        }
    }
}

@MainActor
private final class ControlledPhotoImageRequester: PhotoImageRequesting {
    struct Request {
        let contentMode: PHImageContentMode
        let completion: @MainActor (PhotoImageDelivery) -> Void
    }
    var requests: [Request] = []
    var cancelledRequests: [PHImageRequestID] = []

    func updatePriority(_ priority: PhotoImagePriority, for requestID: PHImageRequestID) {}

    func requestImage(_ key: SharedPhotoImageKey, priority: PhotoImagePriority,
                      completion: @escaping @MainActor (PhotoImageDelivery) -> Void) -> PHImageRequestID {
        let id = PHImageRequestID(requests.count)
        requests.append(Request(contentMode: key.fillsTarget ? .aspectFill : .aspectFit, completion: completion))
        return id
    }

    func cancelImageRequest(_ requestID: PHImageRequestID) { cancelledRequests.append(requestID) }

    func deliver(_ index: Int, image: UIImage, isFinal: Bool) {
        requests[index].completion(PhotoImageDelivery(image: image, isFinal: isFinal))
    }
}
