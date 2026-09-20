import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class WorkspaceExecutionJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-workspace-execution-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testTwoCompletedActionsRetainAttemptsReceiptsAndOrder() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: firstAttempt, receipt: try await fixture.receipt(for: 0)),
                .init(attempt: secondAttempt, receipt: try await fixture.receipt(for: 1)),
            ],
            current: nil
        )

        try journal.validate(plan: fixture.plan, checkpoint: journal.checkpoint)
        XCTAssertEqual(journal.completed.count, 2)
        XCTAssertEqual(journal.completed[0].attempt.id, firstAttempt.id)
        XCTAssertEqual(journal.completed[1].attempt.id, secondAttempt.id)
        XCTAssertEqual(journal.completed[0].receipt.actionID, fixture.plan.actions[0].id)
        XCTAssertEqual(journal.completed[1].receipt.actionID, fixture.plan.actions[1].id)
        XCTAssertNil(journal.current)
        XCTAssertEqual(journal.checkpoint, TaskCheckpoint(nextStepIndex: 2))

        let restored = try JSONDecoder().decode(
            WorkspaceExecutionJournal.self,
            from: JSONEncoder().encode(journal)
        )
        try restored.validate(plan: fixture.plan, checkpoint: restored.checkpoint)
        XCTAssertEqual(restored.completed[0].receipt, journal.completed[0].receipt)
        XCTAssertEqual(restored.completed[1].attempt.grant.id, fixture.secondGrant.id)
    }

    func testPartialPrefixValidatesPreparedAndDispatchedCurrentActions() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        let first = WorkspaceExecutionJournal.CompletedAction(
            attempt: firstAttempt,
            receipt: try await fixture.receipt(for: 0)
        )

        let prepared = WorkspaceExecutionJournal(
            completed: [first],
            current: .prepared(secondAttempt)
        )
        try prepared.validate(plan: fixture.plan, checkpoint: prepared.checkpoint)
        XCTAssertEqual(prepared.checkpoint, TaskCheckpoint(nextStepIndex: 1))

        let dispatched = WorkspaceExecutionJournal(
            completed: [first],
            current: .dispatched(secondAttempt)
        )
        try dispatched.validate(plan: fixture.plan, checkpoint: dispatched.checkpoint)
        XCTAssertEqual(
            dispatched.checkpoint,
            TaskCheckpoint(nextStepIndex: 1, inFlightStepID: fixture.plan.actions[1].id.rawValue)
        )
    }

    func testDuplicateAttemptIDIsRejected() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let secondAttempt = try attempt(
            withID: firstAttempt.id,
            from: WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        )
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: firstAttempt, receipt: try await fixture.receipt(for: 0)),
                .init(attempt: secondAttempt, receipt: try await fixture.receipt(for: 1)),
            ],
            current: nil
        )

        assertValidationError(.duplicateAttempt(firstAttempt.id)) {
            try journal.validate(plan: fixture.plan, checkpoint: journal.checkpoint)
        }
    }

    func testDuplicateGrantIDIsRejected() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let duplicateGrant = try grant(withID: fixture.firstGrant.id, from: fixture.secondGrant)
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: duplicateGrant)
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: firstAttempt, receipt: try await fixture.receipt(for: 0)),
                .init(attempt: secondAttempt, receipt: try await fixture.receipt(for: 1)),
            ],
            current: nil
        )

        assertValidationError(.duplicateGrant(firstAttempt.grant.id)) {
            try journal.validate(plan: fixture.plan, checkpoint: journal.checkpoint)
        }
    }

    func testCompletedOrderIsRejected() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: secondAttempt, receipt: try await fixture.receipt(for: 1)),
                .init(attempt: firstAttempt, receipt: try await fixture.receipt(for: 0)),
            ],
            current: nil
        )

        assertValidationError(.completedIndexMismatch(expected: 0, actual: 1)) {
            try journal.validate(plan: fixture.plan, checkpoint: journal.checkpoint)
        }
    }

    func testCurrentActionAfterFullPrefixIsRejected() async throws {
        let fixture = try await makeFixture()
        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: firstAttempt, receipt: try await fixture.receipt(for: 0)),
                .init(attempt: secondAttempt, receipt: try await fixture.receipt(for: 1)),
            ],
            current: .prepared(secondAttempt)
        )

        assertValidationError(.currentAfterCompletedPlan) {
            try journal.validate(plan: fixture.plan, checkpoint: journal.checkpoint)
        }
    }

    func testWrongPlanAndCheckpointAreRejected() async throws {
        let fixture = try await makeFixture()
        let attempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let journal = WorkspaceExecutionJournal(
            completed: [
                .init(attempt: attempt, receipt: try await fixture.receipt(for: 0)),
            ],
            current: nil
        )
        let otherPlan = try makePlan()

        assertValidationError(.invalidCompletedAction(index: 0)) {
            try journal.validate(plan: otherPlan, checkpoint: journal.checkpoint)
        }
        assertValidationError(
            .checkpointMismatch(expected: journal.checkpoint, actual: TaskCheckpoint(nextStepIndex: 0))
        ) {
            try journal.validate(plan: fixture.plan, checkpoint: TaskCheckpoint(nextStepIndex: 0))
        }
    }

    func testLegacyVerifiedIndexZeroConvertsToCompletedPrefix() async throws {
        let fixture = try await makeFixture()
        let attempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let receipt = try await fixture.receipt(for: 0)
        let converted = try WorkspaceExecutionJournal(
            legacy: .verified(attempt, receipt),
            plan: fixture.plan,
            checkpoint: TaskCheckpoint(nextStepIndex: 1)
        )

        XCTAssertEqual(converted.completed.count, 1)
        XCTAssertEqual(converted.completed[0].attempt.id, attempt.id)
        XCTAssertEqual(converted.completed[0].receipt, receipt)
        XCTAssertNil(converted.current)
        XCTAssertEqual(converted.checkpoint, TaskCheckpoint(nextStepIndex: 1))
    }

    func testLegacyPreparedAndDispatchedIndexZeroConvertToCurrentAction() async throws {
        let fixture = try await makeFixture()
        let attempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let cases: [(WorkspaceActionJournal, TaskCheckpoint)] = [
            (.prepared(attempt), TaskCheckpoint(nextStepIndex: 0)),
            (.dispatched(attempt), TaskCheckpoint(nextStepIndex: 0, inFlightStepID: fixture.plan.actions[0].id.rawValue)),
        ]

        for (legacy, checkpoint) in cases {
            let converted = try WorkspaceExecutionJournal(
                legacy: legacy,
                plan: fixture.plan,
                checkpoint: checkpoint
            )
            XCTAssertTrue(converted.completed.isEmpty)
            XCTAssertEqual(converted.checkpoint, checkpoint)
            switch legacy {
            case .prepared:
                guard case .prepared(let current)? = converted.current else {
                    return XCTFail("prepared legacy journal did not remain prepared")
                }
                XCTAssertEqual(current.id, attempt.id)
            case .dispatched:
                guard case .dispatched(let current)? = converted.current else {
                    return XCTFail("dispatched legacy journal did not remain dispatched")
                }
                XCTAssertEqual(current.id, attempt.id)
            case .verified:
                return XCTFail("unexpected verified legacy journal")
            }
        }
    }

    func testLegacyConversionRejectsMissingPrefixAndInvalidCheckpoint() async throws {
        let fixture = try await makeFixture()
        let secondAttempt = WorkspaceActionJournal.Attempt(actionIndex: 1, grant: fixture.secondGrant)
        let secondReceipt = try await fixture.receipt(for: 1)
        let legacyCases: [(WorkspaceActionJournal, TaskCheckpoint)] = [
            (.prepared(secondAttempt), TaskCheckpoint(nextStepIndex: 1)),
            (.dispatched(secondAttempt), TaskCheckpoint(nextStepIndex: 1, inFlightStepID: fixture.plan.actions[1].id.rawValue)),
            (.verified(secondAttempt, secondReceipt), TaskCheckpoint(nextStepIndex: 2)),
        ]

        for (legacy, checkpoint) in legacyCases {
            assertValidationError(.legacyMissingPrefix(index: 1)) {
                _ = try WorkspaceExecutionJournal(legacy: legacy, plan: fixture.plan, checkpoint: checkpoint)
            }
        }

        let firstAttempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        assertValidationError(.invalidLegacyJournal) {
            _ = try WorkspaceExecutionJournal(
                legacy: .prepared(firstAttempt),
                plan: fixture.plan,
                checkpoint: TaskCheckpoint(nextStepIndex: 1)
            )
        }
    }

    func testUnknownTopLevelAndCurrentFieldsAreRejected() async throws {
        let fixture = try await makeFixture()
        let attempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: fixture.firstGrant)
        let journal = WorkspaceExecutionJournal(completed: [], current: .prepared(attempt))
        var fields = try jsonObject(try JSONEncoder().encode(journal))
        fields["future"] = true
        try assertDecodeRejected(fields)

        fields = try jsonObject(try JSONEncoder().encode(journal))
        var current = try XCTUnwrap(fields["current"] as? [String: Any])
        current["future"] = true
        fields["current"] = current
        try assertDecodeRejected(fields)
    }

    private func makeFixture() async throws -> Fixture {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let firstGrant = try await registry.issue(plan: plan, scope: .action(plan.actions[0].id))
        let secondGrant = try await registry.issue(plan: plan, scope: .action(plan.actions[1].id))
        return Fixture(
            plan: plan,
            registry: registry,
            runtime: WorkspaceFileRuntime(baseURL: directory),
            firstGrant: firstGrant,
            secondGrant: secondGrant
        )
    }

    private func makePlan() throws -> PerryRuntimes.ExecutionPlan {
        let first = try ExecutableAction(
            id: "write-first",
            summary: "Write first report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: directory,
                command: .createUTF8File(path: "first.txt", contents: "first")
            ),
            postcondition: .fileContents("first")
        )
        let second = try ExecutableAction(
            id: "write-second",
            summary: "Write second report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: directory,
                command: .createUTF8File(path: "second.txt", contents: "second")
            ),
            postcondition: .fileContents("second")
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: "execution-journal",
            goal: "Write two reports",
            actions: [first, second],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func attempt(
        withID id: UUID,
        from attempt: WorkspaceActionJournal.Attempt
    ) throws -> WorkspaceActionJournal.Attempt {
        var fields = try jsonObject(try JSONEncoder().encode(attempt))
        fields["id"] = id.uuidString
        return try JSONDecoder().decode(
            WorkspaceActionJournal.Attempt.self,
            from: jsonData(fields)
        )
    }

    private func grant(
        withID id: UUID,
        from grant: ExecutionApprovalGrant
    ) throws -> ExecutionApprovalGrant {
        var fields = try jsonObject(try JSONEncoder().encode(grant))
        fields["id"] = id.uuidString
        return try JSONDecoder().decode(
            ExecutionApprovalGrant.self,
            from: jsonData(fields)
        )
    }

    private func assertValidationError(
        _ expected: WorkspaceExecutionJournalError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected \(expected)")
        } catch let error as WorkspaceExecutionJournalError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("expected \(expected), got \(error)")
        }
    }

    private func assertDecodeRejected(_ fields: [String: Any]) throws {
        let data = try jsonData(fields)
        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceExecutionJournal.self,
            from: data
        ))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct Fixture {
    let plan: PerryRuntimes.ExecutionPlan
    let registry: ExecutionApprovalRegistry
    let runtime: WorkspaceFileRuntime
    let firstGrant: ExecutionApprovalGrant
    let secondGrant: ExecutionApprovalGrant

    func receipt(for index: Int) async throws -> WorkspaceFileExecutionReceipt {
        try await runtime.execute(
            plan: plan,
            actionID: plan.actions[index].id,
            grantID: index == 0 ? firstGrant.id : secondGrant.id,
            registry: registry
        )
    }
}
