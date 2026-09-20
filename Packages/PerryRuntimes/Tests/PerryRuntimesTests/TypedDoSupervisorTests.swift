import XCTest
import PerryCore
@testable import PerryRuntimes

final class TypedDoSupervisorTests: XCTestCase {
    func testTypedProductionPathHasNoLegacyPlanBridge() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PerryRuntimes")
        let sources = try ["DoSupervisor.swift", "RuntimeTypes.swift"].map {
            try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(sources.contains("PerryCore.ExecutionPlan"))
        XCTAssertFalse(sources.contains("ExecutionPlanAdapter"))

        let typedExecutionStart = "    private func execute(\n        _ plan: ExecutionPlan,"
        let typedExecutionEnd = "    private func enterDoing()"
        guard let start = sources.range(of: typedExecutionStart),
              let end = sources.range(of: typedExecutionEnd, range: start.upperBound..<sources.endIndex) else {
            return XCTFail("typed execution implementation was not found")
        }
        let typedExecution = sources[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(typedExecution.contains("LegacyPlanAdapter"))
        XCTAssertFalse(typedExecution.contains("AgentRuntime"))
        XCTAssertFalse(typedExecution.contains("action.step"))
        XCTAssertFalse(typedExecution.contains("Step("))
    }

    func testTypedRunDeliversExactOperationAndVerifiesTypedResult() async throws {
        let action = try makeAction()
        let plan = try makePlan(action: action)
        let executor = RecordingTypedActionExecutor()
        let verifier = RecordingTypedActionVerifier()
        let events = TypedEventRecorder()
        let supervisor = DoSupervisor(
            activityLog: ActivityLog(),
            confirmer: StubTypedConfirmer(approved: true),
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
            confirmer: StubTypedConfirmer(approved: true)
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
            confirmer: StubTypedConfirmer(approved: true),
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

    func testTypedRunDenialPreventsDispatch() async throws {
        let action = try makeAction()
        let executor = RecordingTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer(approved: false)
        )

        let outcome = await supervisor.run(
            plan: try makePlan(action: action),
            typedExecutor: executor
        )
        let receivedAction = await executor.received

        XCTAssertEqual(outcome, .blocked(reason: "user denied Write report"))
        XCTAssertNil(receivedAction)
    }

    func testTypedRunCancellationReachesExecutor() async throws {
        let action = try makeAction()
        let executor = CancellableTypedActionExecutor()
        let supervisor = DoSupervisor(
            confirmer: StubTypedConfirmer(approved: true)
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
            confirmer: StubTypedConfirmer(approved: true)
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
            confirmer: StubTypedConfirmer(approved: true),
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
    let approved: Bool

    init(approved: Bool) {
        self.approved = approved
    }

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        approved
    }
}

private actor RecordingTypedActionExecutor: TypedActionExecutor {
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

private actor CancellableTypedActionExecutor: TypedActionExecutor {
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
