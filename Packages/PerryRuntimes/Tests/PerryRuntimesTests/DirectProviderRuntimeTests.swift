import XCTest
@testable import PerryRuntimes
import PerryCore

final class DirectProviderRuntimeTests: XCTestCase {
    func testOfficialHostLookupMatchesEveryProviderDefaultHostCaseInsensitively() throws {
        for provider in DirectAIProvider.allCases {
            let host = try XCTUnwrap(provider.defaultBaseURL.host)

            XCTAssertEqual(DirectAIProvider(officialHost: host), provider)
            XCTAssertEqual(DirectAIProvider(officialHost: host.uppercased()), provider)
        }
    }

    func testOfficialHostLookupRejectsLookalikeAndCustomHosts() throws {
        var rejectedHosts = ["provider.example"]
        for provider in DirectAIProvider.allCases {
            let host = try XCTUnwrap(provider.defaultBaseURL.host)
            rejectedHosts.append(contentsOf: ["evil.\(host)", "\(host).evil.example"])
        }

        for host in rejectedHosts {
            XCTAssertNil(DirectAIProvider(officialHost: host), host)
        }
    }

    func testEveryProviderBuildsItsOfficialRequestShapeAndParsesAPlan() async throws {
        for fixture in try fixtures() {
            let runtime = DirectProviderRuntime(
                configuration: DirectProviderConfiguration(provider: fixture.provider, model: "vision-model"),
                apiKeyProvider: { "secret-key" },
                transport: { request in
                    XCTAssertEqual(request.url?.absoluteString, fixture.url)
                    XCTAssertEqual(request.value(forHTTPHeaderField: fixture.authenticationHeader), fixture.authenticationValue)
                    let body = try XCTUnwrap(request.httpBody)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    try fixture.assertBody(object)
                    return (fixture.response, try Self.response(url: XCTUnwrap(request.url)))
                }
            )

            let plan = try await runtime.plan(makeRequest())

            XCTAssertEqual(plan.actions.count, 1)
            guard case .computer(let window, let command) = plan.actions[0].operation,
                  case .click(let selector) = command,
                  case .accessibilityID(let target) = selector else {
                return XCTFail("expected a bound computer click action, got \(plan.actions[0].operation)")
            }
            XCTAssertEqual(target, "save-button")
            XCTAssertEqual(window, Self.window)
        }
    }

    func testUnsafeEndpointFailsBeforeReadingTheAPIKeyOrReachingTransport() async throws {
        let keyRead = LockedValue(false)
        let transportReached = LockedValue(false)
        let runtime = DirectProviderRuntime(
            configuration: DirectProviderConfiguration(
                provider: .openAI,
                model: "model",
                baseURL: try XCTUnwrap(URL(string: "http://provider.example"))
            ),
            apiKeyProvider: {
                keyRead.value = true
                return "secret"
            },
            transport: { request in
                transportReached.value = true
                return (Data(), try Self.response(url: XCTUnwrap(request.url)))
            }
        )

        do {
            _ = try await runtime.plan(makeRequest())
            XCTFail("Expected the unsafe endpoint to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("plaintext"))
        }
        XCTAssertFalse(keyRead.value)
        XCTAssertFalse(transportReached.value)
    }

    func testMissingModelAndCredentialFailBeforeTransport() async throws {
        let transportCount = LockedValue(0)
        let missingModel = DirectProviderRuntime(
            configuration: DirectProviderConfiguration(provider: .gemini, model: "  "),
            apiKeyProvider: { "secret" },
            transport: { request in
                transportCount.value += 1
                return (Data(), try Self.response(url: XCTUnwrap(request.url)))
            }
        )
        let missingCredential = DirectProviderRuntime(
            configuration: DirectProviderConfiguration(provider: .anthropic, model: "model"),
            apiKeyProvider: { nil },
            transport: { request in
                transportCount.value += 1
                return (Data(), try Self.response(url: XCTUnwrap(request.url)))
            }
        )

        for runtime in [missingModel, missingCredential] {
            do {
                _ = try await runtime.plan(makeRequest())
                XCTFail("Expected invalid configuration to fail")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
        XCTAssertEqual(transportCount.value, 0)
    }

    private struct Fixture {
        let provider: DirectAIProvider
        let url: String
        let authenticationHeader: String
        let authenticationValue: String
        let response: Data
        let assertBody: ([String: Any]) throws -> Void
    }

    private func fixtures() throws -> [Fixture] {
        let plan = #"{"actions":[{"summary":"Save","operation":{"computer":{"command":{"click":{"target":{"accessibilityID":"save-button"}}}}}}]}"#
        return [
            Fixture(
                provider: .openAI,
                url: "https://api.openai.com/v1/chat/completions",
                authenticationHeader: "Authorization",
                authenticationValue: "Bearer secret-key",
                response: try json(["choices": [["message": ["content": plan]]]]),
                assertBody: { body in
                    XCTAssertEqual(body["model"] as? String, "vision-model")
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
                    XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image_url"])
                }
            ),
            Fixture(
                provider: .openRouter,
                url: "https://openrouter.ai/api/v1/chat/completions",
                authenticationHeader: "Authorization",
                authenticationValue: "Bearer secret-key",
                response: try json(["choices": [["message": ["content": plan]]]]),
                assertBody: { body in
                    XCTAssertEqual(body["model"] as? String, "vision-model")
                }
            ),
            Fixture(
                provider: .anthropic,
                url: "https://api.anthropic.com/v1/messages",
                authenticationHeader: "x-api-key",
                authenticationValue: "secret-key",
                response: try json(["content": [["type": "text", "text": plan]]]),
                assertBody: { body in
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
                    XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
                }
            ),
            Fixture(
                provider: .gemini,
                url: "https://generativelanguage.googleapis.com/v1beta/models/vision-model:generateContent",
                authenticationHeader: "x-goog-api-key",
                authenticationValue: "secret-key",
                response: try json(["candidates": [["content": ["parts": [["text": plan]]]]]]),
                assertBody: { body in
                    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                    let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                    XCTAssertNotNil(parts.first?["text"])
                    XCTAssertNotNil(parts.last?["inline_data"])
                }
            ),
        ]
    }

    private static let window = ExecutableAction.WindowIdentity(
        bundleID: "com.example.App",
        processID: 42,
        windowID: 7,
        connectionGeneration: 1
    )

    private func makeRequest() throws -> PlanningRequest {
        try PlanningRequest(
            goal: "Save",
            taskID: TaskID("direct-provider-test"),
            workspace: FileManager.default.temporaryDirectory,
            context: .screen(ScreenContext(
                frontAppBundleID: "com.example.App",
                screenshotJPEGData: Data([1, 2, 3]),
                screenshotMIMEType: "image/jpeg",
                screenshotCoordinateSpace: .windowPixels,
                targetWindow: Self.window
            ))
        )
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func response(url: URL) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}
