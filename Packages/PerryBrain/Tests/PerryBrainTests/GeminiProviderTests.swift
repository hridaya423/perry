import Foundation
@testable import PerryBrain
import XCTest

final class GeminiProviderTests: XCTestCase {
    private func provider(_ transport: FixtureLineStreaming) -> GeminiProvider {
        GeminiProvider(apiKeyProvider: { "gm-test" }, transport: transport)
    }

    func testTruncatedStreamDoesNotInventCompletion() async throws {
        let body = #"data: {"candidates":[{"content":{"parts":[{"text":"Partial"}]}}]}"# + "\n\n"
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
        let transport = try FixtureLineStreaming(fixture: "gemini-text")
        _ = try await drain(provider(transport).stream(ModelRequest(
            system: "be terse",
            messages: [
                .user([.text("hi"), .image(data: Data([7]), mimeType: "image/jpeg")]),
                .assistant(text: "hello", toolCalls: []),
            ],
            tools: [sampleTool],
            tier: .deep
        )))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
        XCTAssertEqual(request.url?.query, "alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gm-test")
        let body = try XCTUnwrap(JSONValue(parsing: request.httpBody ?? Data()))
        XCTAssertEqual(body["systemInstruction"]?["parts"]?.arrayValue?[0]["text"], .string("be terse"))
        let contents = try XCTUnwrap(body["contents"]?.arrayValue)
        XCTAssertEqual(contents[0]["role"], .string("user"))
        XCTAssertEqual(contents[0]["parts"]?.arrayValue?[1]["inline_data"]?["mime_type"], .string("image/jpeg"))
        XCTAssertEqual(contents[1]["role"], .string("model"))
        XCTAssertEqual(body["tools"]?.arrayValue?[0]["functionDeclarations"]?.arrayValue?[0]["name"], .string("get_weather"))
    }

    func testTextStream() async throws {
        let transport = try FixtureLineStreaming(fixture: "gemini-text")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(text(events), "Hello there")
        XCTAssertTrue(events.contains(.usage(inputTokens: 10, outputTokens: 5)))
        XCTAssertEqual(stopReason(events), .endTurn)
    }

    func testToolCall() async throws {
        let transport = try FixtureLineStreaming(fixture: "gemini-toolcall")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        let calls = toolCalls(events)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "get_weather")
        XCTAssertEqual(calls[0].arguments["city"], .string("Paris"))
        XCTAssertEqual(stopReason(events), .toolUse)
    }

    func testTwoParallelToolCalls() async throws {
        let transport = try FixtureLineStreaming(fixture: "gemini-two-toolcalls")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(toolCalls(events).map(\.name), ["get_weather", "get_time"])
    }

    func testMaxTokens() async throws {
        let transport = try FixtureLineStreaming(fixture: "gemini-maxtokens")
        let events = try await drain(provider(transport).stream(sampleRequest()))
        XCTAssertEqual(stopReason(events), .maxTokens)
    }

    func testErrorPayload() async throws {
        let transport = try FixtureLineStreaming(fixture: "gemini-error")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected error")
        } catch let error as ModelProviderError {
            XCTAssertTrue(error.message.contains("backend exploded"))
        }
    }

    func testUnauthorized() async throws {
        let transport = FixtureLineStreaming(statusCode: 401, body: "bad key")
        do {
            _ = try await drain(provider(transport).stream(sampleRequest()))
            XCTFail("expected unauthenticated")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .unauthenticated)
        }
    }
}
