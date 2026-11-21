import SwiftUI
import UIKit

/// Receives Siri Remote indirect touches through UIKit, independently of which
/// optional Game Controller touch elements the connected remote exposes.
/// Install this once for the whole explore scene, including its zoom Dock.
struct RemoteTouchPanCapture: UIViewRepresentable {
    let isEnabled: Bool
    let acceptsTouches: () -> Bool
    let onContactChanged: (Bool) -> Void
    let onPan: (Double, Double) -> Void
    var onPressClaimed: () -> Void = {}
    var onAvailabilityChanged: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        uiView.configure(
            isEnabled: isEnabled, acceptsTouches: acceptsTouches,
            onContactChanged: onContactChanged, onPan: onPan,
            onPressClaimed: onPressClaimed,
            onAvailabilityChanged: onAvailabilityChanged
        )
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: ()) { uiView.detach() }

    final class CaptureView: UIView {
        private var captureEnabled = false
        private var acceptsTouches: () -> Bool = { false }
        private var onContactChanged: (Bool) -> Void = { _ in }
        private var onPan: (Double, Double) -> Void = { _, _ in }
        private var onPressClaimed: () -> Void = {}
        private var onAvailabilityChanged: (Bool) -> Void = { _ in }
        private weak var installedWindow: UIWindow?
        private var recognizer: IndirectTouchPanRecognizer?
        private var pressObserver: IndirectTouchPressObserver?
        private let availabilityDelivery = AvailabilityDelivery()

        private final class AvailabilityDelivery {
            var generation = 0
        }

        init() {
            super.init(frame: .zero)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            for name in [UIAccessibility.voiceOverStatusDidChangeNotification,
                         UIAccessibility.switchControlStatusDidChangeNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(accessibilityNavigationChanged), name: name, object: nil
                )
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronizeInstallation()
        }

        func configure(
            isEnabled: Bool, acceptsTouches: @escaping () -> Bool,
            onContactChanged: @escaping (Bool) -> Void, onPan: @escaping (Double, Double) -> Void,
            onPressClaimed: @escaping () -> Void,
            onAvailabilityChanged: @escaping (Bool) -> Void
        ) {
            captureEnabled = isEnabled
            self.acceptsTouches = acceptsTouches
            self.onContactChanged = onContactChanged
            self.onPan = onPan
            self.onPressClaimed = onPressClaimed
            self.onAvailabilityChanged = onAvailabilityChanged
            recognizer?.acceptsTouches = acceptsTouches
            recognizer?.onContactChanged = onContactChanged
            recognizer?.onPan = onPan
            recognizer?.onPressClaimed = onPressClaimed
            synchronizeInstallation()
        }

        func detach() {
            captureEnabled = false
            removeInstalledRecognizers()
        }

        private func synchronizeInstallation() {
            if installedWindow !== window || !captureEnabled { removeInstalledRecognizers() }
            guard captureEnabled, let window, recognizer == nil else { return }
            let recognizer = IndirectTouchPanRecognizer()
            let observer = IndirectTouchPressObserver()
            recognizer.acceptsTouches = acceptsTouches
            recognizer.onContactChanged = onContactChanged
            recognizer.onPan = onPan
            recognizer.onPressClaimed = onPressClaimed
            recognizer.isPhysicallyPressed = { [weak observer] in observer?.isPressing == true }
            observer.onPressBegan = { [weak recognizer] in recognizer?.claimContactForPress() }
            self.recognizer = recognizer
            pressObserver = observer
            installedWindow = window
            // Window ancestry includes both the full-screen globe and whichever
            // native SwiftUI button currently owns Focus in the zoom Dock.
            window.addGestureRecognizer(observer)
            window.addGestureRecognizer(recognizer)
            publishAvailability(systemAllowsTouchPan)
        }

        private var systemAllowsTouchPan: Bool {
            !UIAccessibility.isVoiceOverRunning && !UIAccessibility.isSwitchControlRunning
        }

        @objc private func accessibilityNavigationChanged() {
            guard let recognizer else { return }
            if !systemAllowsTouchPan { recognizer.cancelCapture() }
            publishAvailability(systemAllowsTouchPan)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func removeInstalledRecognizers() {
            guard let recognizer else { return }
            let window = installedWindow
            self.recognizer = nil
            installedWindow = nil
            recognizer.cancelCapture()
            window?.removeGestureRecognizer(recognizer)
            if let pressObserver { window?.removeGestureRecognizer(pressObserver) }
            pressObserver?.onPressBegan = nil
            pressObserver = nil
            recognizer.onContactChanged = nil
            recognizer.onPan = nil
            recognizer.onPressClaimed = nil
            recognizer.acceptsTouches = { false }
            publishAvailability(false)
        }

        private func publishAvailability(_ available: Bool) {
            availabilityDelivery.generation += 1
            let generation = availabilityDelivery.generation
            let delivery = availabilityDelivery
            let callback = onAvailabilityChanged
            // Attachment can happen inside updateUIView / didMoveToWindow.
            // Deliver outside that synchronous render transaction. The small
            // token outlives this view long enough to deliver a final detach,
            // and prevents an older install from overwriting a newer detach.
            Task { @MainActor in
                guard delivery.generation == generation else { return }
                callback(available)
            }
        }
    }
}

@MainActor
final class IndirectTouchPanRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var acceptsTouches: () -> Bool = { false }
    var isPhysicallyPressed: () -> Bool = { false }
    var onContactChanged: ((Bool) -> Void)?
    var onPan: ((Double, Double) -> Void)?
    var onPressClaimed: (() -> Void)?
    private var activeTouch: UITouch?
    private var input = RemoteIndirectTouchState()

    init() {
        super.init(target: nil, action: nil)
        name = "Photo Earth indirect touch pan"
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        allowedPressTypes = []
        // Capture displacement without cancelling the focused button's contact.
        // The zoom Dock's own focus environment rejects swipe navigation; UIKit
        // focus cannot reliably be controlled by competing with recognizers.
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    private var acceptsIndirectInput: Bool {
        isEnabled && acceptsTouches()
            && !UIAccessibility.isVoiceOverRunning && !UIAccessibility.isSwitchControlRunning
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        acceptsIndirectInput && touch.type == .indirect
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool { false }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Keep receiving real touch samples alongside UIKit. The local Dock
        // focus gate, not recognizer identity or event ordering, owns navigation.
        true
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .indirect }),
              acceptsIndirectInput else { return }
        activeTouch = touch
        let location = touch.location(in: view)
        let bounds = view?.bounds ?? .zero
        let extent = max(1, min(bounds.width, bounds.height))
        input.began(x: location.x, y: location.y, pointsPerUnit: extent / 2, isPressing: isPhysicallyPressed())
        // Contact itself never moves the camera or invalidates photos; the
        // separate intent gate below controls displacement. Directional Focus
        // in the zoom Dock is independently blocked by its hosting environment.
        state = .began
        onContactChanged?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        guard acceptsIndirectInput else { cancelCapture(); return }
        if isPhysicallyPressed(), !input.contactOwnedByPress { claimContactForPress() }
        // If UIKit batches historical samples, retain their order for the
        // landing/intent gate. The model still accumulates camera travel until
        // its display tick; these callbacks never render the map directly.
        let samples: [UITouch]
        if let coalesced = event.coalescedTouches(for: touch), !coalesced.isEmpty { samples = coalesced }
        else { samples = [touch] }
        for sample in samples {
            let location = sample.location(in: view)
            if case let .pan(dx, dy) = input.moved(x: location.x, y: location.y) {
                state = .changed
                onPan?(dx, dy)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finishContact()
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelCapture()
    }

    override func reset() {
        finishContact()
        super.reset()
    }

    func claimContactForPress() {
        input.claimForPress()
        onPressClaimed?()
    }

    func cancelCapture() {
        let wasTracking = activeTouch != nil
        finishContact()
        if wasTracking, state == .began || state == .changed { state = .cancelled }
    }

    private func finishContact() {
        let wasTouching = input.isTouching
        activeTouch = nil
        input.ended()
        if wasTouching { onContactChanged?(false) }
    }

}

/// Observes physical ownership without ever recognizing or consuming a press.
/// In particular it cannot cancel SwiftUI Select actions or arrow-key Focus.
@MainActor
private final class IndirectTouchPressObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onPressBegan: (() -> Void)?
    private var activePresses = Set<ObjectIdentifier>()
    var isPressing: Bool { !activePresses.isEmpty }

    init() {
        super.init(target: nil, action: nil)
        name = "Photo Earth touch contact press observer"
        allowedTouchTypes = []
        allowedPressTypes = [UIPress.PressType.select, .upArrow, .downArrow, .leftArrow, .rightArrow]
            .map { NSNumber(value: $0.rawValue) }
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { false }
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesBegan(presses, with: event)
        activePresses.formUnion(presses.map(ObjectIdentifier.init))
        if !presses.isEmpty { onPressBegan?() }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesEnded(presses, with: event)
        activePresses.subtract(presses.map(ObjectIdentifier.init))
        if activePresses.isEmpty { state = .failed }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesCancelled(presses, with: event)
        activePresses.subtract(presses.map(ObjectIdentifier.init))
        if activePresses.isEmpty { state = .failed }
    }

    override func reset() {
        activePresses.removeAll()
        super.reset()
    }
}
