import SwiftUI

enum CoverDisplayPhase {
    case waiting, displayed, idle
}

// The selection placeholder and the PhotoKit view are different children of the
// same card. Keep their indicator on the card so its delay spans both phases.
struct CoverDisplayPreference: PreferenceKey {
    static let defaultValue = CoverDisplayPhase.idle
    static func reduce(value: inout CoverDisplayPhase, nextValue: () -> CoverDisplayPhase) {
        value = nextValue()
    }
}

struct CoverLoadingOverlay: View {
    let phase: CoverDisplayPhase
    let focused: Bool
    var usesGlassBackground = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var showing = false

    private var waiting: Bool { visible && scenePhase == .active && phase == .waiting }

    var body: some View {
        Color.clear
            .overlay {
                if phase == .waiting || showing {
                    WaitingCoverView(usesGlassBackground: usesGlassBackground)
                        .overlay {
                            if !showing {
                                EmptyView()
                            } else if reduceMotion {
                                frameMark(angle: .degrees(45))
                            } else {
                                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                                    let time = context.date.timeIntervalSinceReferenceDate
                                    frameMark(angle: .degrees(time.truncatingRemainder(dividingBy: 1.85) / 1.85 * 360))
                                }
                            }
                        }
                        .transition(.opacity)
                }
            }
            .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
            .task(id: waiting) {
                guard waiting else {
                    withAnimation(phase == .displayed && visible && !reduceMotion ? .easeOut(duration: 0.32) : nil) {
                        showing = false
                    }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                showing = true
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func frameMark(angle: Angle) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(AngularGradient(
                stops: [
                    .init(color: .white.opacity(0.94), location: 0),
                    .init(color: .white.opacity(0.30), location: 0.05),
                    .init(color: .white.opacity(0.30), location: 0.72),
                    .init(color: .white.opacity(0.94), location: 1)
                ], center: .center, angle: angle), lineWidth: 2)
            .frame(width: focused ? 44 : 38, height: focused ? 30 : 26)
            .opacity(focused ? 1 : 0.78)
    }
}
