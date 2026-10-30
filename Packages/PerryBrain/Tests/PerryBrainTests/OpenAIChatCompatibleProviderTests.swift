import Foundation
@testable import PerryBrain
import XCTest

final class OpenAIChatCompatibleProviderTests: XCTestCase {
    func testVersionedCustomBaseURLsDoNotRepeatTheVersionPath() async throws {
        for base in ["https://models.example.invalid", "https://models.example.invalid/v1", "https://models.example.invalid/v1/"] {
            let transport = try FixtureLineStreaming(fixture: "chat-text")
            let provider = HTTPModelProvider(
                wire: .openAIChat,
                id: "custom", displayName: "Custom", baseURL: URL(string: base)!,
                models: BrainModelDefaults(fast: "test-model", deep: "test-model"), transport: transport
            )
            _ = try await drain(provider.stream(sampleRequest()))
            XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://models.example.invalid/v1/chat/completions")
        }
    }

    private func provider(_ transport: FixtureLineStreaming) -> HTTPModelProvider {
        HTTPModelProvider(
            wire: .openAIChat,
            id: .openRouter,
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKeyProvider: { "sk-or-test" },
            models: BrainModelDefaults(fast: "openai/gpt-5-mini", deep: "openai/gpt-5"),
            capabilities: [.vision, .tools, .streaming],
            transport: transport
        )
    }

    func testTruncatedStreamDoesNotInventCompletion() async throws {
        let body = #"data: {"choices":[{"delta":{"content":"Partial"},"finish_reason":null}]}"# + "\n\n"
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

    func testContextCapacityIsReadThroughTheSelectedProvider() async throws {
        let provider: any ModelProvider = HTTPModelProvider(
            wire: .openAIChat,
            id: "local.test", displayName: "Local", baseURL: URL(string: "http://127.0.0.1:11434")!,
            models: BrainModelDefaults(fast: "model:7b", deep: "model:7b"),
            contextWindow: { tier in tier == .fast ? 4096 : 8192 }
        )
        let fast = try await provider.contextWindow(for: .fast)
        let deep = try await provider.contextWindow(for: .deep)
        XCTAssertEqual(fast, 4096)
        XCTAssertEqual(deep, 8192)
        let unknown: any ModelProvider = HTTPModelProvider(
            wire: .openAIChat,
            id: "custom", displayName: "Custom", baseURL: URL(string: "https://models.example.invalid")!,
            models: BrainModelDefaults(fast: "model", deep: "model")
        )
        let capacity = try await unknown.contextWindow(for: .fast)
        XCTAssertNil(capacity)
    }

    func testRequestBodyShape() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-text")
        _ = try await drain(provider(transport).stream(ModelRequest(
            system: "be terse",
            messages: [
                .user([.text("hi"), .image(data: Data([9]), mimeType: "image/jpeg")]),
                .assistant(text: "hello", toolCalls: [ToolCall(id: "c1", name: "get_weather", arguments: .object(["city": .string("Paris")]))]),
                .toolResult(callID: "c1", content: [.text("sunny")], isError: false),
            ],
            tools: [sampleTool],
            tier: .fast,
            maxOutputTokens: 64
        )))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        let body = try XCTUnwrap(JSONValue(parsing: request.httpBody ?? Data()))
        XCTAssertEqual(body["model"], .string("openai/gpt-5-mini"))
        XCTAssertEqual(body["stream_options"]?["include_usage"], .bool(true))
        XCTAssertEqual(body["max_tokens"], .number(64))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages[0]["role"], .string("system"))
        XCTAssertEqual(messages[1]["role"], .string("user"))
        XCTAssertEqual(messages[1]["content"]?.arrayValue?[1]["type"], .string("image_url"))
        XCTAssertEqual(messages[2]["tool_calls"]?.arrayValue?[0]["function"]?["name"], .string("get_weather"))
        XCTAssertEqual(messages[3]["role"], .string("tool"))
        XCTAssertEqual(messages[3]["tool_call_id"], .string("c1"))
        XCTAssertEqual(body["tools"]?.arrayValue?[0]["function"]?["name"], .string("get_weather"))
    }

    func testTextStream() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-text")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(text(events), "Hello there")
        XCTAssertTrue(events.contains(.usage(inputTokens: 9, outputTokens: 4)))
        XCTAssertEqual(stopReason(events), .endTurn)
    }

    func testFragmentedToolCall() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-toolcall")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        let calls = toolCalls(events)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].arguments["city"], .string("Paris"))
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testTwoParallelToolCalls() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-two-toolcalls")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(toolCalls(events).map(\.name), ["get_weather", "get_time"])
    }

    func testMaxTokens() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-length")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(stopReason(events), .maxTokens)
    }

    func testMalformedToolArguments() async throws {
        let transport = try FixtureLineStreaming(fixture: "chat-malformed")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected malformed error")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .malformed)
        }
    }

    func testUnauthorized() async throws {
        let transport = FixtureLineStreaming(statusCode: 403, body: "denied")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected unauthenticated")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .unauthenticated)
        }
    }

    func testLocalHostMarkedLocal() {
        let local = HTTPModelProvider(
            wire: .openAIChat,
            id: "local.ollama", displayName: "Ollama",
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            models: BrainModelDefaults(fast: "m", deep: "m")
        )
        XCTAssertTrue(local.capabilities.contains(.local))
    }
}
