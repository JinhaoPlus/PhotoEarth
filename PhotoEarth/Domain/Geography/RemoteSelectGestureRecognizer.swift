/// Resolves one physical Select action on release, independently of touchpad
/// coordinates. Holding Select has no separate meaning; Play/Pause owns the
/// zoom-controls shortcut.
nonisolated struct RemoteSelectGestureRecognizer: Sendable {
    enum Action: Equatable, Sendable {
        case singlePress
    }

    private enum State: Sendable {
        case idle
        case pressed
    }

    private var state = State.idle
    private var lastTimestamp: Double?

    mutating func pressBegan(at timestamp: Double) -> [Action] {
        guard accept(timestamp) else { return [] }
        switch state {
        case .idle:
            state = .pressed
            return []
        case .pressed:
            // Repeated pressed-value notifications do not create extra actions.
            return []
        }
    }

    mutating func pressEnded(at timestamp: Double) -> [Action] {
        guard accept(timestamp) else { return [] }
        switch state {
        case .pressed:
            state = .idle
            // There is no competing hold or double-click gesture. Select always
            // acts on its release edge, without a timer or arbitration delay.
            return [.singlePress]
        case .idle:
            return []
        }
    }

    mutating func reset() {
        state = .idle
        // Retain the monotonic watermark so late events from a cancelled
        // gesture cannot be replayed into a new interaction.
    }

    private mutating func accept(_ timestamp: Double) -> Bool {
        guard timestamp.isFinite, timestamp >= 0,
              lastTimestamp.map({ timestamp >= $0 }) ?? true else { return false }
        lastTimestamp = timestamp
        return true
    }
}
