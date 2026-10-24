import XCTest
@testable import Perry

final class SoundCueTests: XCTestCase {
    private let task = UUID()

    private func executing(_ lifecycle: ExecutionLifecycle) -> SessionState {
        .executing(ExecutionSessionState(
            taskID: task,
            goal: "rename the report",
            startedAt: Date(timeIntervalSince1970: 0),
            appBundleID: nil,
            workspace: URL(fileURLWithPath: "/tmp"),
            lifecycle: lifecycle
        ))
    }

    func testCompletionChimesOnceAndAUserStopStaysSilent() {
        let done = SessionState.reporting(ReportState(taskID: task, summary: "Renamed"))
        XCTAssertEqual(SoundPlayer.cue(from: executing(.running), to: done), .done)
        XCTAssertNil(SoundPlayer.cue(from: done, to: done))
        let stopped = SessionState.reporting(ReportState(taskID: task, summary: "Stopped", outcome: .stopped))
        XCTAssertNil(SoundPlayer.cue(from: executing(.stopping), to: stopped))
    }

    func testFailureChimesOnce() {
        let failure = SessionState.failed(SessionFailure(taskID: task, message: "Couldn’t reach Finder"))
        XCTAssertEqual(SoundPlayer.cue(from: executing(.running), to: failure), .fail)
        XCTAssertNil(SoundPlayer.cue(from: failure, to: failure))
    }

    func testOnlyEnteringApprovalAsksForAttention() {
        let approval = executing(.awaitingApproval(ExecutionApproval(id: UUID(), actionSummary: "Send the email")))
        XCTAssertEqual(SoundPlayer.cue(from: executing(.running), to: approval), .receive)
        XCTAssertNil(SoundPlayer.cue(from: approval, to: approval))
        XCTAssertNil(SoundPlayer.cue(from: executing(.starting), to: executing(.running)))
    }
}
