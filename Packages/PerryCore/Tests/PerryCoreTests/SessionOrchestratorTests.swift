import XCTest
@testable import PerryCore

final class SupervisorStateMachineTests: XCTestCase {
    private let allEvents: [SupervisorEvent] = [
        .wake,
        .dismiss,
        .startGuiding,
        .startDoing,
        .startTask,
        .cancelWindowElapsed,
        .cancel,
        .pause,
        .resume,
        .steer,
        .requestConfirmation,
        .approveAction,
        .denyAction,
        .taskFinished,
        .taskFailed,
        .retry,
    ]

    private let allStates: [SupervisorState] = [
        .idle,
        .listening,
        .starting,
        .guiding,
        .executing(.running),
        .executing(.paused),
        .executing(.awaitingApproval),
        .reporting,
        .failed,
        .stopped,
    ]

    private let legalTransitions: [(from: SupervisorState, event: SupervisorEvent, to: SupervisorState)] = [
        (.idle, .wake, .listening),
        (.listening, .startGuiding, .guiding),
        (.listening, .startDoing, .executing(.running)),
        (.listening, .startTask, .starting),
        (.listening, .dismiss, .idle),
        (.starting, .cancelWindowElapsed, .executing(.running)),
        (.starting, .cancel, .stopped),
        (.starting, .dismiss, .stopped),
        (.starting, .taskFailed, .failed),
        (.guiding, .taskFinished, .listening),
        (.guiding, .dismiss, .idle),
        (.executing(.running), .pause, .executing(.paused)),
        (.executing(.running), .steer, .executing(.running)),
        (.executing(.running), .requestConfirmation, .executing(.awaitingApproval)),
        (.executing(.running), .taskFinished, .reporting),
        (.executing(.running), .taskFailed, .failed),
        (.executing(.running), .cancel, .stopped),
        (.executing(.running), .dismiss, .stopped),
        (.executing(.paused), .resume, .executing(.running)),
        (.executing(.paused), .steer, .executing(.paused)),
        (.executing(.paused), .requestConfirmation, .executing(.awaitingApproval)),
        (.executing(.paused), .taskFailed, .failed),
        (.executing(.paused), .cancel, .stopped),
        (.executing(.paused), .dismiss, .stopped),
        (.executing(.awaitingApproval), .approveAction, .executing(.running)),
        (.executing(.awaitingApproval), .denyAction, .stopped),
        (.executing(.awaitingApproval), .dismiss, .stopped),
        (.reporting, .dismiss, .idle),
        (.failed, .retry, .starting),
        (.failed, .dismiss, .idle),
        (.failed, .cancel, .stopped),
        (.stopped, .dismiss, .idle),
    ]

    func testWakePathFromIdleToListening() throws {
        var machine = SupervisorStateMachine()
        XCTAssertEqual(try machine.send(.wake), .listening)
    }

    func testExecutingToAwaitingApprovalToExecutingOnApproval() throws {
        var machine = SupervisorStateMachine(initial: .executing(.running))
        XCTAssertEqual(try machine.send(.requestConfirmation), .executing(.awaitingApproval))
        XCTAssertEqual(try machine.send(.approveAction), .executing(.running))
    }

    func testAwaitingApprovalDenialGoesToStopped() throws {
        var machine = SupervisorStateMachine(initial: .executing(.awaitingApproval))
        XCTAssertEqual(try machine.send(.denyAction), .stopped)
        XCTAssertEqual(try machine.send(.dismiss), .idle)
    }

    func testFullDoCycleEndsBackAtIdle() throws {
        var machine = SupervisorStateMachine()
        _ = try machine.send(.wake)
        _ = try machine.send(.startDoing)
        _ = try machine.send(.taskFinished)
        XCTAssertEqual(machine.state, .reporting)
        _ = try machine.send(.dismiss)
        XCTAssertEqual(machine.state, .idle)
    }

    func testEveryLegalTransition() throws {
        for transition in legalTransitions {
            var machine = SupervisorStateMachine(initial: transition.from)
            XCTAssertEqual(
                try machine.send(transition.event),
                transition.to,
                "expected \(transition.event) from \(transition.from) to reach \(transition.to)"
            )
        }
    }

    func testEveryIllegalTransitionThrowsAndKeepsState() {
        for state in allStates {
            for event in allEvents where !legalTransitions.contains(where: { $0.from == state && $0.event == event }) {
                var machine = SupervisorStateMachine(initial: state)
                XCTAssertThrowsError(try machine.send(event), "expected \(event) from \(state) to be illegal") { error in
                    guard let illegal = error as? IllegalSupervisorTransitionError else {
                        return XCTFail("expected IllegalSupervisorTransitionError, got \(error)")
                    }
                    XCTAssertEqual(illegal.from, state)
                    XCTAssertEqual(illegal.event, event)
                }
                XCTAssertEqual(machine.state, state)
            }
        }
    }

    func testExecutingStateCannotBePausedAndAwaitingApprovalAtOnce() throws {
        var machine = SupervisorStateMachine(initial: .executing(.paused))

        XCTAssertEqual(try machine.send(.requestConfirmation), .executing(.awaitingApproval))
        XCTAssertThrowsError(try machine.send(.pause))
        XCTAssertThrowsError(try machine.send(.resume))
        XCTAssertEqual(machine.state, .executing(.awaitingApproval))
    }

    func testAsyncWrapperMatchesSyncBehavior() async throws {
        let orchestrator = AsyncSupervisorStateMachine()
        var current = await orchestrator.state
        XCTAssertEqual(current, .idle)
        _ = try await orchestrator.send(.wake)
        current = await orchestrator.state
        XCTAssertEqual(current, .listening)
        _ = try await orchestrator.send(.startDoing)
        current = await orchestrator.state
        XCTAssertEqual(current, .executing(.running))
        _ = try await orchestrator.send(.requestConfirmation)
        current = await orchestrator.state
        XCTAssertEqual(current, .executing(.awaitingApproval))
        _ = try await orchestrator.send(.denyAction)
        current = await orchestrator.state
        XCTAssertEqual(current, .stopped)
        _ = try await orchestrator.send(.dismiss)
        current = await orchestrator.state
        XCTAssertEqual(current, .idle)

        _ = try await orchestrator.send(.wake)
        _ = try await orchestrator.send(.startGuiding)
        _ = try await orchestrator.send(.taskFinished)
        current = await orchestrator.state
        XCTAssertEqual(current, .listening)
        await orchestrator.reset()
        current = await orchestrator.state
        XCTAssertEqual(current, .idle)
    }

    func testConcurrentWakeHasExactlyOneWinner() async {
        let orchestrator = AsyncSupervisorStateMachine()
        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        _ = try await orchestrator.send(.wake)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var successes = 0
            for await won in group {
                if won { successes += 1 }
            }
            return successes
        }
        XCTAssertEqual(winners, 1)
        let finalState = await orchestrator.state
        XCTAssertEqual(finalState, .listening)
    }

    func testStartingWindowCanBeCancelledBeforeExecution() throws {
        var machine = SupervisorStateMachine(initial: .starting)

        XCTAssertEqual(try machine.send(.cancel), .stopped)
        XCTAssertEqual(try machine.send(.dismiss), .idle)
    }

    func testPauseResumeAndSteerStayInsideDoFlow() throws {
        var machine = SupervisorStateMachine(initial: .executing(.running))

        XCTAssertEqual(try machine.send(.pause), .executing(.paused))
        XCTAssertEqual(try machine.send(.steer), .executing(.paused))
        XCTAssertEqual(try machine.send(.resume), .executing(.running))
    }

    func testFailureCanRetryThroughStartingWindow() throws {
        var machine = SupervisorStateMachine(initial: .executing(.running))

        XCTAssertEqual(try machine.send(.taskFailed), .failed)
        XCTAssertEqual(try machine.send(.retry), .starting)
    }
}
