import SwiftUI

/// The existing full-screen map supplies a neutral Earth before permission.
/// No fictional personal lights are drawn on the welcome screen.
struct WelcomeView: View {
    let begin: () -> Void
    let showDemo: () -> Void
    @Namespace private var welcomeFocus
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case connect, sample }


    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text(AppLocalization.string("welcome.title", defaultValue: "See Your Photos on the Globe"))
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("welcome.message", defaultValue: "Photo Earth uses capture dates, locations, and camera information on this Apple TV to build your travel globe. You can exclude albums from the scan."))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
            GlassEffectContainer(spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    Button(AppLocalization.string("welcome.connect", defaultValue: "Connect Photo Library"), action: begin)
                        .focused($focusedAction, equals: .connect)
                        .accessibilityIdentifier("welcome-connect")
                    Button(AppLocalization.string("sample.view_first", defaultValue: "Explore a Sample Journey"), action: showDemo)
                        .focused($focusedAction, equals: .sample)
                        .accessibilityIdentifier("welcome-demo")
                }
                .buttonStyle(.glass)
                .font(.system(size: 25, weight: .medium))
            }
            .padding(.top, 12)
            Spacer()
        }
        .focusScope(welcomeFocus)
        .defaultFocus($focusedAction, .connect, priority: .userInitiated)
        .task(id: scenePhase) {
            // The persistent map and the window may exist before an active
            // welcome page. Set a real button target once this scene can focus.
            guard scenePhase == .active else { return }
            await Task.yield()
            guard !Task.isCancelled, focusedAction == nil else { return }
            focusedAction = .connect
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(.horizontal, 80).padding(.top, 60).padding(.bottom, 104)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            LinearGradient(stops: [.init(color: .black.opacity(0.86), location: 0),
                                   .init(color: .black.opacity(0.65), location: 0.4),
                                   .init(color: .clear, location: 0.82)],
                           startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }
}
