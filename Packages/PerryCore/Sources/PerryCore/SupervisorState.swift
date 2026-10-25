import Foundation

public enum SupervisorExecutionState: Hashable, Sendable {
    case running
    case paused
    case awaitingApproval
}

public enum SupervisorState: Hashable, Sendable {
    case idle
    case listening
    case starting
    case guiding
    case executing(SupervisorExecutionState)
    case reporting
    case failed
    case stopped
}

public enum SupervisorEvent: Hashable, Sendable {
    case wake
    case dismiss
    case startGuiding
    case startDoing
    case startTask
    case cancelWindowElapsed
    case cancel
    case pause
    case resume
    case steer
    case requestConfirmation
    case approveAction
    case denyAction
    case taskFinished
    case taskFailed
    case retry
}

public struct IllegalSupervisorTransitionError: Error, CustomStringConvertible {
    public let from: SupervisorState
    public let event: SupervisorEvent

    public var description: String {
        "illegal transition: \(event) is not valid from \(from)"
    }
}

public struct SupervisorStateMachine: Sendable {
    private static let transitions: [SupervisorState: [SupervisorEvent: SupervisorState]] = [
        .idle: [.wake: .listening],
        .listening: [
            .startGuiding: .guiding,
            .startDoing: .executing(.running),
            .startTask: .starting,
            .dismiss: .idle,
        ],
        .starting: [
            .cancelWindowElapsed: .executing(.running),
            .cancel: .stopped,
            .dismiss: .stopped,
            .taskFailed: .failed,
        ],
        .guiding: [
            .taskFinished: .listening,
            .dismiss: .idle,
        ],
        .executing(.running): [
            .pause: .executing(.paused),
            .steer: .executing(.running),
            .requestConfirmation: .executing(.awaitingApproval),
            .taskFinished: .reporting,
            .taskFailed: .failed,
            .cancel: .stopped,
            .dismiss: .stopped,
        ],
        .executing(.paused): [
            .resume: .executing(.running),
            .steer: .executing(.paused),
            .requestConfirmation: .executing(.awaitingApproval),
            .taskFailed: .failed,
            .cancel: .stopped,
            .dismiss: .stopped,
        ],
        .executing(.awaitingApproval): [
            .approveAction: .executing(.running),
            .denyAction: .stopped,
            .dismiss: .stopped,
        ],
        .reporting: [.dismiss: .idle],
        .failed: [
            .retry: .starting,
            .dismiss: .idle,
            .cancel: .stopped,
        ],
        .stopped: [.dismiss: .idle],
    ]

    public private(set) var state: SupervisorState

    public init(initial: SupervisorState = .idle) {
        state = initial
    }

    public mutating func send(_ event: SupervisorEvent) throws -> SupervisorState {
        guard let next = Self.transitions[state]?[event] else {
            throw IllegalSupervisorTransitionError(from: state, event: event)
        }
        state = next
        return state
    }

    public mutating func reset() {
        state = .idle
    }
}
