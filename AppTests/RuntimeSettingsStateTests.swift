import XCTest
@testable import Perry

@MainActor
final class RuntimeSettingsStateTests: XCTestCase {
    func testReplacementCancelsPreviousLoadAndRejectsItsLateResult() async throws {
        let firstStarted = expectation(description: "First status check started")
        let secondStarted = expectation(description: "Replacement status check started")
        var firstReply: CheckedContinuation<RuntimeSettingsState.Status, Never>?
        var secondReply: CheckedContinuation<RuntimeSettingsState.Status, Never>?
        var calls = 0
        var firstObservedCancellation = false
        let state = RuntimeSettingsState {
            calls += 1
            if calls == 1 {
                let status = await withCheckedContinuation { firstReply = $0; firstStarted.fulfill() }
                firstObservedCancellation = Task.isCancelled
                return status
            }
            return await withCheckedContinuation { secondReply = $0; secondStarted.fulfill() }
        }

        let first = state.refresh()
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = state.refresh()
        await fulfillment(of: [secondStarted], timeout: 1)
        let current = status("Current runtime", cua: "Current driver")
        try XCTUnwrap(secondReply).resume(returning: current)
        await second.value
        XCTAssertEqual(state.status, current)

        try XCTUnwrap(firstReply).resume(returning: status("Stale runtime", cua: "Stale driver"))
        await first.value

        XCTAssertTrue(firstObservedCancellation)
        XCTAssertEqual(state.status, current)
        XCTAssertEqual(calls, 2)
    }

    func testCancelPreservesLastPublishedStatusAndAllowsAnotherRefresh() async throws {
        let pendingStarted = expectation(description: "Pending check started")
        var pendingReply: CheckedContinuation<RuntimeSettingsState.Status, Never>?
        var calls = 0
        var pendingObservedCancellation = false
        let initial = status("Initial runtime", cua: "Initial driver")
        let reopened = status("Reopened runtime", cua: "Reopened driver")
        let state = RuntimeSettingsState {
            calls += 1
            if calls == 1 { return initial }
            if calls == 3 { return reopened }
            let status = await withCheckedContinuation { pendingReply = $0; pendingStarted.fulfill() }
            pendingObservedCancellation = Task.isCancelled
            return status
        }

        await state.refresh().value
        let pending = state.refresh()
        await fulfillment(of: [pendingStarted], timeout: 1)
        state.cancel()
        try XCTUnwrap(pendingReply).resume(returning: status("Canceled runtime", cua: "Canceled driver"))
        await pending.value

        XCTAssertTrue(pendingObservedCancellation)
        XCTAssertEqual(state.status, initial)
        await state.refresh().value
        XCTAssertEqual(state.status, reopened)
    }

    func testCancelBeforeStartDoesNotLaunchProbes() async {
        var calls = 0
        let state = RuntimeSettingsState {
            calls += 1
            return self.status("Should not load", cua: "Should not probe")
        }
        let initial = state.status

        let task = state.refresh()
        state.cancel()
        await task.value

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(state.status, initial)
    }

    func testPendingCheckDoesNotKeepSettingsStateAlive() async throws {
        let started = expectation(description: "Status check started")
        var reply: CheckedContinuation<RuntimeSettingsState.Status, Never>?
        var observedCancellation = false
        var state: RuntimeSettingsState? = RuntimeSettingsState {
            let status = await withCheckedContinuation { reply = $0; started.fulfill() }
            observedCancellation = Task.isCancelled
            return status
        }
        let isReleased = { [weak state] in state == nil }
        let task = try XCTUnwrap(state).refresh()
        await fulfillment(of: [started], timeout: 1)

        state = nil
        XCTAssertTrue(isReleased())
        try XCTUnwrap(reply).resume(returning: status("Late runtime", cua: "Late driver"))
        await task.value

        XCTAssertTrue(observedCancellation)
    }

    private func status(_ summary: String, cua: String) -> RuntimeSettingsState.Status {
        RuntimeSettingsState.Status(
            setup: RuntimeSetupSnapshot(summary: summary, records: [
                RuntimeSetupRecord(
                    id: summary, name: summary, status: summary,
                    isReady: false, authentication: .missing,
                    signInCommand: nil, signOutCommand: nil
                ),
            ]),
            cuaStatus: cua
        )
    }
}
