import Foundation
import GameController

@MainActor
final class SiriRemoteInputController {
    var onDirectionalChange: ((Double, Double) -> Void)?
    var onTouchPan: ((Double, Double) -> Void)?
    var onRingRotation: ((Double) -> Void)?
    var onRingTouchChanged: ((Bool) -> Void)?

    private var configuredControllers: [GCController] = []
    private var surfaceRecognizer = RemoteSurfaceGestureRecognizer()
    private var receivesTouchState = false
    private var isTouching = false
    private var inferredTouching = false

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        GCController.controllers().forEach(configure)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        for controller in configuredControllers {
            controller.microGamepad?.dpad.valueChangedHandler = nil
            controller.physicalInputProfile.dpads[GCInputDirectionalDpad]?.valueChangedHandler = nil
            controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad]?.valueChangedHandler = nil
            controller.physicalInputProfile.buttons[GCInputDirectionalTouchSurfaceButton]?.touchedChangedHandler = nil
        }
        configuredControllers.removeAll()
        surfaceRecognizer.reset()
        receivesTouchState = false
        isTouching = false
        inferredTouching = false
        onDirectionalChange?(0, 0)
        onRingTouchChanged?(false)
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configuredControllers.removeAll { $0 === controller }
        onDirectionalChange?(0, 0)
        finishTouch()
    }

    private func configure(_ controller: GCController) {
        guard !configuredControllers.contains(where: { $0 === controller }) else { return }
        guard let microGamepad = controller.microGamepad else { return }

        controller.handlerQueue = .main
        microGamepad.allowsRotation = false
        microGamepad.reportsAbsoluteDpadValues = true

        // The secondary cardinal pad is the four physical click directions on
        // second-generation and later Siri Remotes. Keep these camera-relative.
        if let cardinalPad = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad] {
            cardinalPad.valueChangedHandler = { [weak self] _, xValue, yValue in
                self?.onDirectionalChange?(Double(xValue), Double(yValue))
            }
        }

        if let touchSurface = controller.physicalInputProfile.buttons[GCInputDirectionalTouchSurfaceButton] {
            touchSurface.touchedChangedHandler = { [weak self] _, _, _, touched in
                guard let self else { return }
                receivesTouchState = true
                isTouching = touched
                if touched {
                    surfaceRecognizer.reset()
                    onRingTouchChanged?(true)
                } else {
                    finishTouch()
                }
            }
        }

        // The primary pad is the absolute position over the entire touch surface,
        // including both the inner pad and the outer circular ring.
        let primaryPad = controller.physicalInputProfile.dpads[GCInputDirectionalDpad]
            ?? microGamepad.dpad
        primaryPad.valueChangedHandler = { [weak self] _, xValue, yValue in
            self?.handleTouchPosition(x: Double(xValue), y: Double(yValue))
        }
        configuredControllers.append(controller)
    }

    private func handleTouchPosition(x: Double, y: Double) {
        let radius = hypot(x, y)
        let touching: Bool
        if receivesTouchState {
            touching = isTouching
        } else {
            touching = radius > 0.06
            if touching != inferredTouching {
                inferredTouching = touching
                onRingTouchChanged?(touching)
            }
        }

        guard let gesture = surfaceRecognizer.update(
            x: x,
            y: y,
            isTouching: touching
        ) else { return }
        switch gesture {
        case let .pan(horizontalDelta, verticalDelta):
            onTouchPan?(horizontalDelta, verticalDelta)
        case let .ring(angleDelta):
            onRingRotation?(angleDelta)
        }
    }

    private func finishTouch() {
        isTouching = false
        inferredTouching = false
        surfaceRecognizer.reset()
        onRingTouchChanged?(false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
