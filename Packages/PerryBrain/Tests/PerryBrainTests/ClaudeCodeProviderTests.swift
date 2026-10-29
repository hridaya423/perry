import Foundation
import XCTest
@testable import PerryBrain

final class ClaudeCodeProviderTests: XCTestCase {
    func testTopLevelTextDeltasStreamAndNestedAgentTextIsIgnored() {
        let top = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}},"parent_tool_use_id":null}"#
        let nested = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}},"parent_tool_use_id":"toolu_1"}"#
        guard case .model(.textDelta("hi"))? = ClaudeCodeProvider.event(from: top, provider: .claudeCode) else {
            return XCTFail("expected a text delta")
        }
        XCTAssertNil(ClaudeCodeProvider.event(from: nested, provider: .claudeCode))
    }

    func testResultMapsToDoneOrFailure() {
        let success = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"ok"}"#
        guard case .done(.endTurn)? = ClaudeCodeProvider.event(from: success, provider: .claudeCode) else {
            return XCTFail("expected end of turn")
        }
        let failure = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        guard case .failure(let error as ModelProviderError)? = ClaudeCodeProvider.event(from: failure, provider: .claudeCode) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error.kind, .unauthenticated)
    }

    func testInputCarriesEarlierTurnsAsTextAndTheLatestImage() throws {
        let line = try ClaudeCodeProvider.inputLine(for: [
            .user([.text("What is this?")]),
            .assistant(text: "A chart.", toolCalls: []),
            .user([.text("And now?"), .image(data: Data([1, 2]), mimeType: "image/png")]),
        ])
        let payload = try JSONValue(parsing: line)
        let content = try XCTUnwrap(payload["message"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["text"]?.stringValue, "Earlier in this conversation:\nUser: What is this?\nYou: A chart.")
        XCTAssertEqual(content[1]["text"]?.stringValue, "And now?")
        XCTAssertEqual(content[2]["source"]?["data"]?.stringValue, Data([1, 2]).base64EncodedString())
    }

    func testToolArgumentsAllowOnlyTheTurnToolsThroughThePerryServer() throws {
        let scope = MCPScope(socketPath: "/tmp/s.sock", token: "t0k", close: {})
        let arguments = ClaudeCodeProvider.toolArguments(
            helper: URL(fileURLWithPath: "/Apps/Perry.app/Contents/MacOS/perry-mcp"),
            scope: scope, wireNames: ["screen_observe": "screen.observe", "files_read": "files.read"]
        )
        XCTAssertEqual(arguments[2], "--allowedTools")
        XCTAssertEqual(arguments[3], "mcp__perry__files_read,mcp__perry__screen_observe")
        let config = try JSONValue(parsing: Data(arguments[1].utf8))
        XCTAssertEqual(config["mcpServers"]?["perry"]?["env"]?["PERRY_MCP_TOKEN"]?.stringValue, "t0k")
        XCTAssertTrue(ClaudeCodeProvider.baseArguments(system: "", model: nil).contains("--strict-mcp-config"))
        let fast = ClaudeCodeProvider.baseArguments(system: "", model: BrainModelCatalog.claudeCode.fast, effort: ClaudeCodeProvider.effort(for: .fast))
        XCTAssertEqual(Array(fast.suffix(4)), ["--model", "claude-sonnet-5-5", "--effort", "low"])
        XCTAssertEqual(ClaudeCodeProvider.effort(for: .deep), "medium")
    }

    func testStreamsTextFromTheCLIAndFailsWhenItExitsWithoutAResult() async throws {
        let ok = try script("""
        cat > /dev/null
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}},"parent_tool_use_id":null}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn"}'
        """)
        var text = ""
        var done = false
        for try await event in ClaudeCodeProvider(executable: ok, helper: nil, scopes: nil).stream(ModelRequest(messages: [.user([.text("hi")])])) {
            if case .textDelta(let delta) = event { text += delta }
            if case .done(.endTurn) = event { done = true }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(done)

        let broken = try script("cat > /dev/null\necho 'boom' >&2\nexit 3")
        do {
            for try await _ in ClaudeCodeProvider(executable: broken, helper: nil, scopes: nil).stream(ModelRequest(messages: [.user([.text("hi")])])) {}
            XCTFail("expected a failure")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertTrue(error.message.contains("boom"))
        }
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
