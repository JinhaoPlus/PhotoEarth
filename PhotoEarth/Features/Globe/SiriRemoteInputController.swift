import Foundation
import GameController
import UIKit

/// Prefer the symbols supplied by Game Controller for the active physical
/// device. A controller is allowed to omit them, and synthetic gamepads may
/// expose generic face-button glyphs, so every control keeps a semantically
/// correct public SF Symbol fallback that is valid on tvOS.
struct SiriRemoteSymbolNames: Equatable {
    let touchSurface: String
    let directionalPad: String
    let centerButton: String
    let playPauseButton: String

    init(
        touchSurface: String? = nil,
        directionalPad: String? = nil,
        centerButton: String? = nil,
        playPauseButton: String? = nil
    ) {
        self.touchSurface = Self.resolved(touchSurface, fallback: "hand.draw")
        self.directionalPad = Self.resolved(
            directionalPad,
            fallback: "arrow.up.and.down.and.arrow.left.and.right"
        )
        self.centerButton = Self.resolved(
            Self.nonLetteredButtonSymbol(centerButton),
            fallback: "circle.inset.filled"
        )
        self.playPauseButton = Self.resolved(
            Self.playPauseSymbol(playPauseButton),
            fallback: "playpause.fill"
        )
    }

    private static func resolved(_ candidate: String?, fallback: String) -> String {
        guard let candidate, !candidate.isEmpty, UIImage(systemName: candidate) != nil else {
            return fallback
        }
        return candidate
    }

    /// Simulator and generic micro-gamepad profiles can report A/X face-button
    /// symbols for inputs that are the Siri Remote's center and Play/Pause
    /// buttons. Those glyphs are technically valid but misleading in this UI.
    private static func nonLetteredButtonSymbol(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let components = candidate.lowercased().split(separator: ".")
        let containsSingleLetter = components.contains { component in
            component.count == 1 && component.first?.isLetter == true
        }
        guard !containsSingleLetter, !components.contains("xmark") else { return nil }
        return candidate
    }

    private static func playPauseSymbol(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let normalized = candidate.lowercased().filter(\.isLetter)
        guard normalized.contains("playpause") else { return nil }
        return candidate
    }
}

/// Physical presses only. UIKit owns the sole touch lifecycle and drag stream;
/// missing Game Controller touch elements must never disable Siri Remote pan.
@MainActor
final class SiriRemoteInputController {
    var onDirectionalChange: ((Double, Double) -> Void)?
    var onDirectionalAvailabilityChanged: ((Bool) -> Void)?
    var onCenterPressChanged: ((Bool) -> Void)?
    var onCenterPressCancelled: (() -> Void)?
    var onSymbolNamesChanged: ((SiriRemoteSymbolNames) -> Void)?

    private final class RemoteState {
        var directionPad: GCControllerDirectionPad?
        var horizontal = 0.0
        var vertical = 0.0
        var waitsForDirectionRelease = false
        var centerButton: GCControllerButtonInput?
        var isCenterPressed = false
    }

    private var states: [ObjectIdentifier: RemoteState] = [:]
    private var isStarted = false
    private var publishedDirectionsAvailable = false
    private var publishedSymbolNames: SiriRemoteSymbolNames?

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidConnect(_:)), name: .GCControllerDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidDisconnect(_:)), name: .GCControllerDidDisconnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidBecomeCurrent(_:)), name: .GCControllerDidBecomeCurrent, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidStopBeingCurrent(_:)), name: .GCControllerDidStopBeingCurrent, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerCustomizationDidChange(_:)),
            name: .GCControllerUserCustomizationsDidChange, object: nil
        )
        GCController.controllers().forEach(configure)
        publishAvailability()
        publishSymbolNames()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        states.values.forEach(detach)
        states.removeAll()
        onCenterPressCancelled?()
        onDirectionalChange?(0, 0)
        publishAvailability()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard isStarted, let controller = notification.object as? GCController else { return }
        configure(controller)
        publishSymbolNames()
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController,
              let state = states.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        detach(state)
        onCenterPressCancelled?()
        publishDirections()
        publishAvailability()
        publishSymbolNames()
    }

    @objc private func controllerDidBecomeCurrent(_ notification: Notification) {
        guard isStarted, let controller = notification.object as? GCController else { return }
        publishSymbolNames(preferred: controller)
    }

    @objc private func controllerDidStopBeingCurrent(_ notification: Notification) {
        guard isStarted else { return }
        publishSymbolNames()
    }

    @objc private func controllerCustomizationDidChange(_ notification: Notification) {
        guard isStarted, let controller = notification.object as? GCController else { return }
        publishSymbolNames(preferred: controller)
    }

    private func configure(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard states[identifier] == nil, let microGamepad = controller.microGamepad else { return }
        let state = RemoteState()
        states[identifier] = state
        controller.handlerQueue = .main
        microGamepad.allowsRotation = false

        let cardinalPad = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad]
        let primaryPad = controller.physicalInputProfile.dpads[GCInputDirectionalDpad] ?? microGamepad.dpad
        // An analog touch location is never an intentional direction press.
        // Legacy/Simulator input without physical directions retains UIKit keys.
        state.directionPad = cardinalPad ?? (primaryPad.isAnalog ? nil : primaryPad)
        if let pad = state.directionPad {
            state.waitsForDirectionRelease = hypot(Double(pad.xAxis.value), Double(pad.yAxis.value)) > 0.05
            pad.valueChangedHandler = { [weak self, weak state] _, x, y in
                guard let self, let state, isStarted else { return }
                if state.waitsForDirectionRelease {
                    if hypot(Double(x), Double(y)) <= 0.05 { state.waitsForDirectionRelease = false }
                    return
                }
                guard state.horizontal != Double(x) || state.vertical != Double(y) else { return }
                state.horizontal = Double(x)
                state.vertical = Double(y)
                publishDirections()
            }
        }
        // Modern buttonA can include outer-ring clicks. Only fall back to it
        // on profiles without a distinct cardinal/center split.
        let center = controller.physicalInputProfile.buttons[GCInputDirectionalCenterButton]
            ?? (cardinalPad == nil ? microGamepad.buttonA : nil)
        state.centerButton = center
        state.isCenterPressed = center?.isPressed ?? false
        center?.pressedChangedHandler = { [weak self, weak state] _, _, pressed in
            guard let self, let state, isStarted, state.isCenterPressed != pressed else { return }
            state.isCenterPressed = pressed
            onCenterPressChanged?(pressed)
        }
        publishAvailability()
    }

    private func publishSymbolNames(preferred: GCController? = nil) {
        let isConfigured: (GCController) -> Bool = { [states] controller in
            states[ObjectIdentifier(controller)] != nil
        }
        let controller = preferred.flatMap { isConfigured($0) ? $0 : nil }
            ?? GCController.current.flatMap { isConfigured($0) ? $0 : nil }
            ?? GCController.controllers().first(where: isConfigured)
        let names = controller.map(symbolNames) ?? SiriRemoteSymbolNames()
        guard names != publishedSymbolNames else { return }
        publishedSymbolNames = names
        onSymbolNamesChanged?(names)
    }

    private func symbolNames(for controller: GCController) -> SiriRemoteSymbolNames {
        guard let microGamepad = controller.microGamepad else { return SiriRemoteSymbolNames() }
        let profile = controller.physicalInputProfile
        let primaryPad = profile.dpads[GCInputDirectionalDpad] ?? microGamepad.dpad
        let cardinalPad = profile.dpads[GCInputDirectionalCardinalDpad]
        let directionalPad = cardinalPad ?? (primaryPad.isAnalog ? nil : primaryPad)
        let centerButton = profile.buttons[GCInputDirectionalCenterButton]
            ?? (cardinalPad == nil ? microGamepad.buttonA : nil)
        let playPauseButton = profile.buttons[GCInputMicroGamepadButtonX] ?? microGamepad.buttonX
        return SiriRemoteSymbolNames(
            touchSurface: primaryPad.sfSymbolsName,
            directionalPad: directionalPad?.sfSymbolsName,
            centerButton: centerButton?.sfSymbolsName,
            playPauseButton: playPauseButton.sfSymbolsName
        )
    }

    private func publishDirections() {
        onDirectionalChange?(
            states.values.reduce(0) { $0 + $1.horizontal },
            states.values.reduce(0) { $0 + $1.vertical }
        )
    }

    private func publishAvailability() {
        let available = states.values.contains { $0.directionPad != nil }
        guard available != publishedDirectionsAvailable else { return }
        publishedDirectionsAvailable = available
        onDirectionalAvailabilityChanged?(available)
    }

    private func detach(_ state: RemoteState) {
        state.centerButton?.pressedChangedHandler = nil
        state.directionPad?.valueChangedHandler = nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
