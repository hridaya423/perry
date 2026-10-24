import Foundation
import XCTest
@testable import PerryBrain

final class AcpAgentProviderTests: XCTestCase {
    private let options: JSONValue = .array([
        .object(["optionId": .string("allow-once"), "kind": .string("allow_once")]),
        .object(["optionId": .string("reject-once"), "kind": .string("reject_once")]),
    ])

    private func outcome(_ toolCall: [String: JSONValue], allowed: Set<String> = ["probe_echo"], updates: [JSONValue] = [], options: JSONValue? = nil) -> String? {
        let ledger = AcpToolCallLedger()
        ledger.allow(allowed)
        updates.forEach(ledger.record)
        var call = toolCall
        call["toolCallId"] = call["toolCallId"] ?? .string("t1")
        let result = AcpAgentProvider.permissionOutcome(.object(["toolCall": .object(call), "options": options ?? self.options]), ledger: ledger)
        return result["outcome"]?["optionId"]?.stringValue ?? result["outcome"]?["outcome"]?.stringValue
    }

    func testPermissionIsGrantedOnlyForThisTurnsPerryTools() {
        XCTAssertEqual(outcome(["title": .string("perry-probe_echo: probe_echo"), "kind": .string("other")]), "allow-once")
        XCTAssertEqual(outcome(["title": .string("mcp__perry__probe_echo")]), "allow-once")
        XCTAssertEqual(outcome(["rawInput": .object(["providerIdentifier": .string("perry"), "toolName": .string("probe_echo")])]), "allow-once")
        let devin: JSONValue = .object(["toolCallId": .string("t1"), "title": .string("Calling probe_echo from perry"), "_meta": .object(["cognition.ai/toolName": .string("mcp__perry__probe_echo")])])
        XCTAssertEqual(outcome([:], updates: [devin]), "allow-once")
        XCTAssertEqual(outcome(["title": .string("Calling probe_echo from perry; rm -rf ~")]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("Run rm -rf ~/Documents")]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("perry: files_trash")]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("Run echo perry probe_echo")]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("perry: probe_echo"), "kind": .string("execute")]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("Read /tmp/perry_screen_observe")], allowed: ["screen_observe"]), "reject-once")
        XCTAssertEqual(outcome([:]), "reject-once")
        XCTAssertEqual(outcome(["title": .string("Edit file")], allowed: [], options: .array([])), "cancelled")
    }

    func testPermissionUsesEverythingTheAgentReportedAboutTheCall() {
        let shell: JSONValue = .object(["toolCallId": .string("t1"), "kind": .string("execute"), "title": .string("touch /tmp/x")])
        XCTAssertEqual(outcome(["title": .string("perry: probe_echo")], updates: [shell]), "reject-once")
        let retitled: JSONValue = .object(["toolCallId": .string("t1"), "title": .string("Run touch /tmp/x")])
        XCTAssertEqual(outcome(["title": .string("perry: probe_echo")], updates: [retitled]), "reject-once")
        let other: JSONValue = .object(["toolCallId": .string("t2"), "kind": .string("execute")])
        XCTAssertEqual(outcome(["title": .string("perry: probe_echo")], updates: [other]), "allow-once")
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
