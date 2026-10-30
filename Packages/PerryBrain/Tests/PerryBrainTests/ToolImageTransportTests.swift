import Foundation
import XCTest
@testable import PerryBrain

final class ToolImageTransportTests: XCTestCase {
    private var request: ModelRequest {
        ModelRequest(messages: [
            .assistant(text: "", toolCalls: [
                ToolCall(id: "capture", name: "screen.observe", arguments: .object([:])),
                ToolCall(id: "read", name: "document.read", arguments: .object([:]))
            ]),
            .toolResult(callID: "capture", content: [.text("window A"), .image(data: Data([1, 2, 3]), mimeType: "image/png")], isError: false),
            .toolResult(callID: "read", content: [.text("document text")], isError: false),
            .user([.text("Describe the captured window.")])
        ])
    }

    func testAnthropicRetainsImageInsideMatchingToolResult() throws {
        let provider = HTTPModelProvider.preset("anthropic")
        let body = try JSONValue(parsing: XCTUnwrap(provider.makeRequest(request).httpBody))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        let results = messages.flatMap { $0["content"]?.arrayValue ?? [] }
        let result = try XCTUnwrap(results.first { $0["tool_use_id"] == .string("capture") })
        let image = result["content"]?.arrayValue?.last
        XCTAssertEqual(image?["type"], .string("image"))
        XCTAssertEqual(image?["source"]?["media_type"], .string("image/png"))
        XCTAssertEqual(image?["source"]?["data"], .string("AQID"))
    }

    func testResponsesRetainsImageInsideMatchingToolOutput() throws {
        let provider = HTTPModelProvider.preset("openai")
        let body = try JSONValue(parsing: XCTUnwrap(provider.makeRequest(request).httpBody))
        let input = try XCTUnwrap(body["input"]?.arrayValue)
        let result = try XCTUnwrap(input.first { $0["type"] == .string("function_call_output") })
        XCTAssertEqual(result["call_id"], .string("capture"))
        XCTAssertEqual(result["output"]?.arrayValue?[0]["text"], .string("window A"))
        XCTAssertEqual(result["output"]?.arrayValue?[1]["type"], .string("input_image"))
        XCTAssertEqual(result["output"]?.arrayValue?[1]["image_url"], .string("data:image/png;base64,AQID"))
    }

    func testChatPlacesToolImagesAfterAllParallelResults() throws {
        let provider = HTTPModelProvider(wire: .openAIChat, id: "test", displayName: "Test", baseURL: URL(string: "https://fixture.invalid")!, models: BrainModelCatalog.openRouter)
        let body = try JSONValue(parsing: XCTUnwrap(provider.makeRequest(request).httpBody))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["assistant", "tool", "tool", "user", "user"])
        XCTAssertEqual(messages[1]["tool_call_id"], .string("capture"))
        XCTAssertEqual(messages[2]["tool_call_id"], .string("read"))
        let images = messages.flatMap { $0["content"]?.arrayValue ?? [] }.filter { $0["type"] == .string("image_url") }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?["image_url"]?["url"], .string("data:image/png;base64,AQID"))
        XCTAssertTrue(messages[3]["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("Tool call capture returned these images.") == true)
    }

    func testGeminiPreservesToolResponsesAndImageInOneUserTurn() throws {
        let provider = HTTPModelProvider.preset("gemini")
        let body = try JSONValue(parsing: XCTUnwrap(provider.makeRequest(request).httpBody))
        let contents = try XCTUnwrap(body["contents"]?.arrayValue)
        XCTAssertEqual(contents.compactMap { $0["role"]?.stringValue }, ["model", "user"])
        let parts = contents.flatMap { $0["parts"]?.arrayValue ?? [] }
        XCTAssertEqual(parts.compactMap { $0["functionResponse"]?["name"]?.stringValue }, ["capture", "read"])
        let images = parts.compactMap { $0["inline_data"] }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?["mime_type"], .string("image/png"))
        XCTAssertEqual(images.first?["data"], .string("AQID"))
        XCTAssertEqual(parts.last?["text"], .string("Describe the captured window."))
    }
}
