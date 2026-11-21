import Foundation

nonisolated enum RemoteSurfaceGesture: Equatable, Sendable {
    case pan(horizontalDelta: Double, verticalDelta: Double)
}

/// UIKit supplies real began / moved / ended boundaries and positions in a
/// window's coordinate space. The first moved sample establishes a stable
/// landing; only movement after that landing can move the globe.
nonisolated struct RemoteIndirectTouchState: Sendable {
    var activationDistance = 12.0
    var maximumUnconfirmedStep = 120.0

    private(set) var isTouching = false
    private(set) var isPanning = false
    private(set) var contactOwnedByPress = false
    private var previousPosition = (x: 0.0, y: 0.0)
    private var landingOrigin = (x: 0.0, y: 0.0)
    private var previousStep = (x: 0.0, y: 0.0)
    private var pending = (x: 0.0, y: 0.0)
    private var hasStableLanding = false
    private var pointsPerUnit = 540.0

    mutating func began(x: Double, y: Double, pointsPerUnit: Double, isPressing: Bool) {
        guard !isTouching, x.isFinite, y.isFinite, pointsPerUnit.isFinite, pointsPerUnit > 0 else { return }
        isTouching = true
        isPanning = false
        contactOwnedByPress = isPressing
        previousPosition = (x, y)
        landingOrigin = (x, y)
        previousStep = (0, 0)
        pending = (0, 0)
        hasStableLanding = false
        self.pointsPerUnit = pointsPerUnit
    }

    mutating func moved(x: Double, y: Double) -> RemoteSurfaceGesture? {
        guard isTouching, !contactOwnedByPress, x.isFinite, y.isFinite else { return nil }
        let step = (x: x - previousPosition.x, y: y - previousPosition.y)
        let priorStep = previousStep
        previousPosition = (x, y)
        previousStep = step
        guard hasStableLanding else {
            hasStableLanding = true
            if hypot(step.x, step.y) > maximumUnconfirmedStep { landingOrigin = (x, y) }
            return nil
        }
        if !isPanning {
            let length = hypot(step.x, step.y)
            let priorLength = hypot(priorStep.x, priorStep.y)
            let continuesFastDrag = priorLength > maximumUnconfirmedStep
                && length >= priorLength * 0.5 && length <= priorLength * 2
                && step.x * priorStep.x + step.y * priorStep.y >= length * priorLength * 0.9
            guard length <= maximumUnconfirmedStep || continuesFastDrag else {
                pending = (0, 0)
                landingOrigin = (x, y)
                return nil
            }
            pending.x += step.x
            pending.y += step.y
            guard hypot(pending.x, pending.y) >= activationDistance,
                  hypot(x - landingOrigin.x, y - landingOrigin.y) >= activationDistance else { return nil }
            isPanning = true
            defer { pending = (0, 0) }
            return normalized(pending)
        }
        guard step.x != 0 || step.y != 0 else { return nil }
        return normalized(step)
    }

    /// A physical click owns the rest of this contact, including movement after
    /// the button is released. Only ended/cancelled permits a fresh drag.
    mutating func claimForPress() {
        guard isTouching else { return }
        contactOwnedByPress = true
        isPanning = false
        pending = (0, 0)
    }

    mutating func ended() {
        isTouching = false
        isPanning = false
        contactOwnedByPress = false
        hasStableLanding = false
        pending = (0, 0)
    }

    private func normalized(_ delta: (x: Double, y: Double)) -> RemoteSurfaceGesture {
        // UIKit's positive Y points down. The camera input contract uses the
        // remote's positive Y pointing up; retain the direct-grab convention.
        .pan(horizontalDelta: delta.x / pointsPerUnit, verticalDelta: -delta.y / pointsPerUnit)
    }
}
