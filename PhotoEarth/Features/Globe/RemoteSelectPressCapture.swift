import SwiftUI
import UIKit

/// A draw-free bridge for UIKit Select presses. The existing SwiftUI input
/// surface keeps focus, directional movement, and Menu handling.
struct RemoteSelectPressCapture: UIViewRepresentable {
    let isEnabled: Bool
    let acceptsPresses: () -> Bool
    let onPressChanged: (Bool) -> Void
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        uiView.configure(
            isEnabled: isEnabled,
            acceptsPresses: acceptsPresses,
            onPressChanged: onPressChanged,
            onCancelled: onCancelled
        )
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: ()) {
        uiView.detach()
    }

    final class CaptureView: UIView {
        private var captureEnabled = false
        private var acceptsPresses: () -> Bool = { false }
        private var onPressChanged: (Bool) -> Void = { _ in }
        private var onCancelled: () -> Void = {}
        private weak var installedWindow: UIWindow?
        private var recognizer: SelectPressRecognizer?

        init() {
            super.init(frame: .zero)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronizeInstallation()
        }

        func configure(
            isEnabled: Bool,
            acceptsPresses: @escaping () -> Bool,
            onPressChanged: @escaping (Bool) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            captureEnabled = isEnabled
            self.acceptsPresses = acceptsPresses
            self.onPressChanged = onPressChanged
            self.onCancelled = onCancelled
            recognizer?.acceptsPresses = acceptsPresses
            recognizer?.onPressChanged = onPressChanged
            recognizer?.onCancelled = onCancelled
            synchronizeInstallation()
        }

        func detach() {
            captureEnabled = false
            removeInstalledRecognizer()
        }

        private func synchronizeInstallation() {
            if installedWindow !== window || !captureEnabled {
                removeInstalledRecognizer()
            }
            guard captureEnabled, let window, recognizer == nil else { return }
            let recognizer = SelectPressRecognizer()
            recognizer.acceptsPresses = acceptsPresses
            recognizer.onPressChanged = onPressChanged
            recognizer.onCancelled = onCancelled
            self.recognizer = recognizer
            installedWindow = window
            // Attach only to the window containing this view, never to another
            // scene's window or to a process-wide/key-window lookup.
            window.addGestureRecognizer(recognizer)
        }

        private func removeInstalledRecognizer() {
            guard let recognizer else { return }
            let window = installedWindow
            self.recognizer = nil
            installedWindow = nil
            // Clear source ownership even after a release, so a later scene
            // cannot inherit this window's capture.
            recognizer.cancelCapture()
            window?.removeGestureRecognizer(recognizer)
            recognizer.onPressChanged = nil
            recognizer.onCancelled = nil
            recognizer.acceptsPresses = { false }
        }
    }
}

@MainActor
private final class SelectPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var acceptsPresses: () -> Bool = { false }
    var onPressChanged: ((Bool) -> Void)?
    var onCancelled: (() -> Void)?
    private var activePresses = Set<ObjectIdentifier>()

    init() {
        super.init(target: nil, action: nil)
        name = "Photo Earth Select press capture"
        allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        return press.type == .select && isEnabled && acceptsPresses()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesBegan(presses, with: event)
        let selectPresses = presses.filter { $0.type == .select }
        guard !selectPresses.isEmpty else { return }
        guard isEnabled, acceptsPresses() else {
            if !activePresses.isEmpty { cancelCapture() }
            return
        }
        let wasPressed = !activePresses.isEmpty
        activePresses.formUnion(selectPresses.map(ObjectIdentifier.init))
        guard !wasPressed else { return }
        state = .began
        onPressChanged?(true)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesChanged(presses, with: event)
        guard presses.contains(where: { activePresses.contains(ObjectIdentifier($0)) }) else { return }
        guard isEnabled, acceptsPresses() else {
            cancelCapture()
            return
        }
        state = .changed
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesEnded(presses, with: event)
        let endingIDs = Set(presses.map(ObjectIdentifier.init))
        guard !activePresses.isDisjoint(with: endingIDs) else { return }
        guard isEnabled, acceptsPresses() else {
            cancelCapture()
            return
        }
        activePresses.subtract(endingIDs)
        guard activePresses.isEmpty else { return }
        state = .ended
        onPressChanged?(false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesCancelled(presses, with: event)
        guard presses.contains(where: { activePresses.contains(ObjectIdentifier($0)) }) else { return }
        cancelCapture()
    }

    override func reset() {
        let wasPressed = !activePresses.isEmpty
        activePresses.removeAll()
        super.reset()
        if wasPressed { onCancelled?() }
    }

    func cancelCapture() {
        let wasPressed = !activePresses.isEmpty
        activePresses.removeAll()
        if wasPressed, state == .began || state == .changed {
            state = .cancelled
        }
        onCancelled?()
    }
}
