import SwiftUI
import UIKit
import XCTest
@testable import PhotoEarth

final class PhotoWallScrollGeometryTests: XCTestCase {
    @MainActor func testRestoringAPhotoAcrossLayoutsOnlyScrollsVertically() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }

        let records = Array(SampleTravelIndex.make().photos.prefix(48))
        // Restoring a first-row photo uses the top edge after each reflow.
        let targetID = records[1].id
        var contentHeight: CGFloat = 0
        var largestHorizontalOffset: CGFloat = 0
        let wall = ViewportPhotoWall(
            records: records, isLoading: false, hasMore: false, placeLabel: { _ in nil },
            selectPhoto: { _, _ in }, loadMore: {}, close: {}, selectedPhotoID: .constant(targetID)
        )
        .defaultAppStorage(defaults)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            CGRect(origin: geometry.contentOffset, size: geometry.contentSize)
        } action: { _, geometry in
            contentHeight = geometry.height
            largestHorizontalOffset = max(largestHorizontalOffset, abs(geometry.origin.x))
        }
        .ignoresSafeArea()
        window.rootViewController = UIHostingController(rootView: wall)
        window.makeKeyAndVisible()

        for mosaic in [false, true, false] {
            let previousHeight = contentHeight
            defaults.set(mosaic, forKey: "photoEarth.mosaicPhotoWall")
            let changed = NSPredicate { _, _ in contentHeight > window.bounds.height && contentHeight != previousHeight }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5)
            XCTAssertLessThanOrEqual(largestHorizontalOffset, 1, "A wall transition scrolled sideways")
        }
    }
}
