import XCTest
import PerryCore
@testable import PerryRuntimes

final class TypedDoSupervisorTests: XCTestCase {
    func testTypedRunDeliversExactOperationAndVerifiesTypedResult() async throws {
        let action = try makeAction()
        let plan = try makePlan(action: action)
        let executor = RecordingTypedActionExecutor()
        let verifier = RecordingTypedActionVerifier()
        let events = TypedEventRecorder()
        let supervisor = DoSupervisor(
            activityLog: ActivityLog(),
            confirmer: StubTypedConfirmer(),
            typedVerifier: verifier,
            onTypedEvent: { event in await events.record(event) }
        )

        let outcome = await supervisor.run(plan: plan, typedExecutor: executor)
        let receivedAction = await executor.received
        let receivedVerifierAction = await verifier.receivedAction
        let receivedResult = await verifier.receivedResult
        let receivedEvents = await events.snapshot()

        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        XCTAssertEqual(receivedAction?.action.id, action.id)
        XCTAssertEqual(receivedAction?.action.operation, action.operation)
        XCTAssertEqual(receivedAction?.grant.scope, .action(action.id))
        XCTAssertEqual(receivedAction?.grant.planDigest, try plan.approvalDigest())
        XCTAssertEqual(receivedVerifierAction?.id, action.id)
        XCTAssertEqual(receivedVerifierAction?.operation, action.operation)
        XCTAssertEqual(receivedResult, ActionExecutionResult(action: action))
        XCTAssertEqual(receivedEvents.count, 2)
        if case .actionStarted(let index, let eventAction, _) = receivedEvents[0] {
            XCTAssertEqual(index, 0)
            XCTAssertEqual(eventAction.id, action.id)
            XCTAssertEqual(eventAction.operation, action.operation)
        } else {
            XCTFail("expected typed action progress event")
        }
        if case .verification(let eventAction, .verified(let evidence)) = receivedEvents[1] {
            XCTAssertEqual(eventAction.id, action.id)
            XCTAssertEqual(eventAction.operation, action.operation)
            XCTAssertEqual(evidence, "typed postcondition verified")
        } else {
            XCTFail("expected typed verification event")
        }
    }

    func testTypedRunRejectsNoOpVerificationForActionPostcondition() async throws {
        let action = try makeAction()
        let executor = RecordingTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer()
        )

        let outcome = await supervisor.run(
            plan: try makePlan(action: action),
            typedExecutor: executor
        )

        guard case .failed(_, let reason) = outcome else {
            return XCTFail("expected no-op verification failure, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("verification"))
    }

    func testTypedRunRejectsFailedVerification() async throws {
        let action = try makeAction()
        let executor = RecordingTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer(),
            typedVerifier: FailingTypedActionVerifier()
        )

        let outcome = await supervisor.run(
            plan: try makePlan(action: action),
            typedExecutor: executor
        )

        guard case .failed(_, let reason) = outcome else {
            return XCTFail("expected verifier failure, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("verification failed"))
    }

    func testTypedRunCancellationReachesExecutor() async throws {
        let action = try makeAction()
        let executor = CancellableTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer()
        )
        let run = Task {
            await supervisor.run(
                plan: try! makePlan(action: action),
                typedExecutor: executor
            )
        }

        await executor.waitUntilStarted()

        await supervisor.cancel()
        let outcome = await run.value
        let cancellationObserved = await executor.cancellationObserved
        XCTAssertEqual(outcome, .blocked(reason: "user cancelled the task"))
        XCTAssertTrue(cancellationObserved)
    }

    func testTypedRunTimeoutCancelsExecutorAndFailsClosed() async throws {
        let action = try makeAction(timeout: 0.03)
        let executor = CancellableTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer()
        )

        let run = Task {
            await supervisor.run(
                plan: try! makePlan(action: action),
                typedExecutor: executor
            )
        }
        await executor.waitUntilStarted()
        let outcome = await run.value

        guard case .failed(_, let reason) = outcome else {
            return XCTFail("expected typed timeout failure, got \(outcome)")
        }
        let cancellationObserved = await executor.cancellationObserved
        XCTAssertTrue(reason.contains("exceeded"))
        XCTAssertTrue(cancellationObserved)
    }

    func testTypedRunCancellationDuringVerificationReturnsPromptlyWithoutRecording() async throws {
        let action = try makeAction()
        let executor = RecordingTypedActionExecutor()
        let verifier = SuspendedTypedActionVerifier()
        let log = ActivityLog()
        let supervisor = DoSupervisor(
            activityLog: log,
            confirmer: StubTypedConfirmer(),
            typedVerifier: verifier
        )
        let run = Task {
            await supervisor.run(
                plan: try! makePlan(action: action),
                typedExecutor: executor
            )
        }

        for _ in 0..<20 {
            if await verifier.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let verificationStarted = await verifier.started
        XCTAssertTrue(verificationStarted)

        let started = Date()
        await supervisor.cancel()
        let outcome = await run.value
        let elapsed = Date().timeIntervalSince(started)
        let cancellationObserved = await verifier.cancellationObserved
        let entries = await log.snapshot()

        XCTAssertEqual(outcome, .blocked(reason: "user cancelled the task"))
        XCTAssertTrue(cancellationObserved)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(entries.isEmpty)
    }

    func testRunAsksNothingForLocalActions() async throws {
        let rename = try ExecutableAction(
            id: ActionID("rename-report"),
            summary: "Rename report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: URL(fileURLWithPath: "/tmp/perry-typed-supervisor"),
                command: .rename(path: "report.txt", destination: "done.txt")
            ),
            postcondition: .renamedItem(device: 1, inode: 2)
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("user-requested-task"),
            goal: "Write report",
            actions: [try makeAction(), rename],
            requestedScopes: [.workspaceWrite]
        )
        let confirmer = RecordingConfirmer()
        let executor = RecordingTypedActionExecutor()
        let supervisor = DoSupervisor(
            activityLog: ActivityLog(),
            confirmer: confirmer,
            typedVerifier: RecordingTypedActionVerifier()
        )

        let outcome = await supervisor.run(plan: plan, typedExecutor: executor)
        let requests = await confirmer.requests

        XCTAssertEqual(outcome, .completed(stepsRun: 2))
        XCTAssertEqual(requests.count, 0)
    }

    func testDeniedQuestionBlocksWithoutDispatching() async throws {
        let ask = try ExecutableAction(
            id: ActionID("ask"),
            summary: "Ask which folder",
            approvalRequirement: .action,
            operation: .askUser(prompt: "Which folder?", choices: ["A", "B"]),
            postcondition: .answered
        )
        let executor = RecordingTypedActionExecutor()
        let supervisor = DoSupervisor(confirmer: DenyingConfirmer())

        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("ask-task"),
            goal: "Ask",
            actions: [ask],
            requestedScopes: []
        )

        let outcome = await supervisor.run(plan: plan, typedExecutor: executor)
        let received = await executor.received

        XCTAssertEqual(outcome, .blocked(reason: "user denied Ask which folder"))
        XCTAssertNil(received)
    }

    private func makeAction(timeout: TimeInterval = 30) throws -> ExecutableAction {
        try ExecutableAction(
            id: ActionID("write-report"),
            summary: "Write report",
            timeout: timeout,
            approvalRequirement: .action,
            operation: .transform(
                workspace: URL(fileURLWithPath: "/tmp/perry-typed-supervisor"),
                command: .createUTF8File(path: "report.txt", contents: "hello")
            ),
            postcondition: .fileContents("hello")
        )
    }

    private func makePlan(action: ExecutableAction) throws -> PerryRuntimes.ExecutionPlan {
        try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("typed-supervisor-task"),
            goal: "Write report",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}

private actor StubTypedConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private struct DenyingConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { false }
}

private actor RecordingConfirmer: Confirmer {
    private(set) var requests: [ConfirmationRequest] = []

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        requests.append(request)
        return true
    }
}

private actor RecordingTypedActionExecutor: ExecutableActionExecutor {
    private(set) var received: ApprovedExecutableAction?

    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        received = approvedAction
        return ActionExecutionResult(action: approvedAction.action)
    }
}

private actor RecordingTypedActionVerifier: TypedActionVerifier {
    private(set) var receivedAction: ExecutableAction?
    private(set) var receivedResult: ActionExecutionResult?

    func verify(approvedAction: ApprovedExecutableAction, result: ActionExecutionResult, context: ScreenContext) async -> VerificationStatus {
        receivedAction = approvedAction.action
        receivedResult = result
        return .verified(evidence: "typed postcondition verified")
    }
}

private actor FailingTypedActionVerifier: TypedActionVerifier {
    func verify(approvedAction: ApprovedExecutableAction, result: ActionExecutionResult, context: ScreenContext) async -> VerificationStatus {
        .unverified(reason: "typed postcondition did not match")
    }
}

private actor SuspendedTypedActionVerifier: TypedActionVerifier {
    private(set) var started = false
    private(set) var cancellationObserved = false
    private var continuation: CheckedContinuation<VerificationStatus, Never>?

    func verify(approvedAction: ApprovedExecutableAction, result: ActionExecutionResult, context: ScreenContext) async -> VerificationStatus {
        started = true
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }, onCancel: {
            Task { await self.cancelVerification() }
        })
    }

    private func cancelVerification() {
        cancellationObserved = true
        continuation?.resume(returning: .unverified(reason: "verification cancelled"))
        continuation = nil
    }
}

private actor TypedEventRecorder {
    private var events: [TypedDoEvent] = []

    func record(_ event: TypedDoEvent) {
        events.append(event)
    }

    func snapshot() -> [TypedDoEvent] {
        events
    }
}

private actor CancellableTypedActionExecutor: ExecutableActionExecutor {
    private(set) var started = false
    private(set) var cancellationObserved = false
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startedContinuation = continuation
            }
        }
    }

    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ActionExecutionResult(action: approvedAction.action)
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }
}
