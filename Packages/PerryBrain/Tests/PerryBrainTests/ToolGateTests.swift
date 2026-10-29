@testable import PerryBrain
import XCTest

final class ToolGateTests: XCTestCase {
    private func call(_ name: String, id: String = "c1") -> ToolCall {
        ToolCall(id: id, name: name, arguments: .object([:]))
    }

    private func spec(_ name: String) -> ToolSpec {
        ToolSpec(name: name, description: "", inputSchema: .object([:]))
    }

    func testTalkCanActWhenAsked() {
        XCTAssertNil(ToolGate.check(call("ui.click"), on: .talk))
        XCTAssertNil(ToolGate.check(call("app.launch"), on: .talk))
    }

    func testUIClickRejectedOnGuide() {
        let rejection = ToolGate.check(call("ui.click", id: "c9"), on: .guide)
        XCTAssertEqual(rejection, ToolRejection(callID: "c9", toolName: "ui.click", surface: .guide))
    }

    func testRingAllowedOnTalk() {
        XCTAssertTrue(ToolGate.allows("ring", on: .talk))
        XCTAssertNil(ToolGate.check(call("ring"), on: .talk))
    }

    func testObserveToolAllowedOnTalk() {
        XCTAssertTrue(ToolGate.allows("screen.observe", on: .talk))
    }

    func testUIClickAllowedOnAgent() {
        XCTAssertTrue(ToolGate.allows("ui.click", on: .agent))
        XCTAssertNil(ToolGate.check(call("ui.click"), on: .agent))
    }

    func testFilterStripsActToolsForGuide() {
        let specs = [spec("screen.observe"), spec("ui.click"), spec("ring"), spec("files.delete")]
        XCTAssertEqual(ToolGate.filter(specs, for: .guide).map(\.name), ["screen.observe", "ring"])
        XCTAssertEqual(ToolGate.filter(specs, for: .talk).count, 4)
        XCTAssertEqual(ToolGate.filter(specs, for: .agent).count, 4)
    }

    func testTalkIsOfferedEveryAgentTool() {
        let agentOnly = ToolSpec(name: "app.launch", description: "", inputSchema: .object([:]), surfaces: [.agent])
        XCTAssertTrue(agentOnly.isOffered(on: .talk))
        XCTAssertFalse(agentOnly.isOffered(on: .guide))
        XCTAssertFalse(agentOnly.isOffered(on: .suggestions))
    }

    func testFilesDeleteRejectedOnGuide() {
        let rejection = ToolGate.check(call("files.delete", id: "c7"), on: .guide)
        XCTAssertEqual(rejection, ToolRejection(callID: "c7", toolName: "files.delete", surface: .guide))
    }
}
