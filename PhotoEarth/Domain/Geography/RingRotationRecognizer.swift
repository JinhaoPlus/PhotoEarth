import Foundation

nonisolated struct RingRotationRecognizer: Sendable {
    var minimumRadius = 0.68
    var activationAngle = 0.045
    var maximumSampleAngle = 0.72

    private var previousAngle: Double?
    private var pendingAngle = 0.0
    private(set) var isRecognized = false

    mutating func update(x: Double, y: Double, isTouching: Bool) -> Double? {
        guard isTouching else {
            reset()
            return nil
        }

        let radius = hypot(x, y)
        let requiredRadius = isRecognized ? minimumRadius - 0.1 : minimumRadius
        guard radius >= requiredRadius else {
            previousAngle = nil
            pendingAngle = 0
            return nil
        }

        let angle = atan2(y, x)
        guard let previousAngle else {
            self.previousAngle = angle
            return nil
        }

        var delta = angle - previousAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        self.previousAngle = angle

        guard abs(delta) <= maximumSampleAngle else {
            pendingAngle = 0
            return nil
        }

        if isRecognized {
            return abs(delta) >= 0.002 ? delta : nil
        }

        pendingAngle += delta
        guard abs(pendingAngle) >= activationAngle else { return nil }
        isRecognized = true
        defer { pendingAngle = 0 }
        return pendingAngle
    }

    mutating func reset() {
        previousAngle = nil
        pendingAngle = 0
        isRecognized = false
    }
}

nonisolated enum RemoteSurfaceGesture: Equatable, Sendable {
    case pan(horizontalDelta: Double, verticalDelta: Double)
    case ring(angleDelta: Double)
}

nonisolated struct RemoteSurfaceGestureRecognizer: Sendable {
    private var ringRecognizer = RingRotationRecognizer()
    private var previousPanPosition: (x: Double, y: Double)?

    mutating func update(
        x: Double,
        y: Double,
        isTouching: Bool
    ) -> RemoteSurfaceGesture? {
        guard isTouching else {
            reset()
            return nil
        }

        let radius = hypot(x, y)
        let ringThreshold = ringRecognizer.isRecognized
            ? ringRecognizer.minimumRadius - 0.1
            : ringRecognizer.minimumRadius

        if radius >= ringThreshold {
            previousPanPosition = nil
            guard let angleDelta = ringRecognizer.update(
                x: x,
                y: y,
                isTouching: true
            ) else { return nil }
            return .ring(angleDelta: angleDelta)
        }

        _ = ringRecognizer.update(x: x, y: y, isTouching: true)
        guard !ringRecognizer.isRecognized,
              radius <= ringRecognizer.minimumRadius - 0.08 else {
            previousPanPosition = nil
            return nil
        }

        guard let previousPanPosition else {
            self.previousPanPosition = (x, y)
            return nil
        }
        self.previousPanPosition = (x, y)
        let horizontalDelta = x - previousPanPosition.x
        let verticalDelta = y - previousPanPosition.y
        guard hypot(horizontalDelta, verticalDelta) >= 0.004,
              abs(horizontalDelta) <= 0.42,
              abs(verticalDelta) <= 0.42 else { return nil }
        return .pan(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta
        )
    }

    mutating func reset() {
        ringRecognizer.reset()
        previousPanPosition = nil
    }
}
