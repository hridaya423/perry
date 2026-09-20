import XCTest
@testable import Perry

@MainActor
final class SessionControllerTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let guideID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testGuideLifecycleRetainsItsIdentityUntilDismissal() throws {
        let controller = SessionController()
        let guide = GuideSessionState(
            id: guideID,
            goal: "Show me how to rename this file",
            startedAt: startedAt,
            appBundleID: "com.apple.finder"
        )

        try controller.wake(at: startedAt)
        try controller.startGuide(guide)
        XCTAssertEqual(controller.state, .guiding(guide))

        XCTAssertEqual(controller.requestDismissal(), .dismiss)
        XCTAssertEqual(controller.state, .idle)
    }

    func testFinishedGuideCannotBeRecordedAsStoppedDuringDismissal() throws {
        let controller = SessionController()
        let guide = GuideSessionState(
            id: guideID,
            goal: "Show me how to rename this file",
            startedAt: startedAt,
            appBundleID: "com.apple.finder"
        )

        try controller.wake(at: startedAt)
        try controller.startGuide(guide)
        try controller.finishGuide(summary: "Guide complete", outcome: .completed)
        XCTAssertEqual(
            controller.state,
            .reporting(ReportState(taskID: guideID, summary: "Guide complete"))
        )
        XCTAssertEqual(controller.requestDismissal(), .dismiss)
        XCTAssertEqual(controller.state, .idle)
    }

    func testGuideFinishDefaultsToStoppedOutcome() throws {
        let controller = SessionController()
        let guide = GuideSessionState(
            id: guideID,
            goal: "Show me how to rename this file",
            startedAt: startedAt,
            appBundleID: "com.apple.finder"
        )

        try controller.wake(at: startedAt)
        try controller.startGuide(guide)
        try controller.finishGuide(summary: "Stopped before the goal was verified")
        XCTAssertEqual(
            controller.state,
            .reporting(ReportState(taskID: guideID, summary: "Stopped before the goal was verified", outcome: .stopped))
        )
    }

    func testExecutionLifecycleMakesSubstatesMutuallyExclusive() throws {
        let controller = SessionController()
        let execution = makeExecution()

        try controller.wake(at: startedAt)
        try controller.startExecution(execution)
        try controller.setExecutionPhase(.running)
        try controller.setExecutionPhase(.paused)
        let approvalID = UUID()
        try controller.awaitApproval(approvalID)

        guard case .executing(let awaitingApproval) = controller.state else {
            return XCTFail("expected an executing session")
        }
        XCTAssertEqual(awaitingApproval.phase, .awaitingApproval)
        XCTAssertEqual(awaitingApproval.pendingApprovalID, approvalID)
        XCTAssertThrowsError(try controller.setExecutionPhase(.paused))

        XCTAssertThrowsError(try controller.setExecutionPhase(.running))
        XCTAssertTrue(controller.approvalIsCurrent(approvalID))
        try controller.acceptApproval(approvalID)
        XCTAssertFalse(controller.approvalIsCurrent(approvalID))
        try controller.setExecutionPhase(.verifying)
        _ = try controller.beginFinalization(outcome: .completed(stepsRun: 0))
        try controller.report(summary: "Renamed and verified the file")
        XCTAssertEqual(
            controller.state,
            .reporting(ReportState(taskID: taskID, summary: "Renamed and verified the file"))
        )
        let reported = AgentActivityStripState()
        reported.apply(sessionState: controller.state)
        XCTAssertEqual(reported.phase, .reporting)
        XCTAssertEqual(reported.title, "Task complete")
        XCTAssertEqual(reported.detail, "Renamed and verified the file")
    }

    func testExecutionStateCarriesActivityMetadataThroughPauseApprovalAndReport() throws {
        let controller = SessionController()
        let approvalID = UUID()
        let stepStartedAt = startedAt.addingTimeInterval(4)

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setPlannedStepCount(2)
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(
            id: "rename",
            summary: "Rename the file",
            tier: .yellow,
            reversible: true,
            index: 1,
            startedAt: stepStartedAt
        )
        try controller.setExecutionPhase(.paused)
        try controller.awaitApproval(approvalID, actionSummary: "Send the renamed file", tier: .orange)

        guard case .executing(let awaitingApproval) = controller.state else {
            return XCTFail("expected an executing session")
        }
        XCTAssertEqual(awaitingApproval.stepEvidence, [
            ExecutionStepEvidence(
                id: "rename",
                summary: "Rename the file",
                tier: .yellow,
                reversible: true,
                startedAt: stepStartedAt,
                index: 1
            )
        ])
        XCTAssertEqual(
            awaitingApproval.lifecycle,
            .awaitingApproval(ExecutionApproval(id: approvalID, actionSummary: "Send the renamed file", tier: .orange))
        )
        XCTAssertEqual(awaitingApproval.progress, 0.5)

        try controller.acceptApproval(approvalID)
        _ = try controller.beginFinalization(outcome: .completed(stepsRun: 1))
        try controller.report(summary: "Renamed and verified the file")
        XCTAssertEqual(
            controller.state,
            .reporting(ReportState(taskID: taskID, summary: "Renamed and verified the file"))
        )
    }

    func testFailureRetainsForegroundRetryIdentityInTypedState() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.fail(
            SessionFailure(taskID: taskID, goal: "Rename the selected file", message: "Cua target closed")
        )

        XCTAssertEqual(
            controller.state,
            .failed(SessionFailure(taskID: taskID, goal: "Rename the selected file", message: "Cua target closed"))
        )
        let failed = AgentActivityStripState()
        failed.apply(sessionState: controller.state)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertTrue(failed.retryIsAvailable)
        XCTAssertEqual(failed.detail, "Cua target closed")
    }

    func testDismissalInvalidatesApprovalBeforeTheCardCanAppear() throws {
        let controller = SessionController()
        let approvalID = UUID()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.awaitApproval(approvalID)

        XCTAssertTrue(controller.approvalIsCurrent(approvalID))
        XCTAssertEqual(controller.requestDismissal(), .stopExecution)
        XCTAssertFalse(controller.approvalIsCurrent(approvalID))
        guard case .executing(let execution) = controller.state else {
            return XCTFail("expected an executing session")
        }
        XCTAssertEqual(execution.phase, .stopping)
        XCTAssertNil(execution.pendingApprovalID)
    }

    func testIllegalOperationsPreserveTheCurrentState() throws {
        let controller = SessionController()
        let guide = GuideSessionState(
            id: guideID,
            goal: "Show the full path",
            startedAt: startedAt,
            appBundleID: nil
        )

        XCTAssertThrowsError(try controller.startGuide(guide))
        XCTAssertEqual(controller.state, .idle)

        try controller.wake(at: startedAt)
        let invoking = controller.state
        XCTAssertThrowsError(try controller.report(summary: "Impossible"))
        XCTAssertEqual(controller.state, invoking)

        try controller.startExecution(makeExecution())
        let starting = controller.state
        XCTAssertThrowsError(try controller.report(summary: "Not finished"))
        XCTAssertEqual(controller.state, starting)
    }

    func testFailureCarriesAConcreteReasonAndCanBeDismissed() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.fail(SessionFailure(message: "Cua target closed"))
        XCTAssertEqual(controller.state, .failed(SessionFailure(message: "Cua target closed")))

        XCTAssertEqual(controller.requestDismissal(), .dismiss)
        XCTAssertEqual(controller.state, .idle)
    }

    func testExecutionDismissalRequestsTransactionalStopAndPreservesEvidence() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.setPlannedStepCount(1)
        try controller.recordExecutionStep(id: "rename", summary: "Rename the file")
        try controller.recordVerification(stepID: "rename", verified: false, warning: "Window title did not change")

        XCTAssertEqual(controller.requestDismissal(), .stopExecution)
        guard case .executing(let stopping) = controller.state else {
            return XCTFail("expected a stopping execution")
        }
        XCTAssertEqual(stopping.phase, .stopping)
        XCTAssertEqual(stopping.steps, ["Rename the file"])
        XCTAssertEqual(stopping.verificationResults, [false])
        XCTAssertEqual(stopping.warnings, ["Window title did not change"])
        XCTAssertEqual(controller.requestDismissal(), .stopExecution)
        XCTAssertThrowsError(try controller.completeDismissal())
        XCTAssertEqual(controller.state, .executing(stopping))
    }

    func testReportingRequiresFinalization() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.setExecutionPhase(.verifying)
        let verifying = controller.state

        XCTAssertThrowsError(try controller.report(summary: "Too early"))
        XCTAssertEqual(controller.state, verifying)
        _ = try controller.beginFinalization(outcome: .completed(stepsRun: 0))
        try controller.report(summary: "Verified")
        try controller.completeDismissal()
        XCTAssertEqual(controller.state, .idle)
    }

    func testGuideEvidenceDeduplicatesPresentedAndActionableSteps() throws {
        let controller = SessionController()
        let stepID = UUID()

        try controller.wake(at: startedAt)
        try controller.startGuide(
            GuideSessionState(id: guideID, goal: "Rename a file", startedAt: startedAt, appBundleID: "com.apple.finder")
        )
        try controller.recordGuideStep(id: stepID, instruction: "Select Rename", actionable: true)
        try controller.recordGuideStep(id: stepID, instruction: "Select Rename", actionable: true)

        guard case .guiding(let guide) = controller.state else {
            return XCTFail("expected a guiding session")
        }
        XCTAssertEqual(guide.steps, ["Select Rename"])
        XCTAssertEqual(guide.presentedStepIDs, [stepID])
        XCTAssertEqual(guide.actionableStepIDs, [stepID])
    }

    func testReplacingGuidePlanDoesNotClaimPresentedEvidence() throws {
        let controller = SessionController()
        let firstID = UUID()
        let secondID = UUID()

        try controller.wake(at: startedAt)
        try controller.startGuide(
            GuideSessionState(id: guideID, goal: "Rename a file", startedAt: startedAt, appBundleID: "com.apple.finder")
        )
        try controller.recordGuideStep(id: UUID(), instruction: "Old step", actionable: true)
        try controller.replaceGuidePlan(steps: [
            (firstID, "Open the menu", true),
            (secondID, "Read the result", false),
        ])

        guard case .guiding(let guide) = controller.state else {
            return XCTFail("expected a guiding session")
        }
        XCTAssertEqual(guide.plannedSteps, ["Open the menu", "Read the result"])
        XCTAssertEqual(guide.steps, ["Old step"])
        XCTAssertEqual(guide.presentedStepIDs.count, 1)
        XCTAssertEqual(guide.actionableStepIDs.count, 1)
    }

    func testExecutionEvidenceAndFinalizationRemainInOnePayload() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setPlannedStepCount(2)
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(id: "rename", summary: "Rename the file")
        try controller.recordExecutionStep(id: "rename", summary: "Rename the file")
        try controller.recordVerification(
            stepID: "rename",
            verified: false,
            warning: "Rename the file: title did not change"
        )
        let finalized = try controller.beginFinalization(outcome: .completed(stepsRun: 1)).execution

        XCTAssertEqual(finalized.totalSteps, 2)
        XCTAssertEqual(finalized.steps, ["Rename the file"])
        XCTAssertEqual(finalized.verificationResults, [false])
        XCTAssertEqual(finalized.warnings, ["Rename the file: title did not change"])
        XCTAssertTrue(finalized.isFinalized)
        XCTAssertThrowsError(try controller.beginFinalization(outcome: .completed(stepsRun: 0)))
        XCTAssertThrowsError(try controller.setExecutionPhase(.running))
        XCTAssertThrowsError(try controller.setPlannedStepCount(3))
        XCTAssertThrowsError(try controller.recordExecutionStep(id: "another", summary: "Another step"))
        XCTAssertThrowsError(try controller.recordVerification(stepID: "rename", verified: true))
        XCTAssertEqual(controller.state, .executing(finalized))
    }

    func testExecutionEvidencePreservesRepeatedSummariesWithDistinctIDs() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(id: "rename-first", summary: "Rename the file")
        try controller.recordExecutionStep(id: "rename-second", summary: "Rename the file")
        let finalized = try controller.beginFinalization(outcome: .completed(stepsRun: 2)).execution

        XCTAssertEqual(finalized.steps, ["Rename the file", "Rename the file"])
        XCTAssertEqual(finalized.stepEvidence.map(\.id), ["rename-first", "rename-second"])
    }

    func testExecutionEvidenceRejectsConflictsAndUnknownVerification() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(id: "rename", summary: "Rename the file")
        let recorded = controller.state

        XCTAssertThrowsError(try controller.recordExecutionStep(id: "rename", summary: "Move the file"))
        XCTAssertThrowsError(try controller.recordVerification(stepID: "unknown", verified: true))
        XCTAssertEqual(controller.state, recorded)
    }

    func testStartExecutionRejectsDirtyOrPreFinalizedPayload() throws {
        let controller = SessionController()
        let invalid = makeExecution(lifecycle: .finalizing(.verifying))

        try controller.wake(at: startedAt)
        let invoking = controller.state
        XCTAssertThrowsError(try controller.startExecution(invalid))
        XCTAssertEqual(controller.state, invoking)
    }

    func testGuideStepsUseIDsRatherThanInstructionTextForIdentity() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startGuide(
            GuideSessionState(id: guideID, goal: "Rename two files", startedAt: startedAt, appBundleID: "com.apple.finder")
        )
        try controller.recordGuideStep(id: UUID(), instruction: "Select Rename", actionable: true)
        try controller.recordGuideStep(id: UUID(), instruction: "Select Rename", actionable: true)

        guard case .guiding(let guide) = controller.state else {
            return XCTFail("expected a guiding session")
        }
        XCTAssertEqual(guide.steps, ["Select Rename", "Select Rename"])
        XCTAssertEqual(guide.presentedStepIDs.count, 2)
        XCTAssertEqual(guide.actionableStepIDs.count, 2)
    }

    func testNegativePlannedStepCountPreservesExecution() throws {
        let controller = SessionController()

        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        let starting = controller.state
        XCTAssertThrowsError(try controller.setPlannedStepCount(-1))
        XCTAssertEqual(controller.state, starting)
    }

    func testFinalizationRetiresApprovalAndRejectsLateExecutionUpdates() throws {
        let controller = SessionController()
        let approvalID = UUID()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(id: "rename", summary: "Rename the file")
        try controller.awaitApproval(approvalID)
        XCTAssertTrue(controller.approvalIsCurrent(approvalID))

        let finalized = try controller.beginFinalization(outcome: .blocked(reason: "user stopped the task")).execution
        let frozenState = controller.state
        XCTAssertEqual(finalized.lifecycle, .finalizing(.stopping))
        XCTAssertNil(finalized.pendingApprovalID)
        XCTAssertFalse(controller.approvalIsCurrent(approvalID))
        XCTAssertThrowsError(try controller.awaitApproval(UUID()))
        XCTAssertThrowsError(try controller.setExecutionPhase(.running))
        XCTAssertThrowsError(try controller.recordExecutionStep(id: "late", summary: "Late action"))
        XCTAssertThrowsError(try controller.recordVerification(stepID: "rename", verified: true))
        XCTAssertThrowsError(try controller.setPlannedStepCount(2))
        XCTAssertThrowsError(try controller.beginFinalization(outcome: .blocked(reason: "user stopped the task")))
        XCTAssertEqual(controller.state, frozenState)

        try controller.report(summary: "Stopped before approval")
        XCTAssertEqual(controller.state, .reporting(ReportState(taskID: taskID, summary: "Stopped before approval")))
    }

    func testStartupFailureCanFinalizeBeforeTheRuntimeStarts() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())

        let finalized = try controller.beginFinalization(outcome: .blocked(reason: "user stopped the task")).execution
        XCTAssertEqual(finalized.lifecycle, .finalizing(.stopping))
        XCTAssertTrue(finalized.steps.isEmpty)
        try controller.fail(SessionFailure(message: "Runtime unavailable"))
        XCTAssertEqual(controller.state, .failed(SessionFailure(message: "Runtime unavailable")))
    }

    func testAcceptedApprovalResumesItsTaskAndCannotBeReused() throws {
        let controller = SessionController()
        let approvalID = UUID()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.awaitApproval(approvalID)
        let waiting = controller.state

        XCTAssertThrowsError(try controller.setExecutionPhase(.running))
        XCTAssertThrowsError(try controller.acceptApproval(UUID()))
        XCTAssertEqual(controller.state, waiting)
        try controller.acceptApproval(approvalID)
        guard case .executing(let running) = controller.state else {
            return XCTFail("expected a running execution")
        }
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertNil(running.pendingApprovalID)
        XCTAssertThrowsError(try controller.acceptApproval(approvalID))
        XCTAssertEqual(controller.state, .executing(running))
        try controller.setExecutionPhase(.verifying)
    }

    func testLateStepsCannotRevivePausedOrStoppingExecution() throws {
        for phase in [ExecutionPhase.paused, .stopping] {
            let controller = SessionController()
            try controller.wake(at: startedAt)
            try controller.startExecution(makeExecution())
            try controller.setExecutionPhase(.running)
            try controller.recordExecutionStep(id: "in-flight", summary: "Existing action")
            try controller.setExecutionPhase(phase)
            let before = controller.state

            XCTAssertThrowsError(try controller.recordExecutionStep(id: "late", summary: "Late action"))
            XCTAssertEqual(controller.state, before)
            try controller.recordVerification(stepID: "in-flight", verified: true)
            guard case .executing(let execution) = controller.state else {
                return XCTFail("expected the execution to retain its phase")
            }
            XCTAssertEqual(execution.phase, phase)
            XCTAssertEqual(execution.steps, ["Existing action"])
            XCTAssertEqual(execution.verificationResults, [true])
        }
    }

    func testExecutionCannotRecordStepsBeforeStarting() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        let starting = controller.state
        XCTAssertThrowsError(try controller.recordExecutionStep(id: "early", summary: "Early action"))
        XCTAssertEqual(controller.state, starting)
    }

    func testStopWinsOverLateCompletionWithoutErasingActionEvidence() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.recordExecutionStep(id: "rename", summary: "Renamed the file")
        try controller.recordVerification(stepID: "rename", verified: true)
        XCTAssertEqual(controller.requestDismissal(), .stopExecution)

        let finalization = try controller.beginFinalization(outcome: .completed(stepsRun: 1))
        XCTAssertEqual(finalization.execution.lifecycle, .finalizing(.stopping))
        XCTAssertEqual(finalization.outcome, .blocked(reason: "stop was requested while finishing; completed actions were not undone"))
        XCTAssertEqual(finalization.execution.steps, ["Renamed the file"])
        XCTAssertEqual(finalization.execution.verificationResults, [true])
        XCTAssertEqual(controller.state, .executing(finalization.execution))
    }

    func testCompletionCannotSucceedBeforeStartingOrWhileApprovalIsPending() throws {
        for awaitingApproval in [false, true] {
            let controller = SessionController()
            try controller.wake(at: startedAt)
            try controller.startExecution(makeExecution())
            if awaitingApproval {
                try controller.setExecutionPhase(.running)
                try controller.awaitApproval(UUID())
            }

            let finalization = try controller.beginFinalization(outcome: .completed(stepsRun: 0))
            XCTAssertEqual(finalization.execution.lifecycle, .finalizing(.stopping))
            XCTAssertNil(finalization.execution.pendingApprovalID)
            XCTAssertEqual(finalization.outcome, .failed(
                stepSummary: "completion", reason: "completion arrived before execution was allowed to finish"
            ))
        }
    }

    func testDismissalAfterFinalizationDoesNotRewriteTheCommittedOutcome() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        try controller.setExecutionPhase(.verifying)
        let finalization = try controller.beginFinalization(outcome: .completed(stepsRun: 0))

        XCTAssertEqual(controller.requestDismissal(), .stopExecution)
        guard case .executing(let stopped) = controller.state else {
            return XCTFail("expected a finalizing execution")
        }
        XCTAssertEqual(stopped.lifecycle, .finalizing(.stopping))
        XCTAssertEqual(finalization.outcome, .completed(stepsRun: 0))
        XCTAssertEqual(finalization.execution.lifecycle, .finalizing(.verifying))
    }

    func testStaleInvocationCannotStartExecutionAfterNewAttempt() throws {
        let controller = SessionController()
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        try controller.wake(at: startedAt, attemptID: firstAttemptID)
        try controller.cancelInvocation(firstAttemptID)
        try controller.wake(at: startedAt, attemptID: secondAttemptID)

        XCTAssertThrowsError(
            try controller.startExecution(makeExecution(), attemptID: firstAttemptID)
        )
        XCTAssertEqual(
            controller.state,
            .invoking(InvocationState(id: secondAttemptID, startedAt: startedAt))
        )
    }

    func testActivityStopRecordsTypedIntentBeforeCancellation() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)

        XCTAssertEqual(controller.requestStop(), .stopExecution)
        guard case .executing(let execution) = controller.state else {
            return XCTFail("expected a stopping execution")
        }
        XCTAssertEqual(execution.stopIntent, .requested)
        XCTAssertEqual(execution.lifecycle, .stopping)
    }

    func testCommittedFinalizationIgnoresStopDuringPersistence() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        _ = try controller.beginFinalization(outcome: .completed(stepsRun: 0))
        let activity = AgentActivityStripState()
        activity.apply(sessionState: controller.state)
        XCTAssertTrue(activity.stopIsAvailable)
        let committed = try controller.commitFinalization(taskID: taskID, outcome: .completed(stepsRun: 0))

        activity.apply(sessionState: controller.state)
        XCTAssertFalse(activity.stopIsAvailable)
        XCTAssertEqual(controller.requestStop(), .dismiss)
        XCTAssertEqual(controller.state, .executing(committed.execution))
        try controller.report(summary: "Finished")
        XCTAssertEqual(controller.state, .reporting(ReportState(taskID: taskID, summary: "Finished")))
    }

    func testCommittedFailedFinalizationCannotBeReportedAsCompleted() throws {
        let controller = SessionController()
        try controller.wake(at: startedAt)
        try controller.startExecution(makeExecution())
        try controller.setExecutionPhase(.running)
        _ = try controller.beginFinalization(
            outcome: .failed(stepSummary: "Typed action", reason: "fixture failure")
        )
        let committed = try controller.commitFinalization(
            taskID: taskID,
            outcome: .failed(stepSummary: "Typed action", reason: "fixture failure")
        )

        XCTAssertEqual(
            committed.outcome,
            .failed(stepSummary: "Typed action", reason: "fixture failure")
        )
        let activity = AgentActivityStripState()
        activity.apply(sessionState: controller.state)
        XCTAssertEqual(activity.phase, .failed)
        XCTAssertFalse(activity.stopIsAvailable)
        XCTAssertThrowsError(try controller.report(summary: "failed"))
        XCTAssertEqual(controller.state, .executing(committed.execution))
    }

    private func makeExecution(lifecycle: ExecutionLifecycle = .starting) -> ExecutionSessionState {
        ExecutionSessionState(
            taskID: taskID,
            goal: "Rename the selected file",
            startedAt: startedAt,
            appBundleID: "com.apple.finder",
            workspace: URL(fileURLWithPath: "/tmp/perry-session-controller-tests"),
            lifecycle: lifecycle
        )
    }
}
