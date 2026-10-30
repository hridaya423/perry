import Foundation
import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BackgroundTaskControlScopeTests: XCTestCase {
    func testNewMaintenanceSupersedesPendingControlReopening() async throws {
        let scope = BackgroundTaskControlScope()
        let gate = TestContinuationGate()
        let finished = expectation(description: "control finished")
        XCTAssertTrue(scope.start {
            await gate.wait()
            finished.fulfill()
        })
        scope.close()
        scope.reopen()
        scope.close()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(scope.acceptsControls)
        let cleanup = Task { @MainActor in try await scope.closeAndDrain() }
        try await finishControlTask(cleanup)
        scope.reopen()
        XCTAssertTrue(scope.acceptsControls)
    }

    func testCancelledDrainRetainsControlOwnershipUntilRetry() async throws {
        let scope = BackgroundTaskControlScope()
        let gate = TestContinuationGate()
        let entered = expectation(description: "control entered")
        XCTAssertTrue(scope.start {
            entered.fulfill()
            await gate.wait()
        })
        addTeardownBlock {
            await gate.release()
            let cleanup = Task { @MainActor in try await scope.closeAndDrain() }
            try await finishControlTask(cleanup)
        }
        await fulfillment(of: [entered], timeout: 2)
        scope.close()
        let drain = Task { @MainActor in try await scope.closeAndDrain() }
        drain.cancel()
        do {
            try await finishControlTask(drain)
            XCTFail("A cancelled drain must not authorize maintenance")
        } catch is CancellationError {
        }
        scope.reopen()
        XCTAssertFalse(scope.acceptsControls)
        XCTAssertFalse(scope.start { XCTFail("A control was admitted during cancelled drainage") })
        await gate.release()
        let retry = Task { @MainActor in try await scope.closeAndDrain() }
        try await finishControlTask(retry)
        scope.reopen()
        XCTAssertTrue(scope.acceptsControls)
    }

    func testUnfinishedControlBlocksMaintenanceAndBoundsDrain() async throws {
        let scope = BackgroundTaskControlScope()
        let gate = TestContinuationGate()
        let entered = expectation(description: "control entered")
        let finished = expectation(description: "control finished")
        XCTAssertTrue(scope.start {
            entered.fulfill()
            await gate.wait()
            finished.fulfill()
        })
        await fulfillment(of: [entered], timeout: 2)
        let fallbackRelease = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await gate.release()
        }
        addTeardownBlock {
            fallbackRelease.cancel()
            await gate.release()
            try await finishControlTask(fallbackRelease)
            let cleanup = Task { @MainActor in try await scope.closeAndDrain() }
            try await finishControlTask(cleanup)
        }
        let started = ContinuousClock.now
        let refusedMaintenance = Task { @MainActor in
            do {
                try await scope.closeAndDrain()
                return false
            } catch BackgroundTaskControlScope.DrainError.timedOut {
                return true
            } catch {
                XCTFail("Unexpected drain failure: \(error)")
                return false
            }
        }
        let refused = try await finishControlTask(refusedMaintenance)
        XCTAssertTrue(refused, "Maintenance must fail if an owned control has not finished")
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(750))
        scope.reopen()
        XCTAssertFalse(scope.acceptsControls)
        XCTAssertFalse(scope.start { XCTFail("Control admission unexpectedly reopened") })
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(scope.acceptsControls)
    }

    func testDrainingControlCompletesCancellationHistoryBeforeStoreWipe() async throws {
        let directory = try makeTemporaryDirectory()
        let gate = TestContinuationGate()
        let scope = BackgroundTaskControlScope()
        addTeardownBlock {
            await gate.release()
            let cleanup = Task { @MainActor in try await scope.closeAndDrain() }
            try await finishControlTask(cleanup)
            try TestTempDirectory.remove(directory)
        }

        let coordinator = TaskCoordinator(storageDirectory: directory)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: NotificationBox())
        let contextStore = BackgroundTaskContextStore(storageDirectory: directory)
        let transcriptStore = TranscriptStore(directory: directory)
        let taskID = TaskID("cancelled")
        let startedAt = Date()
        let plan = try workspacePlan(taskID: taskID, goal: "cancel before erase", workspace: directory)
        _ = try await coordinator.enqueue(executablePlan: plan)
        try await contextStore.save(BackgroundTaskMetadata(targetWindowTitle: "Fixture"), for: taskID)

        let cancellationPersisted = expectation(description: "cancellation persisted")
        let entry = TranscriptEntry(
            id: UUID(),
            sessionID: UUID(),
            request: plan.goal,
            appBundleID: nil,
            summary: "Stopped safely",
            outcome: .stopped,
            startedAt: startedAt,
            finishedAt: startedAt,
            steps: [],
            verified: nil
        )
        XCTAssertTrue(scope.start { @MainActor in
            do {
                try await runner.cancel(id: taskID)
                cancellationPersisted.fulfill()
                await gate.wait()
                _ = try await coordinator.finishCancellation(id: taskID, reason: "user cancelled the task")
                _ = await transcriptStore.append(entry)
                try await contextStore.remove(for: taskID)
            } catch {
                XCTFail("Cancellation control failed: \(error)")
            }
        })
        await fulfillment(of: [cancellationPersisted], timeout: 2)

        scope.close()
        XCTAssertFalse(scope.start { })
        let drainCompleted = CompletionProbe()
        let drain = Task { @MainActor in
            try await scope.closeAndDrain()
            await drainCompleted.mark()
        }
        try await Task.sleep(for: .milliseconds(50))
        let completedBeforeRelease = await drainCompleted.value()
        let historyBeforeRelease = await transcriptStore.snapshot()
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertTrue(historyBeforeRelease.isEmpty)

        await gate.release()
        try await finishControlTask(drain)
        let completedAfterRelease = await drainCompleted.value()
        let cancelledRecord = await coordinator.record(id: taskID)
        let recordedHistory = await transcriptStore.snapshot()
        let removedContext = await contextStore.metadata(for: taskID)
        XCTAssertTrue(completedAfterRelease)
        XCTAssertNil(cancelledRecord)
        XCTAssertEqual(recordedHistory, [entry])
        XCTAssertNil(removedContext)

        let historyErased = await transcriptStore.wipe()
        let contextErased = try await contextStore.wipe()
        XCTAssertTrue(historyErased)
        XCTAssertTrue(contextErased)
        let reloadedTranscript = TranscriptStore(directory: directory)
        let reloadedContext = BackgroundTaskContextStore(storageDirectory: directory)
        let historyAfterErase = await reloadedTranscript.snapshot()
        let contextAfterErase = await reloadedContext.metadata(for: taskID)
        XCTAssertTrue(historyAfterErase.isEmpty)
        XCTAssertNil(contextAfterErase)
    }

    func testDrainingControlSerializesInFlightWorkspacePauseAcrossReload() async throws {
        let directory = try makeTemporaryDirectory()
        let gate = TestContinuationGate()
        let scope = BackgroundTaskControlScope()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: NotificationBox())
        let taskID = TaskID("active")
        let actionID = ActionID("dispatch")
        let plan = try workspacePlan(taskID: taskID, goal: "pause after dispatch", workspace: directory, actionID: actionID)
        _ = try await coordinator.enqueue(executablePlan: plan)
        let queuedRecord = await coordinator.record(id: taskID)
        let queued = try XCTUnwrap(queuedRecord)
        let prepared = try await coordinator.approveWorkspaceAction(id: taskID, expectedRevision: queued.revision)
        let dispatched = try await coordinator.beginWorkspaceDispatch(id: taskID, expectedRevision: prepared.revision)
        addTeardownBlock {
            await gate.release()
            let cleanup = Task { @MainActor in try await scope.closeAndDrain() }
            try await finishControlTask(cleanup)
            try TestTempDirectory.remove(directory)
        }

        XCTAssertEqual(dispatched.state, .running)
        XCTAssertEqual(dispatched.checkpoint.inFlightStepID, actionID.rawValue)

        let pausePersisted = expectation(description: "in-flight pause persisted")
        XCTAssertTrue(scope.start { @MainActor in
            do {
                try await runner.pause(id: taskID)
                pausePersisted.fulfill()
                await gate.wait()
            } catch {
                XCTFail("Pause control failed: \(error)")
            }
        })
        await fulfillment(of: [pausePersisted], timeout: 2)

        let pausedRecord = await coordinator.record(id: taskID)
        let paused = try XCTUnwrap(pausedRecord)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.intent, .pause)
        XCTAssertEqual(paused.checkpoint.inFlightStepID, actionID.rawValue)
        XCTAssertTrue(paused.requiresReconciliation)

        scope.close()
        XCTAssertFalse(scope.start { })
        let drainCompleted = CompletionProbe()
        let drain = Task { @MainActor in
            try await scope.closeAndDrain()
            await drainCompleted.mark()
        }
        try await Task.sleep(for: .milliseconds(50))
        let completedBeforeRelease = await drainCompleted.value()
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        try await finishControlTask(drain)
        let completedAfterRelease = await drainCompleted.value()
        XCTAssertTrue(completedAfterRelease)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let retainedRecord = await reloaded.record(id: taskID)
        let retained = try XCTUnwrap(retainedRecord)
        XCTAssertEqual(retained.state, .paused)
        XCTAssertEqual(retained.intent, .pause)
        XCTAssertEqual(retained.checkpoint.inFlightStepID, actionID.rawValue)
        XCTAssertTrue(retained.requiresReconciliation)
    }

    private func workspacePlan(
        taskID: TaskID,
        goal: String,
        workspace: URL,
        actionID: ActionID = ActionID("create-file")
    ) throws -> ExecutionPlan {
        let action = try ExecutableAction(
            id: actionID,
            summary: "create the result file",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "result.txt", contents: "done")
            ),
            postcondition: .fileContents("done")
        )
        return try ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}

@MainActor
final class GuideCallbackAdmissionTests: XCTestCase {
    func testClosedGuideSessionRejectsLateCallbacks() async {
        let scope = GuideWorkerSession(id: UUID())
        let gate = TestContinuationGate()
        scope.start(.presentation) { await gate.wait() }
        scope.closeAndCancel()

        XCTAssertFalse(scope.startAction { XCTFail("An action started after closure") })
        scope.start(.repoint) { XCTFail("A callback registered after closure") }
        await gate.release()
        await scope.drain()
    }
}

@MainActor
private func finishControlTask<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) async throws -> Value {
    let completed = XCTestExpectation(description: "owned task finished")
    let waiter = Task {
        let result = await task.result
        completed.fulfill()
        return result
    }
    guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
        task.cancel()
        throw ControlScopeTestError.timeout
    }
    return try await waiter.value.get()
}

private enum ControlScopeTestError: Error {
    case timeout
}

private actor TestContinuationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor CompletionProbe {
    private var completed = false

    func mark() {
        completed = true
    }

    func value() -> Bool {
        completed
    }
}

private actor NotificationBox: Notifying {
    func deliver(_ notification: TaskNotification) async {}
}
