import Combine
import SwiftUI
import UIKit

enum ZoomButtonFocusTarget: Int, CaseIterable, Hashable {
    case zoomOut
    case zoomIn
    case currentView
    case mapStyle
}

/// Explicit requests from physical arrows. The actual focused button remains
/// owned by SwiftUI / UIKit, including when accessibility moves it directly.
@MainActor
final class ZoomButtonFocusNavigation: ObservableObject {
    struct Request: Equatable {
        let target: ZoomButtonFocusTarget
        let sequence: Int
    }

    @Published private(set) var request = Request(target: .zoomIn, sequence: 0)
    private(set) var currentControl: ZoomButtonFocusTarget = .zoomIn
    var layoutDirection: LayoutDirection = .leftToRight
    var includesCurrentView = false
    var includesMapStyle = false
    private var targets: [ZoomButtonFocusTarget] {
        [.zoomOut, .zoomIn] + (includesCurrentView ? [.currentView] : [])
            + (includesMapStyle ? [.mapStyle] : [])
    }

    func didFocus(_ target: ZoomButtonFocusTarget?) {
        if let target { currentControl = target }
    }

    func moveFocus(for pressType: UIPress.PressType) {
        let step: Int
        switch pressType {
        case .leftArrow: step = -1
        case .rightArrow: step = 1
        default: return
        }
        let logicalStep = layoutDirection == .rightToLeft ? -step : step
        let index = min(max((targets.firstIndex(of: currentControl) ?? 1) + logicalStep, 0), targets.count - 1)
        let target = targets[index]
        guard target != currentControl else { return }
        currentControl = target
        request = Request(target: target, sequence: request.sequence &+ 1)
    }
}

/// A Focus boundary around only the zoom Dock. It does not replace the app's
/// window/controller or intercept navigation on the sidebar and photo screens.
struct ZoomButtonFocusContainer<Content: View>: UIViewControllerRepresentable {
    let navigation: ZoomButtonFocusNavigation
    let content: Content
    @Environment(\.scenePhase) private var scenePhase

    init(navigation: ZoomButtonFocusNavigation, @ViewBuilder content: () -> Content) {
        self.navigation = navigation
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ZoomButtonHostingController<Content> {
        navigation.layoutDirection = context.environment.layoutDirection
        let controller = ZoomButtonHostingController(rootView: content, navigation: navigation)
        controller.routingEnabled = scenePhase == .active
        return controller
    }

    func updateUIViewController(_ controller: ZoomButtonHostingController<Content>, context: Context) {
        navigation.layoutDirection = context.environment.layoutDirection
        controller.rootView = content
        controller.routingEnabled = scenePhase == .active
        controller.synchronizeRouting()
    }

    static func dismantleUIViewController(_ controller: ZoomButtonHostingController<Content>, coordinator: ()) {
        controller.routingEnabled = false
    }
}

@MainActor
final class ZoomButtonHostingController<Content: View>: UIHostingController<Content> {
    private let navigation: ZoomButtonFocusNavigation
    private let assistiveNavigationIsActive: @MainActor () -> Bool
    private let directionRecognizer = ZoomButtonDirectionPressRecognizer()
    var routingEnabled = true {
        didSet { synchronizeRouting() }
    }

    init(
        rootView: Content,
        navigation: ZoomButtonFocusNavigation,
        assistiveNavigationIsActive: @escaping @MainActor () -> Bool = {
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        }
    ) {
        self.navigation = navigation
        self.assistiveNavigationIsActive = assistiveNavigationIsActive
        super.init(rootView: rootView)
        // The Dock already reserves the same 104 pt bottom space as before.
        // UIKit must not add a second TV safe-area inset inside this host.
        safeAreaRegions = []
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        directionRecognizer.onDirection = { [weak self] in self?.receiveDirectionalPress($0) }
        directionRecognizer.acceptsPresses = { [weak self] in self?.routesPhysicalArrows == true }
        view.addGestureRecognizer(directionRecognizer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityNavigationChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityNavigationChanged),
            name: UIAccessibility.switchControlStatusDidChangeNotification, object: nil
        )
        synchronizeRouting()
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // A focus update does not publicly identify whether a swipe or a
        // physical arrow caused it. Deny all directional searching here and
        // let real arrow presses request a specific native button instead.
        // Programmatic entry/exit and accessibility retain standard Focus.
        allowsNativeFocus(heading: context.focusHeading) && super.shouldUpdateFocus(in: context)
    }

    func allowsNativeFocus(heading: UIFocusHeading) -> Bool {
        let cardinal: UIFocusHeading = [.up, .down, .left, .right]
        return !routesPhysicalArrows || heading.intersection(cardinal).isEmpty
    }

    func receiveDirectionalPress(_ type: UIPress.PressType) {
        guard routesPhysicalArrows else { return }
        navigation.moveFocus(for: type)
    }

    func synchronizeRouting() {
        let enabled = routesPhysicalArrows
        if directionRecognizer.isEnabled != enabled { directionRecognizer.isEnabled = enabled }
    }

    private var routesPhysicalArrows: Bool {
        routingEnabled && !assistiveNavigationIsActive()
    }

    @objc private func accessibilityNavigationChanged() { synchronizeRouting() }

    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Watches actual left/right UIPress lifecycles, never touch-based movement
/// commands. Select and Menu remain native button/responder-chain events.
@MainActor
final class ZoomButtonDirectionPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var acceptsPresses: () -> Bool = { true }
    var onDirection: ((UIPress.PressType) -> Void)?
    private var activePresses = Set<ObjectIdentifier>()

    init() {
        super.init(target: nil, action: nil)
        name = "Photo Earth zoom physical arrows"
        allowedTouchTypes = []
        allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        isEnabled && acceptsPresses() && (press.type == .leftArrow || press.type == .rightArrow)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesBegan(presses, with: event)
        guard isEnabled, acceptsPresses() else { return }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            guard activePresses.insert(ObjectIdentifier(press)).inserted else { continue }
            state = state == .possible ? .began : .changed
            onDirection?(press.type)
        }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesEnded(presses, with: event)
        endPresses(presses, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesCancelled(presses, with: event)
        endPresses(presses, cancelled: true)
    }

    override func reset() {
        activePresses.removeAll()
        super.reset()
    }

    private func endPresses(_ presses: Set<UIPress>, cancelled: Bool) {
        let hadPress = !activePresses.isEmpty
        for press in presses { activePresses.remove(ObjectIdentifier(press)) }
        guard hadPress, activePresses.isEmpty else { return }
        state = cancelled ? .cancelled : .ended
    }
}
