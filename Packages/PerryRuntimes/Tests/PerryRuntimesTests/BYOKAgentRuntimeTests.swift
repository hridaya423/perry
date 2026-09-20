import Foundation
import XCTest
@testable import PerryRuntimes
import PerryCore

final class BYOKAgentRuntimeTests: XCTestCase {
    func testRejectsPlaintextRemoteEndpointBeforeSendingSecret() async {
        let runtime = BYOKAgentRuntime(
            endpoint: BYOKAgentEndpoint(baseURL: URL(string: "http://api.example.com")!, model: "test"),
            apiKeyProvider: { "secret" },
            transport: { _ in
                XCTFail("unsafe endpoint must not receive a request")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await runtime.plan(makeRequest())
            XCTFail("expected unsafe endpoint to fail")
        } catch let error as PlanError {
            XCTAssertTrue(error.message.contains("loopback"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPlanRequiresScreenContext() async {
        let runtime = BYOKAgentRuntime(
            endpoint: BYOKAgentEndpoint(baseURL: URL(string: "https://provider.example")!, model: "vision-model"),
            apiKeyProvider: { "secret" },
            transport: { _ in
                XCTFail("planning must not run without screen context")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await runtime.plan(makeRequest(context: .none))
            XCTFail("expected context requirement")
        } catch PlanningError.contextRequired {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testResponseTextExtractsStringAndPartContent() {
        let stringContent = Data(#"{"choices":[{"message":{"content":"{\"actions\":[]}"}}]}"#.utf8)
        XCTAssertEqual(BYOKAgentRuntime.responseText(from: stringContent), #"{"actions":[]}"#)

        let partsContent = Data(#"{"choices":[{"message":{"content":[{"text":"{\"a"},{"text":"ctions\":[]}"}]}}]}"#.utf8)
        XCTAssertEqual(BYOKAgentRuntime.responseText(from: partsContent), #"{"actions":[]}"#)

        XCTAssertNil(BYOKAgentRuntime.responseText(from: Data("not json".utf8)))
        XCTAssertNil(BYOKAgentRuntime.responseText(from: Data(#"{"choices":[]}"#.utf8)))
    }

    func testPlanSendsScreenshotAsOpenAICompatibleImageContent() async throws {
        let response = Data(#"{"choices":[{"message":{"content":"{\"actions\":[{\"summary\":\"press Save\",\"operation\":{\"computer\":{\"command\":{\"click\":{\"target\":{\"windowPixels\":{\"x\":10,\"y\":20}}}}}}}]}"}}]}"#.utf8)
        let runtime = BYOKAgentRuntime(
            endpoint: BYOKAgentEndpoint(baseURL: URL(string: "https://provider.example")!, model: "vision-model"),
            apiKeyProvider: { "secret" },
            transport: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
                XCTAssertEqual(content.count, 2)
                XCTAssertEqual(content[1]["type"] as? String, "image_url")
                return (
                    response,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let window = try XCTUnwrap(makeWindowIdentity())
        let plan = try await runtime.plan(makeRequest(
            goal: "press Save",
            context: .screen(ScreenContext(
                frontAppBundleID: "com.example.Editor",
                frontWindowTitle: "Report",
                screenshotJPEGData: Data([1, 2, 3]),
                targetWindow: window
            ))
        ))

        XCTAssertEqual(plan.actions.count, 1)
        guard case .computer(let actionWindow, let command) = plan.actions[0].operation,
              case .click = command else {
            return XCTFail("expected a bound computer click action")
        }
        XCTAssertEqual(actionWindow, window)
    }

    private func makeRequest(
        goal: String = "test",
        context: PlanningContext = .screen(ScreenContext())
    ) throws -> PlanningRequest {
        try PlanningRequest(
            goal: goal,
            taskID: TaskID("byok-test"),
            workspace: FileManager.default.temporaryDirectory,
            context: context
        )
    }

    private func makeWindowIdentity() -> ExecutableAction.WindowIdentity? {
        ExecutableAction.WindowIdentity(
            bundleID: "com.example.Editor",
            processID: 42,
            windowID: 7,
            connectionGeneration: 1
        )
    }
}
