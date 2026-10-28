import Foundation
@testable import PerryBrain
import XCTest

final class AnthropicMessagesProviderTests: XCTestCase {
    private func provider(_ transport: FixtureLineStreaming) -> AnthropicMessagesProvider {
        AnthropicMessagesProvider(apiKeyProvider: { "sk-ant-test" }, transport: transport)
    }

    func testTruncatedStreamDoesNotInventCompletion() async throws {
        let body = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}"# + "\n\n"
        let transport = FixtureLineStreaming(body: body)
        var received: [ModelEvent] = []
        do {
            for try await event in provider(transport).stream(sampleRequest()) { received.append(event) }
            XCTFail("A truncated stream must fail")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .malformed)
        }
        XCTAssertEqual(text(received), "Partial")
        XCTAssertNil(stopReason(received))
    }

    func testRequestBodyShape() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-text")
        _ = try await drain(provider(transport).stream(ModelRequest(
            system: "be terse",
            messages: [
                .user([.text("hi"), .image(data: Data([3]), mimeType: "image/jpeg")]),
                .assistant(text: "hello", toolCalls: [ToolCall(id: "toolu_1", name: "get_weather", arguments: .object(["city": .string("Paris")]))]),
                .toolResult(callID: "toolu_1", content: [.text("sunny")], isError: false),
            ],
            tools: [sampleTool],
            tier: .deep
        )))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONValue(parsing: request.httpBody ?? Data()))
        XCTAssertEqual(body["model"], .string("claude-sonnet-5-5"))
        XCTAssertEqual(body["system"], .string("be terse"))
        XCTAssertEqual(body["stream"], .bool(true))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages[0]["role"], .string("user"))
        XCTAssertEqual(messages[0]["content"]?.arrayValue?[1]["type"], .string("image"))
        XCTAssertEqual(messages[0]["content"]?.arrayValue?[1]["source"]?["type"], .string("base64"))
        XCTAssertEqual(messages[1]["role"], .string("assistant"))
        XCTAssertEqual(messages[1]["content"]?.arrayValue?[1]["type"], .string("tool_use"))
        XCTAssertEqual(messages[2]["content"]?.arrayValue?[0]["type"], .string("tool_result"))
        XCTAssertEqual(messages[2]["content"]?.arrayValue?[0]["tool_use_id"], .string("toolu_1"))
        XCTAssertEqual(body["tools"]?.arrayValue?[0]["name"], .string("get_weather"))
        XCTAssertNotNil(body["tools"]?.arrayValue?[0]["input_schema"])
    }

    func testTextStream() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-text")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(text(events), "Hello there")
        XCTAssertTrue(events.contains(.usage(inputTokens: 15, outputTokens: 6)))
        XCTAssertEqual(stopReason(events), .endTurn)
    }

    func testFragmentedToolCall() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-toolcall")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        let calls = toolCalls(events)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "toolu_1")
        XCTAssertEqual(calls[0].arguments["city"], .string("Paris"))
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testTwoParallelToolCalls() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-two-toolcalls")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(toolCalls(events).map(\.name), ["get_weather", "get_time"])
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testMaxTokens() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-maxtokens")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(stopReason(events), .maxTokens)
    }

    func testMalformedToolArguments() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-malformed")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected malformed error")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .malformed)
        }
    }

    func testErrorEvent() async throws {
        let transport = try FixtureLineStreaming(fixture: "anthropic-error")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected error")
        } catch let error as ModelProviderError {
            XCTAssertTrue(error.message.contains("overloaded"))
        }
    }

    func testRateLimited() async throws {
        let transport = FixtureLineStreaming(statusCode: 429, headers: ["retry-after": "5"], body: "{}")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected rateLimited")
        } catch let error as ModelProviderError {
            guard case .rateLimited = error.kind else {
                return XCTFail("wrong kind: \(error.kind)")
            }
        }
    }
}
