import SwiftUI

/// One flight per window. Native tab and direct-home layouts supply their own landing point.
@MainActor @Observable
final class OpeningWordmarkFlight {
    var revealedScene: InitialGlobeScene?
    private(set) var destination: CGPoint?
    private(set) var finished = false

    func land(at center: CGPoint, reduceMotion: Bool) {
        guard !finished, destination != center else { return }
        guard !reduceMotion else { finish(); return }
        withAnimation(.timingCurve(0.42, 0, 0.16, 1, duration: 0.88), completionCriteria: .removed) {
            destination = center
        } completion: {
            if self.destination == center { self.finish() }
        }
    }

    func finish() { finished = true }
}

private struct PhotoEarthWordmark: View {
    static let homePointSize: CGFloat = 32
    var pointSize: CGFloat = Self.homePointSize

    var body: some View {
        Text(verbatim: "PHOTO EARTH")
            .font(.custom("AvenirNext-DemiBold", fixedSize: pointSize))
            .tracking(2 * pointSize / Self.homePointSize)
            .fixedSize()
    }
}

struct HomeWordmark: View {
    let scene: InitialGlobeScene
    @Environment(OpeningWordmarkFlight.self) private var opening: OpeningWordmarkFlight?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PhotoEarthWordmark()
            .foregroundStyle(.white.opacity(0.88))
            .frame(height: 45)
            .accessibilityAddTraits(.isHeader)
            .opacity(opening?.finished == false ? 0 : 1)
            .background {
                if let opening, !opening.finished, opening.revealedScene == scene {
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        guard !frame.isEmpty else { return }
                        opening.land(at: CGPoint(x: frame.midX, y: frame.midY), reduceMotion: reduceMotion)
                    }
                }
            }
            .allowsHitTesting(false)
    }
}

struct OpeningPresentation: View {
    let flight: OpeningWordmarkFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsHourglass = false
    private let openingPointSize: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.frame(in: .global)
            let start = CGPoint(x: bounds.width / 2, y: bounds.height * 0.32)
            let landing = flight.destination
            let breathes = landing == nil && !reduceMotion
            ZStack {
                SpaceBackdrop()
                    .background(.black)
                    .opacity(landing == nil ? 1 : 0)
                PhotoEarthWordmark(pointSize: openingPointSize)
                    .phaseAnimator(breathes ? [false, true] : [false]) { wordmark, dimmed in
                        wordmark.opacity(dimmed ? 0.60 : 1)
                    } animation: { _ in
                        .easeInOut(duration: 1.35)
                    }
                    .foregroundStyle(.white)
                    .opacity(landing == nil ? 0.94 : 0.88)
                    .scaleEffect(landing == nil ? 1 : PhotoEarthWordmark.homePointSize / openingPointSize)
                    .position(x: landing.map { $0.x - bounds.minX } ?? start.x,
                              y: landing.map { $0.y - bounds.minY } ?? start.y)
                if showsHourglass && reduceMotion && landing == nil {
                    Image(systemName: "hourglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                        .position(x: start.x, y: start.y + 59)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.string("scanning.title", defaultValue: "Opening PHOTO EARTH…"))
        .accessibilityIdentifier("app-opening")
        .task(id: reduceMotion) {
            guard reduceMotion else { return }
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            showsHourglass = true
        }
    }
}
