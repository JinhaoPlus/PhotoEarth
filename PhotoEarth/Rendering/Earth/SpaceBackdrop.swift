import SwiftUI

struct SpaceBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.005, green: 0.012, blue: 0.035), .black]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            drawAurora(in: &context, size: size)
            drawConstellations(in: &context, size: size)

            for index in 0..<230 {
                let x = pseudoRandom(index * 17 + 3) * size.width
                let y = pseudoRandom(index * 29 + 11) * size.height
                let radius = 0.7 + pseudoRandom(index * 43 + 7) * 2.8
                let opacity = 0.2 + pseudoRandom(index * 13 + 5) * 0.76
                let color = index.isMultiple(of: 9) ? Color.cyan : Color.white
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(color.opacity(opacity))
                )
            }

            drawMeteors(in: &context, size: size)
        }
        .ignoresSafeArea()
        .overlay {
            RadialGradient(
                colors: [Color.blue.opacity(0.13), .clear],
                center: UnitPoint(x: 0.37, y: 0.48),
                startRadius: 80,
                endRadius: 850
            )
            .ignoresSafeArea()
        }
    }

    private func drawAurora(in context: inout GraphicsContext, size: CGSize) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 62))
            for band in 0..<4 {
                var ribbon = Path()
                let y = size.height * (0.2 + Double(band) * 0.11)
                ribbon.move(to: CGPoint(x: -120, y: y))
                ribbon.addCurve(
                    to: CGPoint(x: size.width + 120, y: y + size.height * 0.12),
                    control1: CGPoint(x: size.width * 0.24, y: y - size.height * 0.18),
                    control2: CGPoint(x: size.width * 0.67, y: y + size.height * 0.28)
                )
                layer.stroke(
                    ribbon,
                    with: .linearGradient(
                        Gradient(colors: [
                            .clear,
                            Color(red: 0.05, green: 0.92, blue: 0.68).opacity(0.2),
                            Color.cyan.opacity(0.12),
                            .clear,
                        ]),
                        startPoint: CGPoint(x: 0, y: y),
                        endPoint: CGPoint(x: size.width, y: y)
                    ),
                    lineWidth: 34 + Double(band) * 9
                )
            }
        }
    }

    private func drawConstellations(in context: inout GraphicsContext, size: CGSize) {
        for group in 0..<8 {
            var line = Path()
            let base = CGPoint(
                x: pseudoRandom(group * 101 + 7) * size.width,
                y: pseudoRandom(group * 83 + 13) * size.height * 0.65
            )
            for point in 0..<4 {
                let seed = group * 101 + point * 19
                let location = CGPoint(
                    x: base.x + (pseudoRandom(seed + 7) - 0.5) * 190,
                    y: base.y + (pseudoRandom(seed + 31) - 0.5) * 130
                )
                if point == 0 {
                    line.move(to: location)
                } else {
                    line.addLine(to: location)
                }
            }
            context.stroke(line, with: .color(.cyan.opacity(0.1)), lineWidth: 1)
        }
    }

    private func drawMeteors(in context: inout GraphicsContext, size: CGSize) {
        for index in 0..<9 {
            let x = pseudoRandom(index * 71 + 4) * size.width
            let y = pseudoRandom(index * 37 + 18) * size.height * 0.76
            let length = 70 + pseudoRandom(index * 53 + 1) * 150
            var meteor = Path()
            meteor.move(to: CGPoint(x: x - length * 0.46, y: y - length))
            meteor.addLine(to: CGPoint(x: x, y: y))
            context.stroke(
                meteor,
                with: .linearGradient(
                    Gradient(colors: [.clear, .cyan.opacity(0.32), .white.opacity(0.9)]),
                    startPoint: CGPoint(x: x - length * 0.46, y: y - length),
                    endPoint: CGPoint(x: x, y: y)
                ),
                style: StrokeStyle(lineWidth: index.isMultiple(of: 3) ? 2.2 : 1.1, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                with: .color(.white.opacity(0.9))
            )
        }
    }

    private func pseudoRandom(_ seed: Int) -> Double {
        let value = sin(Double(seed) * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}
