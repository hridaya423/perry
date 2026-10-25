import XCTest
@testable import Perry

final class CommandRouterTests: XCTestCase {
    private let taskID = UUID()

    private func executing(_ lifecycle: ExecutionLifecycle) -> SessionState {
        .executing(ExecutionSessionState(
            taskID: taskID, goal: "rename files", startedAt: Date(), appBundleID: nil,
            workspace: URL(fileURLWithPath: "/tmp/perry-router"), lifecycle: lifecycle
        ))
    }

    private let asking = SessionState.asking(AskSessionState(id: UUID(), startedAt: Date(), question: "first"))

    func testRoutesTodaysCommands() {
        let moved = "That task already moved on. Hold the shortcut again to steer the current one."
        let busy = "A task started while you were speaking. Hold the shortcut again to steer it."
        let locked = "Perry can’t take direction right now. Use the task controls, or say “stop”."
        expect(nil, .idle, nil, .showPanel)
        expect("", .idle, nil, .showPanel)
        expect("what can you help me with", .idle, nil, .ask("what can you help me with"))
        expect("how do I export a PDF", .idle, nil, .guide("export a PDF"))
        expect("help me write a poem", .idle, nil, .guide("write a poem"))
        expect("show me everything for invoices", .idle, nil, .showEverything("for invoices"))
        expect("take over and rename these", .idle, nil, .doTask("and rename these"))
        expect("do this for me: tidy Downloads", .idle, nil, .doTask("tidy Downloads"))
        expect("cancel", .idle, nil, .dismiss)
        expect("show me how to share", asking, nil, .askInGuide("show me how to share", full: false))
        expect("show me everything", asking, nil, .askInGuide("show me everything", full: true))
        expect("take over", asking, nil, .ask("take over"))
        expect("and the second one?", asking, nil, .ask("and the second one?"))
        expect("stop", asking, nil, .dismiss)
        expect("make it blue", executing(.running), nil, .status(busy))
        expect("make it blue", executing(.running), taskID, .steer("make it blue"))
        expect("make it blue", executing(.paused), taskID, .steer("make it blue"))
        expect("stop", executing(.running), taskID, .dismiss)
        expect("make it blue", executing(.verifying), taskID, .status(locked))
        expect("make it blue", executing(.running), UUID(), .status(moved))
        expect("make it blue", .idle, taskID, .status(moved))
    }

    private func expect(_ text: String?, _ state: SessionState, _ scope: UUID?, _ route: CommandRouter.Route, line: UInt = #line) {
        XCTAssertEqual(CommandRouter.decide(text, state: state, voiceTaskScope: scope), route, line: line)
    }
}
