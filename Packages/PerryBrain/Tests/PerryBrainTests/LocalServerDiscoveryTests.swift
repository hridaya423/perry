import Foundation
@testable import PerryBrain
import XCTest

final class LocalServerDiscoveryTests: XCTestCase {
    private func fetcher(returning body: String, for host: String) -> LocalServerDiscovery.Fetcher {
        { request in
            guard request.url?.host == host else {
                throw URLError(.cannotConnectToHost)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func fetcher(failingForAll: Bool) -> LocalServerDiscovery.Fetcher {
        { _ in throw URLError(.cannotConnectToHost) }
    }

    func testOllamaDiscovery() async throws {
        let discovery = LocalServerDiscovery(fetch: fetcher(returning: #"{"models":[{"name":"llama3.2-vision:latest","details":{"families":["mllama"]}},{"name":"qwen3:latest","details":{"families":["qwen3"]}}]}"#, for: "127.0.0.1"))
        let models = await discovery.discover()
        let ollama = models.filter { $0.server == .ollama }
        XCTAssertEqual(ollama.count, 2)
        XCTAssertTrue(ollama.first { $0.name == "llama3.2-vision:latest" }?.supportsVision == true)
        XCTAssertFalse(ollama.first { $0.name == "qwen3:latest" }?.supportsVision ?? true)
    }

    func testLMStudioDiscovery() async throws {
        let fetcher: LocalServerDiscovery.Fetcher = { request in
            let body: String
            switch request.url?.path {
            case "/v1/models":
                body = #"{"data":[{"id":"gemma3-12b"},{"id":"plain-text-model"}]}"#
            default:
                throw URLError(.cannotConnectToHost)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let discovery = LocalServerDiscovery(fetch: fetcher)
        let models = await discovery.discover()
        let lmStudio = models.filter { $0.server == .lmStudio }
        XCTAssertEqual(lmStudio.count, 2)
        XCTAssertTrue(lmStudio.first { $0.name == "gemma3-12b" }?.supportsVision == true)
    }

    func testBothServersDownReturnsEmpty() async throws {
        let discovery = LocalServerDiscovery(fetch: fetcher(failingForAll: true))
        let models = await discovery.discover()
        XCTAssertEqual(models, [])
    }

    func testNon2xxReturnsEmpty() async throws {
        let fetcher: LocalServerDiscovery.Fetcher = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let discovery = LocalServerDiscovery(fetch: fetcher)
        let models = await discovery.discover()
        XCTAssertEqual(models, [])
    }
}
