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
        XCTAssertEqual(ollama.map(\.name), ["llama3.2-vision:latest", "qwen3:latest"])
        XCTAssertEqual(ollama.first?.id, "local.ollama.llama3.2-vision:latest")
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
        XCTAssertEqual(lmStudio.map(\.name), ["gemma3-12b", "plain-text-model"])
    }

    func testLoadedContextUsesRuntimeConfigurationInsteadOfModelMaximum() async throws {
        let payloads: [(LocalModel.Server, String, String, Int?)] = [
            (.ollama, "qwen3:latest", #"{"models":[{"name":"qwen3:latest","context_length":4096},{"name":"other","context_length":99999}]}"#, 4096),
            (.ollama, "qwen3:latest", #"{"models":[]}"#, nil),
            (.ollama, "qwen3:latest", #"{"models":[{"name":"qwen3:latest","context_length":-1}]}"#, nil),
            (.ollama, "qwen3:latest", #"{"models":[{"name":"qwen3:latest","context_length":4096.5}]}"#, nil),
            (.lmStudio, "model", #"{"models":[{"type":"llm","key":"model","max_context_length":131072,"loaded_instances":[{"id":"instance","config":{"context_length":8192}},{"id":"other-instance","config":{"context_length":4096}}]}]}"#, 4096),
            (.lmStudio, "instance", #"{"models":[{"type":"llm","key":"model","max_context_length":131072,"loaded_instances":[{"id":"instance","config":{"context_length":8192}}]}]}"#, 8192),
            (.lmStudio, "model", #"{"models":[{"type":"llm","key":"model","max_context_length":131072,"loaded_instances":[]}]}"#, nil)
        ]
        for (server, name, body, expected) in payloads {
            let discovery = LocalServerDiscovery(fetch: { request in
                XCTAssertEqual(request.url?.path, server == .ollama ? "/api/ps" : "/api/v1/models")
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let model = LocalModel(server: server, baseURL: URL(string: "http://127.0.0.1:11434")!, name: name)
            let capacity = try await discovery.loadedContextWindow(for: model)
            XCTAssertEqual(capacity, expected)
        }
    }

    func testContextLookupDoesNotHideServerOrProtocolFailures() async throws {
        let model = LocalModel(server: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!, name: "qwen3:latest")
        for body in ["not JSON", "{}"] {
            let discovery = LocalServerDiscovery(fetch: fetcher(returning: body, for: "127.0.0.1"))
            do {
                _ = try await discovery.loadedContextWindow(for: model)
                XCTFail("Malformed metadata must report a failure")
            } catch {}
        }
        do {
            _ = try await LocalServerDiscovery(fetch: fetcher(failingForAll: true)).loadedContextWindow(for: model)
            XCTFail("Unreachable server must report a failure")
        } catch {}
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
