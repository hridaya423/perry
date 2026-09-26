import Foundation

/// Pure hover-intent state machine for the notch Home strip (Phase 5 §4.7).
/// Owns no timers — it reports deadline state and the controller schedules
/// a single timer for `pendingDeadline`, which keeps fuzzed pointer paths
/// free of stuck-open states by construction.
struct HomeHoverIntent: Equatable {
    enum State: Equatable {
        case closed
        case dwelling(deadline: TimeInterval)
        case peekOpen
        case tucking(deadline: TimeInterval)
        /// Esc pressed: stays closed until the pointer leaves the zone.
        case latched
    }

    enum Action: Equatable {
        case none
        case showPeek
        case hidePeek
    }

    var dwell: TimeInterval = 0.120
    var tuck: TimeInterval = 0.250
    /// Full Home window is open: peek is suppressed entirely.
    var homeOpen = false
    private(set) var state: State = .closed

    var pendingDeadline: TimeInterval? {
        switch state {
        case .dwelling(let d), .tucking(let d): return d
        case .closed, .peekOpen, .latched: return nil
        }
    }

    mutating func entered(at now: TimeInterval) -> Action {
        guard !homeOpen else { return .none }
        switch state {
        case .closed:
            state = .dwelling(deadline: now + dwell)
        case .tucking:
            // Re-enter during tuck cancels the close — no hide/show flicker.
            state = .peekOpen
        case .dwelling, .peekOpen, .latched:
            break
        }
        return .none
    }

    mutating func exited(at now: TimeInterval) -> Action {
        switch state {
        case .dwelling:
            state = .closed
        case .peekOpen:
            state = .tucking(deadline: now + tuck)
        case .latched:
            state = .closed
        case .closed, .tucking:
            break
        }
        return .none
    }

    mutating func deadlineReached(at now: TimeInterval) -> Action {
        switch state {
        case .dwelling(let d) where now >= d:
            state = .peekOpen
            return .showPeek
        case .tucking(let d) where now >= d:
            state = .closed
            return .hidePeek
        default:
            return .none
        }
    }

    mutating func escape() -> Action {
        switch state {
        case .dwelling, .peekOpen:
            state = .latched
            return .hidePeek
        case .tucking:
            // Pointer already left — nothing to latch against; just close.
            state = .closed
            return .hidePeek
        case .closed, .latched:
            return .none
        }
    }

    /// Opening/closing the full Home window. Opening hides any peek at once.
    mutating func setHomeOpen(_ open: Bool) -> Action {
        homeOpen = open
        guard open else { return .none }
        switch state {
        case .dwelling, .peekOpen, .tucking:
            state = .closed
            return .hidePeek
        case .closed, .latched:
            return .none
        }
    }
}
