nonisolated struct OverviewFocusHandoff: Equatable {
    static let entryID = "enter-globe"

    enum Phase: Equatable {
        case inactive
        case restoring(String)
        case browsing
        case returningToTop
    }

    private(set) var phase: Phase = .inactive

    mutating func deactivate() { phase = .inactive }
    mutating func restore(_ id: String) { phase = .restoring(id) }
    mutating func returnToTop() { phase = .returningToTop }

    mutating func accept(_ id: String?, atTop: Bool) -> String? {
        guard let id else { return nil }
        switch phase {
        case .inactive: return nil
        case .browsing: return id
        case .restoring(let target) where id != target: return nil
        case .returningToTop where id != Self.entryID || !atTop: return nil
        default:
            phase = .browsing
            return id
        }
    }

    func handlesBack(hasFocus: Bool, belowTop: Bool) -> Bool {
        phase == .returningToTop || (phase != .inactive && hasFocus && belowTop)
    }
}
