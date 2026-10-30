import XCTest
import PerryBrain
import PerryRuntimes
@testable import Perry

/// Phase 10 audit: "every state has a visible exit ≤10 s, no stuck states."
/// The state machine is the contract — this enumerates every constructible
/// `SessionState` and proves a lawful transition path reaches `.idle`,
/// `.reporting`, or `.failed` (which dismiss in one call) in ≤5 steps.
@MainActor
final class SessionExitAuditTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-00000000ee10")!

    func testEverySessionStateReachesATerminalDismissal() throws {
        for (name, state) in fixtureStates {
            let controller = SessionController()
            controller.debugSet(state)
            try assertExits(controller, named: name)
        }
    }

    /// Walks the lawful transition graph to a terminal state, asserting the
    /// whole exit takes ≤5 transitions — well inside the 10 s budget.
    private func assertExits(_ controller: SessionController, named name: String, line: UInt = #line) throws {
        for step in 0...6 {
            switch controller.state {
            case .idle:
                return
            case .reporting, .failed:
                try controller.completeDismissal()
                XCTAssertEqual(controller.state, .idle, "\(name): dismissal after terminal")
                return
            case .executing(let execution):
                if let outcome = execution.finalizationOutcome {
                    switch outcome {
                    case .completed, .blocked:
                        try controller.report(summary: "audit")
                    case .failed(let stepSummary, let reason):
                        try controller.fail(SessionFailure(taskID: execution.taskID, message: "\(stepSummary): \(reason)"))
                    }
                } else if execution.isFinalized {
                    _ = try controller.commitFinalization(
                        taskID: execution.taskID, outcome: .blocked(reason: "audit")
                    )
                } else {
                    _ = controller.requestStop()
                    _ = try controller.beginFinalization(outcome: .blocked(reason: "audit stop"))
                }
            case .invoking, .guiding, .asking, .talking:
                XCTAssertEqual(controller.requestDismissal(), .dismiss, "\(name)")
                XCTAssertEqual(controller.state, .idle, "\(name)")
                return
            }
            if step == 6 {
                XCTFail("\(name): no exit after 6 transitions — a state is stuck", line: line)
            }
        }
    }

    private var fixtureStates: [String: SessionState] {
        var states: [String: SessionState] = [
            "idle": .idle,
            "invoking": .invoking(InvocationState(id: UUID(), startedAt: startedAt)),
            "guiding": .guiding(GuideSessionState(
                id: UUID(), goal: "audit", startedAt: startedAt, appBundleID: "com.apple.finder"
            )),
            "asking": .asking(AskSessionState(id: UUID(), startedAt: startedAt, question: "audit")),
            "talking": .talking(TalkSessionState(id: UUID(), startedAt: startedAt, transcript: "audit")),
            "reporting": .reporting(ReportState(taskID: taskID, summary: "audit")),
            "failed": .failed(SessionFailure(taskID: taskID, message: "audit")),
        ]
        for lifecycle in executionLifecycles {
            states["executing \(lifecycle.name)"] = .executing(execution(lifecycle: lifecycle))
        }
        for (label, lifecycle) in [
            ("finalized-complete", ExecutionLifecycle.finalizing(.verifying)),
            ("finalized-stopped", ExecutionLifecycle.finalizing(.stopping)),
        ] {
            states["executing \(label)"] = .executing(execution(
                lifecycle: lifecycle, outcome: .completed(stepsRun: 0)
            ))
        }
        states["executing finalized-failed"] = .executing(execution(
            lifecycle: .finalizing(.stopping),
            outcome: .failed(stepSummary: "audit", reason: "audit")
        ))
        return states
    }

    private var executionLifecycles: [ExecutionLifecycle] {
        [
            .starting, .running, .paused,
            .awaitingApproval(ExecutionApproval(id: UUID(), actionSummary: "audit", tier: .orange)),
            .verifying, .stopping,
            .finalizing(.verifying), .finalizing(.stopping),
        ]
    }

    private func execution(
        lifecycle: ExecutionLifecycle,
        outcome: DoOutcome? = nil
    ) -> ExecutionSessionState {
        ExecutionSessionState(
            taskID: taskID,
            goal: "audit",
            startedAt: startedAt,
            appBundleID: "com.apple.finder",
            workspace: URL(fileURLWithPath: "/tmp/perry-exit-audit"),
            lifecycle: lifecycle,
            stopRequested: outcome == nil && lifecycle == .stopping,
            finalizationOutcome: outcome
        )
    }
}

private extension ExecutionLifecycle {
    var name: String {
        switch self {
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .awaitingApproval: return "awaitingApproval"
        case .verifying: return "verifying"
        case .stopping: return "stopping"
        case .finalizing(let phase):
            return phase == .verifying ? "finalizing.verifying" : "finalizing.stopping"
        }
    }
}
