import Foundation
@testable import PerryBrain
import XCTest

final class OpenAIResponsesProviderTests: XCTestCase {
    private func provider(_ transport: any HTTPLineStreaming) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(apiKeyProvider: { "sk-test" }, transport: transport)
    }

    func testRequestBodyShape() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-text")
        let events = try await drain(provider(transport).stream(ModelRequest(
            system: "be terse",
            messages: [
                .user([.text("hi"), .image(data: Data([1, 2]), mimeType: "image/png")]),
                .assistant(text: "hello", toolCalls: [ToolCall(id: "c1", name: "get_weather", arguments: .object(["city": .string("Paris")]))]),
                .toolResult(callID: "c1", content: [.text("sunny")], isError: false),
            ],
            tools: [sampleTool],
            tier: .deep,
            maxOutputTokens: 123
        )))
        XCTAssertEqual(stopReason(events), .endTurn)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONValue(parsing: request.httpBody ?? Data()))
        XCTAssertEqual(body["model"], .string("gpt-5"))
        XCTAssertEqual(body["instructions"], .string("be terse"))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["max_output_tokens"], .number(123))

        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input.count, 4)
        let userParts = input[0]["content"]?.arrayValue
        XCTAssertEqual(userParts?[0]["type"], .string("input_text"))
        XCTAssertEqual(userParts?[1]["type"], .string("input_image"))
        XCTAssertTrue(userParts?[1]["image_url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(input[1]["role"], .string("assistant"))
        XCTAssertEqual(input[2]["type"], .string("function_call"))
        XCTAssertEqual(input[2]["call_id"], .string("c1"))
        XCTAssertEqual(input[3]["type"], .string("function_call_output"))
        XCTAssertEqual(input[3]["output"], .string("sunny"))

        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools[0]["type"], .string("function"))
        XCTAssertEqual(tools[0]["name"], .string("get_weather"))
        XCTAssertNotNil(tools[0]["parameters"])
    }

    func testTextStream() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-text")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(text(events), "Hello there")
        XCTAssertTrue(events.contains(.usage(inputTokens: 12, outputTokens: 7)))
        XCTAssertEqual(stopReason(events), .endTurn)
    }

    func testFragmentedToolCall() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-toolcall")
        let events = try await drain(provider(transport).stream(sampleRequest(tools: [sampleTool])))
        let calls = toolCalls(events)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].name, "get_weather")
        XCTAssertEqual(calls[0].arguments["city"], .string("Paris"))
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testTwoParallelToolCalls() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-two-toolcalls")
        let events = try await drain(provider(transport).stream(sampleRequest(tools: [sampleTool])))
        XCTAssertEqual(toolCalls(events).map(\.name), ["get_weather", "get_time"])
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testMaxTokensStop() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-maxtokens")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(stopReason(events), .maxTokens)
    }

    func testMalformedToolArguments() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-malformed")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected malformed error")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .malformed)
        }
    }

    func testUnauthorized() async throws {
        let transport = FixtureLineStreaming(statusCode: 401, body: "no")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected unauthenticated")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .unauthenticated)
        }
    }

    func testRateLimited() async throws {
        let transport = FixtureLineStreaming(statusCode: 429, headers: ["retry-after": "17"], body: "slow down")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected rateLimited")
        } catch let error as ModelProviderError {
            guard case .rateLimited(let resetAt) = error.kind else {
                return XCTFail("wrong kind: \(error.kind)")
            }
            XCTAssertNotNil(resetAt)
        }
    }

    func testStreamFailure() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-error")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected error")
        } catch let error as ModelProviderError {
            XCTAssertTrue(error.message.contains("backend exploded"))
        }
    }

    func testPlaintextNonLoopbackRejectedBeforeRequest() async throws {
        let transport = try FixtureLineStreaming(fixture: "openai-text")
        let insecure = OpenAIResponsesProvider(
            baseURL: URL(string: "http://example.com")!,
            apiKeyProvider: { "sk-test" },
            transport: transport
        )
        do {
            _ = try await drain(insecure.stream(sampleRequest()))
            XCTFail("expected endpoint rejection")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Network drop mid-stream: the transport stops producing lines without closing.
    /// Cancelling the consumer must settle the stream (and the transport task) within 2 s.
    func testStalledStreamSettlesAfterCancelWithinTwoSeconds() async throws {
        let transport = StallingLineStreaming(lines: [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hel\"}",
            "",
        ])
        let stream = provider(transport).stream(sampleRequest())
        let consumer = Task { () -> [ModelEvent] in
            var events: [ModelEvent] = []
            do { for try await event in stream { events.append(event) } } catch {}
            return events
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        consumer.cancel()
        let events = try await withTimeout(2) { await consumer.value }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(text(events), "Hel")
        try await withTimeout(2) { await transport.waitUntilTerminated() }
    }
}

private final class StallingLineStreaming: HTTPLineStreaming, @unchecked Sendable {
    private let lines: [String]
    private let terminated = AsyncStream<Void>.makeStream()
    init(lines: [String]) { self.lines = lines }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let lines = lines
        let done = terminated.continuation
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.onTermination = { _ in done.finish() }
        }
        return (response, stream)
    }

    func waitUntilTerminated() async {
        for await _ in terminated.stream {}
    }
}
