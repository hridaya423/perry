#if DEBUG
import Foundation

extension ForegroundTaskController {
    func debugShowActivityFixture() {
        let fixtureStart = Date()
        activityStripState.reset()
        activityStripState.isExpanded = true
        activityStripState.phase = .working
        activityStripState.title = "UI test fixture"
        activityStripState.detail = "Long task fixture · running"
        activityStripState.progress = 0.42
        activityStripState.tier = .yellow
        activityStripState.startedAt = fixtureStart
        activityStripState.steps = [
            AgentActivityStep(
                id: "fixture-inspect",
                summary: "Inspect the active window and collect a bounded snapshot",
                tier: .green,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-18),
                verification: "Checked: fixture snapshot ready"
            ),
            AgentActivityStep(
                id: "fixture-plan",
                summary: "Plan the next safe action from the current task state",
                tier: .yellow,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-12),
                verification: nil
            ),
            AgentActivityStep(
                id: "fixture-prepare",
                summary: "Prepare the staged result for review",
                tier: .orange,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-6),
                verification: nil
            ),
            AgentActivityStep(
                id: "fixture-report",
                summary: "Report the verified result and keep the task visible",
                tier: .yellow,
                reversible: true,
                timestamp: fixtureStart,
                verification: nil
            )
        ]
        NotchPresentation.shared.present(id: activityStripID, priority: .activity, content: AgentActivityStripView(
            state: activityStripState,
            onPause: { [weak self] in
                guard let self, self.activityStripState.phase == .working else { return }
                self.activityStripState.phase = .paused
                self.activityStripState.detail = "Long task fixture · paused"
            },
            onResume: { [weak self] in
                guard let self, self.activityStripState.phase == .paused else { return }
                self.activityStripState.phase = .working
                self.activityStripState.detail = "Long task fixture · running"
            },
            onStop: { [weak self] in
                guard let self else { return }
                self.activityStripState.phase = .failed
                self.activityStripState.detail = "Stopped by the UI test fixture; retry is available"
                self.activityStripState.canRetry = true
            },
            onRetry: { [weak self] in
                guard let self, self.activityStripState.retryIsAvailable else { return }
                self.activityStripState.phase = .working
                self.activityStripState.detail = "Long task fixture · running after retry"
                self.activityStripState.progress = 0.42
                self.activityStripState.canRetry = false
            },
            onSteer: { [weak self] instruction in
                guard let self, self.activityStripState.steeringIsAvailable else { return }
                self.activityStripState.detail = "Steering: \(instruction)"
            },
            onTakeOver: {}
        ), reveal: activityStripState.isExpanded)
    }
}
#endif
