// Run from the repository root after generate_top_shelf_globe.sh.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

struct Receipt: Decodable {
    struct Landmark: Decodable { let verifiedLightDelta: Int }
    let width: Int
    let height: Int
    let pitch: Double
    let pngSHA256: String
    let publicLandmarks: [Landmark]
}

func pixels(_ image: CGImage, piece: CGRect, width: Int, height: Int) throws -> [UInt8] {
    guard let crop = image.cropping(to: piece),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
          let address = context.data else { throw CocoaError(.fileReadCorruptFile) }
    context.interpolationQuality = .high
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Array(UnsafeBufferPointer(start: address.assumingMemoryBound(to: UInt8.self), count: width * height))
}

func matches(_ original: CGImage, _ packaged: CGImage, legal: Bool) throws -> Bool {
    func region(_ image: CGImage) -> CGRect {
        guard legal else { return CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        // Compare the native credit in its own corner at the same relative scale in both files.
        let scale = Double(image.width) / Double(original.width)
        return CGRect(x: 0, y: Double(image.height) - 48 * scale, width: 128 * scale, height: 48 * scale)
    }
    let width = legal ? 64 : 128
    let height = legal ? 24 : 72
    let a = try pixels(original, piece: region(original), width: width, height: height)
    let b = try pixels(packaged, piece: region(packaged), width: width, height: height)
    let meanError = zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / a.count
    return meanError < 8 && Int(a.max() ?? 0) - Int(a.min() ?? 0) > 25
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let raw = repo.appendingPathComponent("Design/TopShelf/MapKit")
let variants: [(String, String, Int, Int)] = [
    ("PublicOrbit", "PhotoEarthTopShelf/EarthShelfGlobe.jpg", 1600, 900),
    ("PublicOrbit", "PhotoEarthTopShelf/EarthShelfGlobePreview.jpg", 1600, 900)
]
for (name, path, width, height) in variants {
    let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: raw.appendingPathComponent(name + ".json")))
    let png = try Data(contentsOf: raw.appendingPathComponent(name + ".png"))
    let jpg = try Data(contentsOf: repo.appendingPathComponent(path))
    guard SHA256.hash(data: png).map({ String(format:"%02x", $0) }).joined() == receipt.pngSHA256,
          receipt.publicLandmarks.count == 6, receipt.publicLandmarks.allSatisfy({ $0.verifiedLightDelta >= 12 }),
          abs(receipt.pitch - 35) < 0.2,
          let source = CGImageSourceCreateWithData(png as CFData, nil),
          let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
          original.width == receipt.width, original.height == receipt.height,
          let compressed = CGImageSourceCreateWithData(jpg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(compressed, 0, nil),
          image.width == width, image.height == height,
          let metadata = CGImageSourceCopyPropertiesAtIndex(compressed, 0, nil) as? [CFString: Any],
          metadata[kCGImagePropertyGPSDictionary] == nil,
          !path.contains("Preview") || jpg.count <= 192 * 1024,
          try matches(original, image, legal: false), try matches(original, image, legal: true) else {
        throw NSError(domain: "PublicMapKitShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: path])
    }
    print("\(width) × \(height)  \(jpg.count) B  \(path)")
}
