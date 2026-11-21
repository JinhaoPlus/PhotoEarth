// Procedural test charts: no source photograph, private content or image edits.
// Run from the project directory with Xcode's Swift runtime.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

for (name, width, height, red, green, blue) in [
    ("RatioLandscape", 1200, 800, 0.12, 0.32, 0.40),
    ("RatioPortrait", 800, 1200, 0.32, 0.16, 0.40),
    ("RatioPanorama", 2400, 800, 0.40, 0.26, 0.12),
] {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); context.setLineWidth(3)
    for n in 1..<8 {
        let x = CGFloat(width) * CGFloat(n) / 8, y = CGFloat(height) * CGFloat(n) / 8
        context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
        context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: CGFloat(width), y: y))
    }
    context.strokePath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); context.setLineWidth(12)
    context.stroke(CGRect(x: 20, y: 20, width: width - 40, height: height - 40))
    let diameter = min(width, height) / 2
    context.strokeEllipse(in: CGRect(x: (width - diameter) / 2, y: (height - diameter) / 2, width: diameter, height: diameter))
    context.setFillColor(CGColor(red: 0.9, green: 0.65, blue: 0.25, alpha: 1))
    for x in [38, width - 98] { for y in [38, height - 98] { context.fill(CGRect(x: x, y: y, width: 60, height: 60)) } }
    let url = URL(fileURLWithPath: "PhotoEarth/Resources/\(name).png")
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
}
