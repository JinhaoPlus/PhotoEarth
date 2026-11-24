import SwiftUI
import UIKit

struct LibraryPreparationView: View {
    @ObservedObject var model: AppModel
    @Binding var followsDiscoveries: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Action?
    private enum Action: Hashable { case status, browse, scope, pause, camera }
    private var progress: LibraryPreparationProgress { model.preparationProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(progress.title)
                .font(.system(size: 56, weight: .light))
                .accessibilityAddTraits(.isHeader)
                .focusable()
                .focusEffectDisabled()
                .focused($focus, equals: .status)
                .accessibilityIdentifier("preparation-status")
            if progress.mode == .rebuild && progress.phase.isWorking {
                Text(AppLocalization.string("preparation.hero.rebuild", defaultValue: "Existing place names are kept."))
                    .font(.system(size: 25)).foregroundStyle(.secondary)
                    .padding(.top, 16)
            }
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 18) {
                if progress.phase != .complete, model.isInitialLibraryReady, let index = model.index {
                    Text(AppLocalization.format("preparation.ready.count", defaultValue: "Ready to explore: %1$@ · %2$@",
                                                AppLocalization.itemCount(index.locatedPhotoCount),
                                                AppLocalization.visitCount(index.places.count)))
                        .font(.system(size: 32, weight: .light))
                        .accessibilityIdentifier("preparation-ready")
                }
                if progress.phase == .labeling, let place = model.recentlyPreparedPlace, PlaceDisplayLabel(place: place).isComplete {
                    let name = PlaceDisplayLabel(place: place).styledName(citySize: 32)
                    Text(AttributedString(localized: "preparation.recent_place", defaultValue: "Just added · \(name)",
                                          locale: AppLocalization.locale))
                        .font(.system(size: 32, weight: .light))
                        .transition(.opacity)
                }
                Text(progress.countText)
                    .font(.system(size: 26)).monospacedDigit().foregroundStyle(.white.opacity(0.78))
                    .accessibilityIdentifier(model.isInitialLibraryReady && progress.phase == .complete ? "preparation-ready" : "preparation-count")
                if let fraction = progress.fraction {
                    Capsule().fill(.white.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 640 * fraction)
                        }
                        .frame(width: 640, height: 5)
                        .accessibilityHidden(true)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(5).frame(maxWidth: 1050, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .floatingSurface(in: RoundedRectangle(cornerRadius: 26))
            .padding(.bottom, 28)

            GlassEffectContainer(spacing: TVControlLayout.actionSpacing) {
                HStack(spacing: TVControlLayout.actionSpacing) {
                    if model.phase == .scanning && model.canBrowsePreparedLibrary {
                        Button(AppLocalization.string("preparation.browse_now", defaultValue: "Explore Now"), action: {
                            ProductAnalytics.shared.capture(.preparationAction, value: "browse_now")
                            model.closePreparation()
                        })
                            .focused($focus, equals: .browse)
                            .accessibilityIdentifier("preparation-browse")
                    }

                    if model.usesLivePhotoLibrary && progress.phase == .failed {
                        Button(AppLocalization.string("scan.scope.title", defaultValue: "Albums to Exclude from Scanning"), action: { model.showScanScope(from: .preparation) })
                            .focused($focus, equals: .scope)
                            .accessibilityIdentifier("preparation-scan-scope")
                    }
                    if progress.phase.isWorking || progress.phase == .paused || progress.phase == .failed {
                        Button(scanActionTitle) {
                            Task {
                                if progress.phase.isWorking { await model.pausePreparation() }
                                else { await model.resumePreparation() }
                            }
                        }
                        .focused($focus, equals: .pause)
                        .accessibilityIdentifier("preparation-pause")
                    }
                    if !reduceMotion && progress.phase.isWorking {
                        Button(followsDiscoveries
                            ? AppLocalization.string("preparation.pause_camera", defaultValue: "Pause Camera Movement")
                            : AppLocalization.string("preparation.follow_places", defaultValue: "Follow New Places")) {
                                followsDiscoveries.toggle()
                                ProductAnalytics.shared.capture(.preparationAction, value: followsDiscoveries ? "follow_camera" : "pause_camera")
                            }
                            .focused($focus, equals: .camera)
                            .accessibilityIdentifier("preparation-camera")
                    }
                }
                .buttonStyle(.glass)
                .font(.system(size: 24, weight: .medium))
                .focusSection()
            }
        }
        .padding(.horizontal, 80).padding(.top, 80).padding(.bottom, 104)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        .defaultFocus($focus, .status)
        .onAppear {
            focus = .status
            if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
                model.retainPreparationFocus()
            }
        }
        .onChange(of: focus) { _, action in
            if action == .browse || action == .scope || action == .pause || action == .camera { model.retainPreparationFocus() }
        }
        .onExitCommand { model.closePreparation() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-preparation")
    }

    private var scanActionTitle: String {
        if progress.phase.isWorking { return AppLocalization.string("preparation.pause", defaultValue: "Pause Scan") }
        if progress.phase == .failed { return AppLocalization.string("common.retry", defaultValue: "Try Again") }
        return AppLocalization.string("preparation.continue", defaultValue: "Continue")
    }

    private var detail: String? {
        if let notice = progress.notice { return notice.text() }
        switch progress.phase {
        case .checking:
            return AppLocalization.format("preparation.detail.checking", defaultValue: "%lld items with location data", Int64(progress.locatedPhotos))
        case .paused:
            return AppLocalization.string("preparation.detail.paused", defaultValue: "Your scan will resume where you left off.")
        default:
            return nil
        }
    }
}

struct LibraryPreparationEntry: View {
    let progress: LibraryPreparationProgress
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.22), lineWidth: 2)
                    if let fraction = progress.fraction {
                        Circle().trim(from: 0, to: fraction).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    } else {
                        Image(systemName: progress.phase == .paused ? "pause.fill" : "globe.asia.australia")
                            .font(.system(size: 18))
                    }
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.phase == .complete
                        ? AppLocalization.string("preparation.entry.updated", defaultValue: "Photos & Places · Updated")
                        : progress.title).font(.system(size: 22, weight: .medium))
                    if progress.phase != .idle && progress.phase != .complete {
                        Text(progress.countText).font(.system(size: 19)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("library-preparation-entry")
        .accessibilityLabel(AppLocalization.format("preparation.accessibility", defaultValue: "Scan progress, %1$@, %2$@", progress.title, progress.countText))
    }
}

/// Lives inside each native Tab content so the system can navigate between the
/// page and this header. The full-width focus section bridges the empty space.
struct LibraryPreparationChrome: ViewModifier {
    @ObservedObject var model: AppModel
    var aboveHomeActions = false
    func body(content: Content) -> some View {
        content.overlay(alignment: aboveHomeActions ? .topLeading : .topTrailing) {
            LibraryPreparationPageEntry(model: model)
                .frame(maxWidth: .infinity, alignment: aboveHomeActions ? .leading : .trailing)
                .focusSection()
                .padding(.top, 48).padding(.horizontal, 80)
        }
    }
}

struct LibraryPreparationPageEntry: View {
    @ObservedObject var model: AppModel
    @FocusState private var entryFocused: Bool
    @State private var restoresEntry = false
    private var showsEntry: Bool {
        !model.isUsingSampleData
            && model.preparationProgress.phase != .complete
            && model.preparationProgress.phase != .partial
    }

    var body: some View {
        if showsEntry {
            LibraryPreparationEntry(progress: model.preparationProgress) {
                restoresEntry = true
                model.showPreparation()
            }
            .focused($entryFocused)
            .task(id: model.isPreparationPresented) {
                guard !model.isPreparationPresented, restoresEntry else { return }
                // Allow the retained page and its native default focus to return
                // before restoring the button that opened the scan scene.
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled else { return }
                restoresEntry = false
                guard showsEntry else { return }
                entryFocused = true
            }
        }
    }
}
