import UIKit
import XCTest
@testable import PhotoEarth

@MainActor
final class SlideshowTransitionCanvasTests: XCTestCase {
    func testHighMotionHasDistinctMiddleFramesAndSettlesOnTheFullPhotograph() throws {
        let sample = SampleTravelIndex.make()
        let record = try XCTUnwrap(sample.photos.first)
        let visit = try XCTUnwrap(sample.index.places.first)
        func page(_ resources: [String]) throws -> SlideshowCanvasPage {
            let tiles = try resources.map { name in
                let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "jpg"))
                let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
                return SlideshowCollageFrames.Tile(id: name, ratio: image.size.width / image.size.height, image: image)
            }
            let descriptor = SlideshowPageDescriptor(ids: resources, ratios: tiles.map(\.ratio), visitID: visit.id,
                firstDate: record.creationDate, lastDate: record.creationDate, favorite: false, dynamic: false)
            return .init(descriptor: descriptor, record: record, visit: visit, tiles: tiles)
        }
        let stage = SlideshowTransitionCanvas.Stage(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: stage.bounds, format: format)
        func render(_ page: SlideshowCanvasPage, _ effect: SlideshowEffect? = nil, _ progress: Double = 1) -> UIImage {
            stage.display(page, effect: effect.map { .init(kind: $0, duration: $0.duration) }, progress: progress, waiting: false)
            stage.layoutIfNeeded()
            return renderer.image { stage.layer.render(in: $0.cgContext) }
        }
        let old = try page(["DemoTokyo"])
        let wide = try page(["DemoSydney"])
        let grid = try page(["Collage1", "Collage2", "Collage3"])
        var middleFrames = Set<Data>()
        for kind in [SlideshowEffect.panoramaGlide, .focusPullback, .centerOpen] {
            let next = kind == .centerOpen ? grid : wide
            let expected = try XCTUnwrap(render(next).pngData())
            let start = try XCTUnwrap(render(old).pngData())
            let dissolve = try XCTUnwrap(render(next, .dissolve, 0.5).pngData())
            _ = render(next)
            _ = render(old)
            XCTAssertEqual(render(next, kind, 0).pngData(), start)
            let middle = render(next, kind, 0.5)
            let pixels = try XCTUnwrap(middle.pngData())
            XCTAssertTrue(middleFrames.insert(pixels).inserted)
            XCTAssertNotEqual(pixels, dissolve)
            XCTAssertNotEqual(pixels, expected)
            XCTAssertEqual(render(next, kind, 1).pngData(), expected)
            let attachment = XCTAttachment(image: middle)
            attachment.name = kind.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
