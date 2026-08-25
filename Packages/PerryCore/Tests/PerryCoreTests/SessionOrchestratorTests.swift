import XCTest
@testable import PerryCore

final class SessionOrchestratorTests: XCTestCase {
    func testWakePathFromIdleToListening() throws {
        var machine = SessionOrchestrator()
        XCTAssertEqual(try machine.send(.wake), .listening)
    }

    func testDoingToConfirmingToDoingOnApproval() throws {
        var machine = SessionOrchestrator(initial: .doing)
        XCTAssertEqual(try machine.send(.requestConfirmation), .confirming)
        XCTAssertEqual(try machine.send(.approveAction), .doing)
    }

    func testDenialFromConfirmationGoesToStopped() throws {
        var machine = SessionOrchestrator(initial: .confirming)
        XCTAssertEqual(try machine.send(.denyAction), .stopped)
        XCTAssertEqual(try machine.send(.dismiss), .idle)
    }

    func testFullDoCycleEndsBackAtIdle() throws {
        var machine = SessionOrchestrator()
        try machine.send(.wake)
        try machine.send(.startDoing)
        try machine.send(.taskFinished)
        XCTAssertEqual(machine.state, .reporting)
        try machine.send(.dismiss)
        XCTAssertEqual(machine.state, .idle)
    }

    func testIllegalTransitionThrowsAndKeepsState() {
        var machine = SessionOrchestrator()
        XCTAssertThrowsError(try machine.send(.taskFinished)) { error in
            guard let illegal = error as? IllegalTransitionError else {
                return XCTFail("expected IllegalTransitionError, got \(error)")
            }
            XCTAssertEqual(illegal.from, .idle)
            XCTAssertEqual(illegal.event, .taskFinished)
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testConfirmingRejectsTaskFinished() {
        var machine = SessionOrchestrator(initial: .confirming)
        XCTAssertThrowsError(try machine.send(.taskFinished))
        XCTAssertEqual(machine.state, .confirming)
    }

    func testAsyncWrapperMatchesSyncBehavior() async throws {
        let orchestrator = AsyncSessionOrchestrator()
        var current = await orchestrator.state
        XCTAssertEqual(current, .idle)
        _ = try await orchestrator.send(.wake)
        current = await orchestrator.state
        XCTAssertEqual(current, .listening)
        _ = try await orchestrator.send(.startGuiding)
        _ = try await orchestrator.send(.taskFinished)
        current = await orchestrator.state
        XCTAssertEqual(current, .listening)
        await orchestrator.reset()
        current = await orchestrator.state
        XCTAssertEqual(current, .idle)
    }

    func testConcurrentWakeHasExactlyOneWinner() async {
        let orchestrator = AsyncSessionOrchestrator()
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
}
