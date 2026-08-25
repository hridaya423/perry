import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case listening
    case guiding
    case doing
    case confirming
    case reporting
    case stopped
}

public enum SessionEvent: Equatable, Sendable {
    case wake
    case dismiss
    case startGuiding
    case startDoing
    case requestConfirmation
    case approveAction
    case denyAction
    case taskFinished
}

public struct IllegalTransitionError: Error, CustomStringConvertible {
    public let from: SessionState
    public let event: SessionEvent

    public var description: String {
        "illegal transition: \(event) is not valid from \(from)"
    }
}

public struct SessionOrchestrator: Sendable {
    private static let transitions: [SessionState: [SessionEvent: SessionState]] = [
        .idle: [.wake: .listening],
        .listening: [
            .startGuiding: .guiding,
            .startDoing: .doing,
            .dismiss: .idle,
        ],
        .guiding: [
            .taskFinished: .listening,
            .dismiss: .idle,
        ],
        .doing: [
            .requestConfirmation: .confirming,
            .taskFinished: .reporting,
            .dismiss: .stopped,
        ],
        .confirming: [
            .approveAction: .doing,
            .denyAction: .stopped,
        ],
        .reporting: [.dismiss: .idle],
        .stopped: [.dismiss: .idle],
    ]

    public private(set) var state: SessionState

    public init(initial: SessionState = .idle) {
        state = initial
    }

    public mutating func send(_ event: SessionEvent) throws -> SessionState {
        guard let next = Self.transitions[state]?[event] else {
            throw IllegalTransitionError(from: state, event: event)
        }
        state = next
        return state
    }

    public mutating func reset() {
        state = .idle
    }
}

public actor AsyncSessionOrchestrator {
    private var machine: SessionOrchestrator

    public init(initial: SessionState = .idle) {
        machine = SessionOrchestrator(initial: initial)
    }

    public var state: SessionState { machine.state }

    public func send(_ event: SessionEvent) throws -> SessionState {
        try machine.send(event)
    }

    public func reset() {
        machine.reset()
    }
}
