import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
#if canImport(TVServices)
import TVServices
#endif
@testable import PhotoEarth

struct JourneyShelfImageURLTests {
    @Test func deliveryCarriesABoundedDecodableImageWithoutAFileOrRemoteHost() throws {
        let context = try #require(CGContext(data: nil, width: 80, height: 45, bitsPerComponent: 8, bytesPerRow: 320,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 45))
        let pixels = try #require(context.makeImage())
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        let url = try #require(JourneyShelfImageURL.make(jpeg: buffer as Data))
        #expect(url.scheme == "data")
        #expect(url.host == nil)
        #expect(try Data(contentsOf: url) == buffer as Data)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 80 && decoded.height == 45)
#if canImport(TVServices)
        let item = TVTopShelfSectionedItem(identifier: "synthetic")
        item.setImageURL(url, for: .screenScale2x)
        #expect(item.imageURL(for: .screenScale2x) == url)
        #expect(item.expirationDate == nil)
#endif
    }

    @Test func invalidOrOversizePreviewsAreNeverPublishedAsImageURLs() {
        #expect(JourneyShelfImageURL.make(jpeg: Data("incomplete".utf8)) == nil)
        var large = Data([0xff, 0xd8])
        large.append(Data(repeating: 0, count: JourneyShelfImageURL.byteLimit))
        large.append(contentsOf: [0xff, 0xd9])
        #expect(JourneyShelfImageURL.make(jpeg: large) == nil)
    }
}
