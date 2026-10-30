import Foundation

struct HomeHoverIntent: Equatable {
    enum State: Equatable {
        case closed
        case dwelling(deadline: TimeInterval)
        case peekOpen
        case tucking(deadline: TimeInterval)
        case latched
    }

    enum Action: Equatable {
        case none
        case showPeek
        case hidePeek
    }

    var dwell: TimeInterval = 0.180
    var tuck: TimeInterval = 0.350
    private(set) var state: State = .closed

    var pendingDeadline: TimeInterval? {
        switch state {
        case .dwelling(let d), .tucking(let d): return d
        case .closed, .peekOpen, .latched: return nil
        }
    }

    mutating func entered(at now: TimeInterval) -> Action {
        switch state {
        case .closed:
            state = .dwelling(deadline: now + dwell)
        case .tucking:
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
            state = .closed
            return .hidePeek
        case .closed, .latched:
            return .none
        }
    }
}
