import SwiftUI

/// A quiet, static sky for onboarding and loading scenes. MapKit supplies its own
/// globe sky; this view does not add a second animated renderer behind the map.
struct SpaceBackdrop: View {
    enum Quality {
        case minimal
        case standard
    }

    var quality: Quality = .standard

    var body: some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let background = Path(CGRect(origin: .zero, size: size))
            context.fill(
                background,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.007, green: 0.015, blue: 0.035), .black]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            if quality == .standard {
                // Broad gradients create depth without four full-screen blurred
                // offscreen passes or decorative, permanently frozen meteors.
                context.fill(
                    background,
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 0.025, green: 0.075, blue: 0.13).opacity(0.62), .clear]),
                        center: CGPoint(x: size.width * 0.74, y: size.height * 0.42),
                        startRadius: 0,
                        endRadius: size.width * 0.66
                    )
                )
            }

            let starCount = quality == .minimal ? 64 : Self.stars.count
            var faint = Path()
            var medium = Path()
            var bright = Path()
            for star in Self.stars.prefix(starCount) {
                let diameter = star.diameter
                let rect = CGRect(
                    x: star.x * size.width, y: star.y * size.height,
                    width: diameter, height: diameter
                )
                switch star.brightness {
                case 0: faint.addEllipse(in: rect)
                case 1: medium.addEllipse(in: rect)
                default: bright.addEllipse(in: rect)
                }
            }
            // Three batched fills, with no per-star filters, layers or timers.
            context.fill(faint, with: .color(.white.opacity(0.19)))
            context.fill(medium, with: .color(Color(red: 0.75, green: 0.86, blue: 1).opacity(0.39)))
            context.fill(bright, with: .color(.white.opacity(0.72)))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Star {
        let x: Double
        let y: Double
        let diameter: Double
        let brightness: Int
    }

    // Noise is evaluated once per process, not each time SwiftUI revisits a
    // loading/progress screen. The deterministic field never flickers or jumps.
    private static let stars: [Star] = (0..<180).map { index in
        Star(
            x: pseudoRandom(index * 17 + 3),
            y: pseudoRandom(index * 29 + 11),
            diameter: 0.65 + pseudoRandom(index * 43 + 7) * 1.5,
            brightness: index.isMultiple(of: 13) ? 2 : (index.isMultiple(of: 3) ? 1 : 0)
        )
    }

    private static func pseudoRandom(_ seed: Int) -> Double {
        let value = sin(Double(seed) * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}
