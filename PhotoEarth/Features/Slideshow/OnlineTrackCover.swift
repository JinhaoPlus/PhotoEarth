import CoreGraphics
import Foundation

/// The grid and the now-playing thumbnail share the same small, immutable sRGB print.
nonisolated final class OnlineTrackCover {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func image(title: String, theme: String) -> CGImage? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let key = theme + "\u{0}" + title
        if let image = cache.object(forKey: key as NSString) { return image }
        let side = 400
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(side) / 256, y: -CGFloat(side) / 256)
        let cover = OnlineTrackCover(context: context, seed: key, title: title)
        switch theme {
        case "quiet-moments": cover.lake()
        case "open-road": cover.highway()
        case "piano": cover.staffNotes()
        case "jazz": cover.paperCutout()
        case "lofi": cover.window()
        case "cinematic": cover.cliffs()
        case "synthwave": cover.synthesizer()
        case "chiptune": cover.pixels()
        default: cover.aurora()
        }
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    private let ctx: CGContext
    private let title: String
    private let words: Set<String>
    private var seed: UInt32

    private init(context: CGContext, seed: String, title: String) {
        ctx = context
        self.title = title.lowercased()
        words = Set(self.title.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        self.seed = seed.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    // The prototype uses FNV-1a and Mulberry32. Both are stable across process launches.
    private func sample(_ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat {
        seed &+= 0x6d2b_79f5
        var mix = (seed ^ (seed >> 15)) &* (seed | 1)
        mix ^= mix &+ ((mix ^ (mix >> 7)) &* (mix | 61))
        return lo + (hi - lo) * CGFloat(mix ^ (mix >> 14)) / 4_294_967_296
    }

    private func pick(_ palettes: [[Int]]) -> [Int] { palettes[Int(sample(0, CGFloat(palettes.count)))] }
    private var night: Bool { !words.isDisjoint(with: ["night", "midnight", "moon", "dark"]) }
    private func mentions(_ terms: String...) -> Bool { terms.contains { title.contains($0) } }

    private func color(_ rgb: Int, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }

    private typealias Point = (CGFloat, CGFloat)
    private func point(_ p: Point) -> CGPoint { CGPoint(x: p.0, y: p.1) }

    private func gradient(_ from: Point, _ to: Point, _ colors: [Int]) {
        let stops = colors.map { color($0) } as CFArray
        guard let fill = CGGradient(colorsSpace: Self.space, colors: stops, locations: nil) else { return }
        ctx.drawLinearGradient(
            fill, start: point(from), end: point(to),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func paper(_ colors: [Int]) { gradient((10, 0), (176, 256), colors) }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rgb: Int, alpha: CGFloat = 1) {
        ctx.setFillColor(color(rgb, alpha: alpha))
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    private func disk(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ rgb: Int, alpha: CGFloat = 1) {
        ctx.setFillColor(color(rgb, alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    private func path(_ vertices: [Point]) {
        ctx.beginPath()
        ctx.addLines(between: vertices.map(point))
    }

    private func polygon(_ vertices: [Point], _ rgb: Int, alpha: CGFloat = 1) {
        path(vertices)
        ctx.closePath()
        ctx.setFillColor(color(rgb, alpha: alpha))
        ctx.fillPath()
    }

    private func line(_ start: Point, _ end: Point, _ rgb: Int, _ width: CGFloat, alpha: CGFloat = 1) {
        ctx.setStrokeColor(color(rgb, alpha: alpha))
        ctx.setLineWidth(width)
        ctx.strokeLineSegments(between: [point(start), point(end)])
    }

    private func clipped(_ bounds: CGRect, _ operation: () -> Void) {
        ctx.saveGState()
        ctx.clip(to: bounds)
        operation()
        ctx.restoreGState()
    }

    private func mirror() {
        ctx.translateBy(x: 256, y: 0)
        ctx.scaleBy(x: -1, y: 1)
    }

    private func ridge(_ y: CGFloat, _ height: CGFloat, _ rgb: Int) {
        let frequency = sample(0.009, 0.022)
        let phase = sample(0, 6.28)
        var vertices: [Point] = [(-5, 260)]
        for x in stride(from: CGFloat(-5), through: 265, by: 5) {
            let wave = sin(phase + x * frequency) + 0.23 * sin(x * frequency * 2.8 + phase)
            vertices.append((x, y + height * wave))
        }
        polygon(vertices + [(265, 260)], rgb)
    }

    private func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ rgb: Int, alpha: CGFloat) {
        let stops = [color(rgb, alpha: alpha), color(rgb, alpha: 0)] as CFArray
        guard let fill = CGGradient(colorsSpace: Self.space, colors: stops, locations: nil) else { return }
        let center = CGPoint(x: x, y: y)
        ctx.drawRadialGradient(fill, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
    }

    private func lake() {
        let snow = !words.isDisjoint(with: ["snow", "ice", "winter", "cold", "fog"])
        let palette =
            !snow && sample() < 0.48
            ? [0xedd5ad, 0xf5e3c7, 0x9bb5ac, 0x6d9994, 0x365d63]
            : [0x9abfc7, 0xf2e7d8, 0xb7cfd0, 0x89adb0, 0x517983]
        paper(Array(palette.prefix(2)))
        let x = sample(46, 212)
        let y = sample(39, 91)
        disk(x, y, sample(18, 33), 0xfff6da)
        if snow {
            for _ in 0..<52 { disk(sample(0, 256), sample(0, 152), sample(0.42, 1.45), 0xfffcf4, alpha: 0.72) }
        }
        ridge(sample(112, 131), 12, palette[2])
        ridge(sample(137, 157), 17, palette[3])
        ridge(sample(162, 186), 14, palette[4])
        let shore = sample(179, 199)
        clipped(CGRect(x: 0, y: shore, width: 256, height: 256 - shore)) {
            gradient((0, shore), (0, 256), [palette[2], palette[0]])
        }
        for _ in 0..<50 {
            let depth = sample()
            let offset = sample(-1, 1) * (4 + depth * 28)
            rect(x + offset, shore + depth * (256 - shore), sample(2, 9), 0.9, 0xfffae1, alpha: 0.63)
        }
    }

    private func highway() {
        let p =
            night
            ? [0x171c40, 0x79647f, 0xf7a16f, 0x4d4967, 0x222b44, 0xe7ac91]
            : pick([
                [0xdd8c65, 0xffdfa5, 0xfff0ae, 0xb87359, 0x77484a, 0xffd789],
                [0x6baea4, 0xf6deaf, 0xffdb9e, 0x839577, 0x385b58, 0xf0cc91],
            ])
        paper(Array(p.prefix(2)))
        if sample() < 0.5 { mirror() }
        let horizon = sample(89, 135)
        let vanishingX = sample(80, 178)
        disk(sample(45, 201), horizon - sample(18, 44), sample(16, 31), p[2])
        if night {
            for _ in 0..<36 { disk(sample(0, 256), sample(0, horizon * 0.72), sample(0.4, 1.1), 0xf6dda9, alpha: 0.73) }
        }
        ridge(horizon, 10, p[3])
        let bend = sample(25, 71)
        var left: [Point] = []
        var right: [Point] = []
        var center: [Point] = []
        for i in 0...96 {
            let t = CGFloat(i) / 96
            let width = 2 + 91 * t * t
            let x = vanishingX + bend * sin(t * 6) * t - 71 * t * t
            let y = horizon + (260 - horizon) * t
            left.append((x - width, y))
            right.append((x + width, y))
            center.append((x, y))
        }
        polygon(left + right.reversed(), p[4])
        for i in 0..<96 where sin(32 * log(CGFloat(i + 12) / 106)) > 0 {
            line(center[i], center[i + 1], p[5], 0.7 + 3 * CGFloat(i) / 96)
        }
    }

    private func staffNotes() {
        let palette = pick([
            [0xffb4a2, 0xed817f, 0x481d36],
            [0x254d83, 0x30275d, 0xfff1cf],
            [0xa9e8d0, 0x65c5ba, 0x103e41],
            [0xffd784, 0xefab53, 0x482b35],
            [0xdfc1fb, 0xac98e7, 0x362751],
            [0x175c68, 0x163e50, 0xd9f7db],
            [0xffc1c7, 0xea8bae, 0x501b45],
            [0xbae9ff, 0x84b7ef, 0x183758],
            [0x82445e, 0x48314e, 0xffe4be],
            [0xdae99a, 0xa5cc7e, 0x283d2a],
        ])
        paper(Array(palette.prefix(2)))
        let ink = palette[2]
        ctx.translateBy(x: 128, y: sample(119, 139))
        ctx.rotate(by: sample(-0.13, 0.06))
        let spacing = sample(15, 19)
        for i in -2...2 {
            let y = CGFloat(i) * spacing
            line((-175, y), (175, y), ink, 1.6, alpha: 0.57)
        }

        let count = Int(sample(4, 7))
        let joined = Int(sample(0, CGFloat(count - 1)))
        let hollow = (joined + 2) % count
        var notes: [Point] = []
        for i in 0..<count {
            let x = -104 + CGFloat(i) * 208 / CGFloat(count - 1) + sample(-4, 4)
            let y = CGFloat(Int(sample(0, 11)) - 5) * spacing / 2
            notes.append((x, y))
        }

        let width = spacing * 1.43, height = spacing * 0.93
        let pairDirection: CGFloat = notes[joined].1 + notes[joined + 1].1 >= 0 ? -1 : 1
        let beamStart = (pairDirection < 0 ? min(notes[joined].1, notes[joined + 1].1)
                                          : max(notes[joined].1, notes[joined + 1].1)) + pairDirection * spacing * 3
        let beamSlope = min(5, max(-5, (notes[joined + 1].1 - notes[joined].1) / 4))
        var beam: [Point] = []
        for (i, note) in notes.enumerated() {
            let paired = i == joined || i == joined + 1
            let direction: CGFloat = paired ? pairDirection : (note.1 < 0 ? 1 : -1)
            let stemX = note.0 - direction * (width * 0.46 - 1)
            let tip = paired ? beamStart + (i == joined ? 0 : beamSlope) : note.1 + direction * spacing * 3
            line((stemX, note.1 + direction * 2), (stemX, tip), ink, 2.7)
            if paired { beam.append((stemX, tip)) }

            ctx.saveGState()
            ctx.translateBy(x: note.0, y: note.1)
            ctx.rotate(by: -0.35)
            ctx.addEllipse(in: CGRect(x: -width/2, y: -height/2, width: width, height: height))
            if i == hollow {
                ctx.addEllipse(in: CGRect(x: -width*0.30, y: -height*0.19, width: width*0.60, height: height*0.38))
            }
            ctx.setFillColor(color(ink))
            ctx.drawPath(using: .eoFill)
            ctx.restoreGState()
        }
        let thickness = -pairDirection * spacing * 0.38
        polygon([beam[0], beam[1], (beam[1].0, beam[1].1 + thickness), (beam[0].0, beam[0].1 + thickness)], ink)
    }

    private func paperCutout() {
        let p =
            night
            ? [0x182944, 0xe59164, 0x488b9a, 0xf2cd8a]
            : pick([
                [0xe6bb56, 0x202b35, 0xcc5538, 0xf2d9aa], [0xd86547, 0x242838, 0xe9b956, 0xf6d5ac],
                [0x7aa7a0, 0x1d2d3c, 0xda6845, 0xf5cf92],
            ])
        rect(0, 0, 256, 256, p[0])
        if sample() < 0.5 { mirror() }
        ctx.translateBy(x: sample(-12, 26), y: sample(-16, 16))
        ctx.rotate(by: sample(-0.15, 0.1))
        let x = sample(70, 119)
        let y = sample(83, 132)
        ctx.setStrokeColor(color(p[1]))
        ctx.setLineWidth(sample(34, 49))
        ctx.addArc(center: point((x, y)), radius: 83, startAngle: .pi * 0.09, endAngle: .pi * 1.55, clockwise: false)
        ctx.strokePath()
        if mentions("barriers", "static", "bar", "stretch") {
            for i in 0..<4 {
                let a = CGFloat(i) * 43
                let b = CGFloat(i) * 7
                polygon(
                    [(12 + a, 52 - b), (31 + a, 47 - b), (79 + a, 209), (56 + a, 217)],
                    i.isMultiple(of: 2) ? p[2] : p[3])
            }
        } else {
            polygon([(x - 8, y + 14), (262, sample(3, 48)), (172, y + 83)], p[2])
        }
        disk(sample(136, 189), sample(40, 69), sample(18, 34), p[3])
        for i in 0..<4 {
            let a = CGFloat(i) * 9
            line((115 + a, 166), (81 + a, 261), p[1], 3.3)
        }
        for i in 0..<5 {
            for j in 0..<4 { disk(CGFloat(203 + i * 6), CGFloat(187 + j * 7), 1.65, p[1]) }
        }
    }

    private func window() {
        let p = pick([
            [0xb57e86, 0xa9a6cb, 0xf7c6a1, 0x51475d], [0xb4a29a, 0x98b9b0, 0xffddad, 0x475658],
            [0x9d91ac, 0xbba7cf, 0xf4c2b2, 0x524765],
        ])
        paper([p[0], p[2]])
        if sample() < 0.5 { mirror() }
        let x = sample(42, 70)
        let y = sample(22, 53)
        let w = sample(119, 151)
        let h = sample(115, 149)
        let skew = sample(40, 92)
        let sill = y + h
        ctx.saveGState()
        path([(x, sill), (x + w, sill), (x + w - skew, 263), (x - skew, 263)])
        ctx.clip()
        gradient((0, sill), (0, 260), [p[2], p[0]])
        ctx.restoreGState()
        rect(x - 6, y - 6, w + 12, h + 13, p[3])
        clipped(CGRect(x: x, y: y, width: w, height: h)) {
            gradient((x, y), (x + w, sill), [p[1], p[2]])
            disk(x + w * sample(0.3, 0.76), y + h * sample(0.17, 0.45), sample(11, 19), 0xfff0d1)
            for i in stride(from: CGFloat(0), to: w, by: 11) {
                let building = sample(9, 37)
                rect(x + i, sill - building, 12, building, p[0])
            }
        }
        rect(x + w * 0.57, y, 4, h, p[3])
        rect(x, y + h * 0.51, w, 4, p[3])
        line((x + w * 0.57 + 2, sill + 8), (x + w * 0.57 + 2 - skew, 260), p[0], 4)
        rect(x - 11, sill + 6, w + 22, 6, p[3])
        if mentions("coffee", "ramen", "morning") {
            let cx = x + w * 0.27
            let bottom = sill + 5
            ctx.setStrokeColor(color(p[3]))
            ctx.setLineWidth(3.5)
            ctx.strokeEllipse(in: CGRect(x: cx + 6, y: bottom - 18, width: 14, height: 12))
            polygon([(cx - 14, bottom - 21), (cx + 13, bottom - 21), (cx + 10, bottom), (cx - 9, bottom)], p[3])
            line((cx - 11, bottom - 19), (cx + 10, bottom - 19), p[2], 1.5)
        } else if mentions("laundry", "wire") {
            ctx.move(to: point((0, y + 14)))
            ctx.addQuadCurve(to: point((256, y + 21)), control: point((122, y + 57)))
            ctx.setStrokeColor(color(p[3]))
            ctx.setLineWidth(1.6)
            ctx.strokePath()
            for i in 0..<4 {
                let xx = x + CGFloat(i * 33)
                let t = xx / 256
                let yy = y + 14 + 86 * t - 79 * t * t
                polygon(
                    [(xx, yy), (xx + 22, yy + 1), (xx + 18, yy + 18 + CGFloat(i % 2) * 7), (xx - 3, yy + 15)],
                    i.isMultiple(of: 2) ? p[0] : p[2])
            }
        }
    }

    private func aurora() {
        let p = pick([
            [0x122d45, 0x83dace, 0x9396e8], [0x24203d, 0xb7a0df, 0x8bcfdb], [0x13323c, 0x9bd8a0, 0x82bdda],
        ])
        paper([p[0], 0x172439])
        let phase = sample(0, 6.28)
        let tilt = sample(-45, 45)
        ctx.setBlendMode(.screen)
        glow(sample(25, 215), sample(60, 200), 148, p[2], alpha: 0.53)
        ctx.setLineWidth(2.1)
        for i in 0..<140 {
            let t = CGFloat(i) / 139
            ctx.beginPath()
            for x in stride(from: CGFloat(-4), through: 261, by: 3) {
                let y = 57 + 132 * t + sin(x / 57 + phase + t * 2.4) * (28 + 31 * t) + (x / 256 - 0.5) * tilt
                let position = CGPoint(x: x, y: y)
                if x == -4 { ctx.move(to: position) } else { ctx.addLine(to: position) }
            }
            ctx.setStrokeColor(color(i < 70 ? p[2] : p[1], alpha: 0.055 + 0.32 * pow(t, 5)))
            ctx.strokePath()
        }
    }

    private func cliffs() {
        let p = pick([
            [0x334756, 0xddc9a1, 0x7f8580, 0x182b33], [0x43394d, 0xe8b995, 0x917c78, 0x262634],
            [0x263f4d, 0xc4d9cc, 0x778c90, 0x172a36],
        ])
        paper([p[0], p[1], p[1]])
        if sample() < 0.5 { mirror() }
        let x = sample(144, 195)
        let h = sample(148, 177)
        disk(x, h - sample(57, 96), sample(15, 30), 0xfce8c1)
        ridge(h - 17, 11, p[2])
        ridge(h + 15, 19, p[0])
        let top = sample(18, 65)
        let w = sample(81, 111)
        polygon([(-6, 268), (-6, top + 34), (w - 21, top), (w, top + 3), (w - 4, h + 26), (w + 22, 268)], p[3])
        polygon([(w - 21, top), (w, top + 3), (w - 4, h + 26), (w - 16, h + 8)], p[2])
        polygon([(-6, 255), (91, h + 24), (179, h + 13), (262, h + 29), (262, 266)], p[3])
        line((0, 254), (154, h + 18), p[1], 1.2)
    }

    private func synthesizer() {
        let p = pick([
            [0x201443, 0x923e81, 0xfa7494, 0x6fe6ed], [0x211b48, 0x794aa5, 0xfb689a, 0xbd9afe],
            [0x192349, 0x5d4a9c, 0xef6b9f, 0x79d9e3],
        ])
        paper([p[0], p[1], p[0]])
        if mentions("synth", "computer", "machine", "electronic") {
            glow(174, 102, 130, p[2], alpha: 0.38)
            let phase = sample(-2, 2)
            let frequency = sample(2.4, 4)
            for i in 0..<37 {
                let row = CGFloat(i)
                var edge: [Point] = []
                for x in stride(from: CGFloat(-6), through: 264, by: 3) {
                    let envelope = sin(.pi * min(1, max(0, x / 256)))
                    let wave = sin(x / 256 * .pi * frequency + phase + row * 0.063) + 0.37 * cos(x / 22 - row * 0.075)
                    edge.append((x, 73 + row * 4.2 - wave * envelope * 30))
                }
                polygon([(-6, 266)] + edge + [(265, 266)], p[0])
                ctx.saveGState()
                path(edge)
                ctx.setLineWidth(1.35)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                gradient((10, 0), (245, 0), [p[2], p[3], 0xe4b0ff])
                ctx.restoreGState()
            }
        } else {
            let x = sample(77, 185)
            let h = sample(135, 162)
            let radius = sample(43, 63)
            let y = h - radius * 0.81
            glow(x, y, radius * 1.75, p[2], alpha: 0.53)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            ctx.clip()
            ctx.addRect(CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: radius * 0.96))
            for i in 0..<8 {
                let band = CGFloat(i)
                ctx.addRect(
                    CGRect(
                        x: x - radius, y: y - radius * 0.04 + band * radius / 8,
                        width: 2 * radius, height: radius / 8 * (0.91 - band * 0.09)))
            }
            ctx.clip()
            gradient((0, y - radius), (0, y + radius), [0xffe298, 0xff978a, p[2]])
            ctx.restoreGState()
            ridge(h, 9, p[0])
            clipped(CGRect(x: 0, y: h + 5, width: 256, height: 256 - h)) {
                gradient((0, h), (0, 256), [p[0], 0x16162f])
            }
            for i in -6...6 { line((x, h + 5), (x + CGFloat(i * 72), 260), p[3], 1.15, alpha: 0.55) }
            for d: CGFloat in [4, 9, 17, 29, 48, 76, 110] { line((0, h + d), (256, h + d), p[3], 1.15, alpha: 0.72) }
        }
    }

    private func sprite(_ rows: [String], at origin: Point, scale: CGFloat, fill: Int, shadow: Int? = nil) {
        for (row, pixels) in rows.enumerated() {
            for (column, bit) in pixels.enumerated() where bit != "0" {
                rect(
                    origin.0 + CGFloat(column) * scale, origin.1 + CGFloat(row) * scale, scale, scale,
                    bit == "2" ? shadow ?? fill : fill)
            }
        }
    }

    private func pixels() {
        let p = pick([
            [0x24223d, 0xfcd48d, 0x806891, 0x41586e, 0x93d5be], [0x222640, 0xffdc98, 0xac7aa3, 0x365061, 0x8edbbb],
            [0x302342, 0xf3bb83, 0xa66d91, 0x5b4c79, 0x83d3c5],
        ])
        rect(0, 0, 256, 256, p[0])
        let x = floor(sample(7, 24)) * 8
        let y = floor(sample(5, 13)) * 8
        if mentions("asteroid", "space", "star", "scroller") {
            for _ in 0..<48 { rect(floor(sample(0, 32)) * 8, floor(sample(0, 32)) * 8, 2.5, 2.5, p[4]) }
            let rock = ["0011100", "0111110", "1111211", "1112221", "1122211", "0111110", "0011000"]
            sprite(rock, at: (32, 24), scale: 6, fill: p[2], shadow: p[3])
            sprite(rock, at: (160, 104), scale: 8, fill: p[2], shadow: p[3])
            sprite(rock, at: (88, 184), scale: 4, fill: p[2], shadow: p[3])
            sprite(["00100", "01110", "11111", "10101"], at: (x - 64, y + 80), scale: 8, fill: p[1])
        } else {
            sprite(["01110", "11111", "11111", "11111", "01110"], at: (x, y), scale: 8, fill: p[1])
            for _ in 0..<24 { rect(floor(sample(0, 32)) * 8, floor(sample(0, 19)) * 8, 2, 2, p[1]) }
            let phase = sample(0, 7)
            for i in 0..<32 {
                let column = CGFloat(i)
                let hill = (18 + sin(column / 4 + phase) * 3 + sin(column / 2) * 2).rounded() * 8
                let ground = (25 + sin(column / 5 + phase) * 4).rounded() * 8
                rect(column * 8, hill, 8, 256, p[2])
                rect(column * 8, ground, 8, 256, p[3])
                rect(column * 8, ground, 8, 8, p[4])
                if i.isMultiple(of: 3) { rect(column * 8, ground + 16, 8, 8, p[0]) }
            }
        }
    }
}
