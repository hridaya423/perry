import Foundation
import XCTest
@testable import PerryBrain

final class AcpAgentProviderTests: XCTestCase {
    private let options: JSONValue = .array([
        .object(["optionId": .string("allow-once"), "kind": .string("allow_once")]),
        .object(["optionId": .string("reject-once"), "kind": .string("reject_once")]),
    ])

    func testPermissionIsGrantedOnlyForThisTurnsPerryTools() {
        let perry: JSONValue = .object(["toolCall": .object(["title": .string("perry-probe_echo: probe_echo")]), "options": options])
        let shell: JSONValue = .object(["toolCall": .object(["title": .string("Run rm -rf ~/Documents")]), "options": options])
        let otherPerryTool: JSONValue = .object(["toolCall": .object(["title": .string("perry: files_trash")]), "options": options])
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(perry, perryTools: ["probe_echo"])["outcome"]?["optionId"]?.stringValue, "allow-once")
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(shell, perryTools: ["probe_echo"])["outcome"]?["optionId"]?.stringValue, "reject-once")
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(otherPerryTool, perryTools: ["probe_echo"])["outcome"]?["optionId"]?.stringValue, "reject-once")
        let disguised: JSONValue = .object(["toolCall": .object(["title": .string("Run shell: touch /tmp/perry_probe_echo"), "kind": .string("execute")]), "options": options])
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(disguised, perryTools: ["probe_echo"])["outcome"]?["optionId"]?.stringValue, "reject-once")
        let worded: JSONValue = .object(["toolCall": .object(["title": .string("echo perry probe_echo; rm -rf ~"), "kind": .string("execute")]), "options": options])
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(worded, perryTools: ["probe_echo"])["outcome"]?["optionId"]?.stringValue, "reject-once")
        let substring: JSONValue = .object(["toolCall": .object(["title": .string("Read /tmp/perry_screen_observe")]), "options": options])
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(substring, perryTools: ["screen_observe"])["outcome"]?["optionId"]?.stringValue, "reject-once")
        let noReject: JSONValue = .object(["toolCall": .object(["title": .string("Edit file")]), "options": .array([])])
        XCTAssertEqual(AcpAgentProvider.permissionOutcome(noReject, perryTools: [])["outcome"]?["outcome"]?.stringValue, "cancelled")
    }

    func testPrefersAReadOnlyModeWhenTheAgentOffersOne() {
        let modes = { (ids: [String]) -> JSONValue in
            .object(["modes": .object(["availableModes": .array(ids.map { .object(["id": .string($0)]) })])])
        }
        XCTAssertEqual(AcpAgentProvider.readOnlyMode(modes(["agent", "plan", "ask"])), "ask")
        XCTAssertEqual(AcpAgentProvider.readOnlyMode(modes(["agent", "plan"])), "plan")
        XCTAssertNil(AcpAgentProvider.readOnlyMode(modes(["agent"])))
        XCTAssertNil(AcpAgentProvider.readOnlyMode(.object([:])))
    }

    func testPromptCarriesPerrysInstructionsFirst() {
        let blocks = AcpAgentProvider.prompt([.user([.text("hi")])], system: "Be brief.", images: true)
        XCTAssertEqual(blocks.first?["text"]?.stringValue, "Instructions from Perry, the app you are working inside:\nBe brief.")
        XCTAssertEqual(blocks.last?["text"]?.stringValue, "hi")
    }

    func testPromptDropsImagesTheAgentCannotRead() {
        let messages: [ModelMessage] = [.user([.text("Look"), .image(data: Data([1]), mimeType: "image/png")])]
        XCTAssertEqual(AcpAgentProvider.prompt(messages, images: false).count, 1)
        XCTAssertEqual(AcpAgentProvider.prompt(messages, images: true).last?["mimeType"]?.stringValue, "image/png")
    }

    func testRunsATurnInReadOnlyModeAndRejectsTheAgentsOwnTools() async throws {
        let agent = try script(#"""
        #!/usr/bin/env python3
        import json, sys
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        mode = "agent"
        for line in sys.stdin:
            m = json.loads(line)
            assert m.get("jsonrpc") == "2.0"
            meth, i = m.get("method"), m.get("id")
            if meth == "initialize":
                send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": True}}}})
            elif meth == "session/new":
                send({"jsonrpc": "2.0", "id": i, "result": {"sessionId": "s1", "modes": {"availableModes": [{"id": "agent"}, {"id": "ask"}]}}})
            elif meth == "session/set_mode":
                mode = m["params"]["modeId"]
                send({"jsonrpc": "2.0", "id": i, "result": {}})
            elif meth == "session/prompt":
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": "s1", "toolCall": {"title": "Run shell: ls ~"}, "options": [{"optionId": "yes", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]}})
                answer = json.loads(sys.stdin.readline())
                chosen = answer["result"]["outcome"]["optionId"]
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": mode + ":" + chosen}}}})
                send({"jsonrpc": "2.0", "id": i, "result": {"stopReason": "end_turn"}})
                break
        """#)
        let provider = AcpAgentProvider(agent: AcpAgent(id: "fake", name: "Fake", command: agent.path, arguments: []), executable: agent, helper: nil, scopes: nil)
        var text = ""
        var done = false
        for try await event in provider.stream(ModelRequest(messages: [.user([.text("hi")])])) {
            if case .textDelta(let delta) = event { text += delta }
            if case .done(.endTurn) = event { done = true }
        }
        XCTAssertEqual(text, "ask:no")
        XCTAssertTrue(done)
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-acp-\(UUID().uuidString)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
