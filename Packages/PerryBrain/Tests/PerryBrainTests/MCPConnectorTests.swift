import XCTest
import PerryCore
@testable import PerryBrain

/// Scriptable in-memory MCPTransport: each method maps to a canned result
/// (or a closure for echo-style responses). Requests are recorded.
private final class FakeTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(method: String, params: JSONValue?)] = []
    var handlers: [String: (JSONValue?) throws -> JSONValue] = [:]
    var closed = false

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        lock.withLock { requests.append((method, params)) }
        guard let handler = handlers[method] else {
            throw MCPError(code: -32601, message: "unknown method: \(method)")
        }
        return try handler(params)
    }

    func notify(method: String, params: JSONValue?) async throws {
        lock.withLock { requests.append((method, params)) }
    }

    func close() async { lock.withLock { closed = true } }
}

private func fakeInitializeResult() -> JSONValue {
    .object([
        "protocolVersion": .string(MCPServer.protocolVersion),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": .string("Fake Tools"), "version": .string("1.0")]),
    ])
}

private func fakeTools(_ cursor: String?) -> JSONValue {
    let search: JSONValue = .object([
        "name": .string("search"), "description": .string("Search things"),
        "inputSchema": .object(["type": .string("object")]),
        "annotations": .object(["readOnlyHint": .bool(true)]),
    ])
    let mutate: JSONValue = .object([
        "name": .string("mutate"), "description": .string("Change things"),
        "inputSchema": .object(["type": .string("object")]),
    ])
    if cursor == "page2" {
        return .object(["tools": .array([mutate])])
    }
    return .object(["tools": .array([search]), "nextCursor": .string("page2")])
}

final class MCPConnectorTests: XCTestCase {
    private func connector(transport: FakeTransport) -> MCPConnector {
        transport.handlers["initialize"] = { _ in fakeInitializeResult() }
        transport.handlers["tools/list"] = { params in fakeTools(params?["cursor"]?.stringValue) }
        transport.handlers["tools/call"] = { params in
            .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("echo:\(params?["name"]?.stringValue ?? "")"),
                ])]),
                "isError": .bool(false),
            ])
        }
        return MCPConnector(transport: transport, clientVersion: "test")
    }

    func testInitializeHandshake() async throws {
        let transport = FakeTransport()
        let conn = connector(transport: transport)
        let info = try await conn.initialize()
        XCTAssertEqual(info.serverName, "Fake Tools")
        XCTAssertEqual(info.protocolVersion, MCPServer.protocolVersion)
        XCTAssertEqual(
            transport.requests.map(\.method),
            ["initialize", "notifications/initialized"]
        )
    }

    func testCallsBeforeInitializeFail() async throws {
        let conn = connector(transport: FakeTransport())
        await XCTAssertThrowsErrorAsyncVoid(try await conn.listTools())
    }

    func testListToolsPaginates() async throws {
        let transport = FakeTransport()
        let conn = connector(transport: transport)
        try await conn.initialize()
        let tools = try await conn.listTools()
        XCTAssertEqual(tools.map(\.name), ["search", "mutate"])
        XCTAssertEqual(tools.first?.readOnlyHint, true)
        XCTAssertEqual(tools.last?.readOnlyHint, nil)
        // page 2 was requested with the cursor
        let listCalls = transport.requests.filter { $0.method == "tools/list" }
        XCTAssertEqual(listCalls.count, 2)
        XCTAssertEqual(listCalls.last?.params?["cursor"]?.stringValue, "page2")
    }

    func testCallToolMapsContent() async throws {
        let conn = connector(transport: FakeTransport())
        try await conn.initialize()
        let result = try await conn.callTool(name: "search", arguments: .object(["q": .string("x")]))
        XCTAssertFalse(result.isError)
        guard case .text(let text)? = result.content.first else { return XCTFail() }
        XCTAssertEqual(text, "echo:search")
    }

    func testCallToolMapsImagePart() async throws {
        let transport = FakeTransport()
        let conn = connector(transport: transport)
        transport.handlers["tools/call"] = { _ in
            .object([
                "content": .array([.object([
                    "type": .string("image"),
                    "data": .string(Data([1, 2, 3]).base64EncodedString()),
                    "mimeType": .string("image/png"),
                ])]),
            ])
        }
        try await conn.initialize()
        let result = try await conn.callTool(name: "shot", arguments: .object([:]))
        guard case .image(let data, let mime)? = result.content.first else { return XCTFail() }
        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual(mime, "image/png")
    }

    func testExecutorsBridgeTiersAndCalls() async throws {
        let conn = connector(transport: FakeTransport())
        try await conn.initialize()
        let executors = try await conn.makeExecutors()
        let host = PerryToolHost(executors: executors)

        let names = host.specs(for: .agent).map(\.name)
        XCTAssertEqual(names, ["mcp.fake-tools.mutate", "mcp.fake-tools.search"])

        // readOnlyHint → green read-only, runs without approval.
        let read = await host.handle(
            ToolCall(id: "c1", name: "mcp.fake-tools.search", arguments: .object([:])),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(read.isError)

        // unknown effect → orange, fails closed without an approver.
        let denied = await host.handle(
            ToolCall(id: "c2", name: "mcp.fake-tools.mutate", arguments: .object([:])),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(denied.isError)

        let approved = await host.handle(
            ToolCall(id: "c3", name: "mcp.fake-tools.mutate", arguments: .object([:])),
            context: ToolContext(surface: .agent, approve: { _, _ in .approvedOnce })
        )
        XCTAssertFalse(approved.isError)
        guard case .text(let text)? = approved.content.first else { return XCTFail() }
        XCTAssertEqual(text, "echo:mutate")

        // And never on the talk surface.
        let talk = await host.handle(
            ToolCall(id: "c4", name: "mcp.fake-tools.search", arguments: .object([:])),
            context: ToolContext(surface: .talk)
        )
        XCTAssertTrue(talk.isError)
    }

    func testTierOverride() async throws {
        let conn = connector(transport: FakeTransport())
        try await conn.initialize()
        let executors = try await conn.makeExecutors(tierOverrides: ["mutate": .red])
        XCTAssertEqual(executors.first { $0.spec.name == "mcp.fake-tools.mutate" }?.spec.tier, .red)
    }

    // MARK: - stdio transport against the python fixture

    private func fixtureServer() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "fake-mcp-server", withExtension: "py", subdirectory: "Fixtures")
        )
    }

    func testStdioTransportRoundTrip() async throws {
        let transport = try StdioMCPTransport(
            command: "/usr/bin/python3",
            arguments: ["-u", try fixtureServer().path]
        )
        defer { Task { await transport.close() } }

        try await withTimeout(15) {
            let conn = MCPConnector(transport: transport, clientVersion: "test")
            let info = try await conn.initialize()
            XCTAssertEqual(info.serverName, "Fake Tools")

            let tools = try await conn.listTools()
            XCTAssertEqual(tools.map(\.name), ["search", "mutate"])

            let result = try await conn.callTool(
                name: "search", arguments: .object(["q": .string("perry")])
            )
            guard case .text(let text)? = result.content.first else {
                XCTFail("expected text")
                return
            }
            XCTAssertTrue(text.contains("\"search\""))
            XCTAssertTrue(text.contains("perry"))

            let failed = try await conn.callTool(name: "fail_tool", arguments: .object([:]))
            XCTAssertTrue(failed.isError)
            await conn.close()
        }
    }
}

/// Canned HTTP performer: each request gets the queued (contentType, body)
/// response; requests are recorded.
private final class FakeHTTPPerformer: MCPHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var responses: [(status: Int, contentType: String, body: String, sessionID: String?)] = []

    func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        lock.withLock { requests.append(request) }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (http, Data())
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        lock.withLock { requests.append(request) }
        let canned = lock.withLock { () -> (status: Int, contentType: String, body: String, sessionID: String?) in
            responses.isEmpty ? (200, "application/json", "", nil) : responses.removeFirst()
        }
        var fields: [String: String] = ["Content-Type": canned.contentType]
        if let sessionID = canned.sessionID { fields["Mcp-Session-Id"] = sessionID }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: canned.status, httpVersion: nil, headerFields: fields
        )!
        let body = canned.body
        let stream = AsyncThrowingStream<String, Error> { continuation in
            body.split(separator: "\n", omittingEmptySubsequences: false).forEach {
                continuation.yield(String($0))
            }
            continuation.finish()
        }
        return (http, stream)
    }
}

private func jsonResponse(_ result: JSONValue, id: Double) -> String {
    let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(id), "result": result])
    return String(data: try! message.data(), encoding: .utf8)!
}

final class HTTPMCPTransportTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9999/mcp")!

    func testPlainJSONRoundTrip() async throws {
        let performer = FakeHTTPPerformer()
        performer.responses = [
            (200, "application/json", jsonResponse(fakeInitializeResult(), id: 1), "sess-1"),
            (202, "application/json", "", nil), // notifications/initialized
            (200, "application/json", jsonResponse(.object(["tools": .array([])]), id: 2), nil),
        ]
        let transport = try HTTPMCPTransport(endpoint: endpoint, performer: performer)
        let conn = MCPConnector(transport: transport, clientVersion: "test")
        try await conn.initialize()
        _ = try await conn.listTools()

        // Requests after initialize carry the captured session id.
        XCTAssertEqual(performer.requests.count, 3)
        let listRequest = performer.requests[2]
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
        XCTAssertEqual(
            listRequest.value(forHTTPHeaderField: "Accept"),
            "application/json, text/event-stream"
        )
    }

    func testSSEResponseEndsOnMatchingID() async throws {
        let performer = FakeHTTPPerformer()
        // Server interleaves a notification before the real response.
        let sse = """
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"n":1}}

        event: message
        data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"t1","description":"x","inputSchema":{"type":"object"}}]}}

        """
        performer.responses = [
            (200, "application/json", jsonResponse(fakeInitializeResult(), id: 1), nil),
            (202, "application/json", "", nil), // notifications/initialized
            (200, "text/event-stream", sse, nil), // tools/list (request id 2)
        ]
        let transport = try HTTPMCPTransport(endpoint: endpoint, performer: performer)
        let conn = MCPConnector(transport: transport, clientVersion: "test")
        try await conn.initialize()
        let tools = try await conn.listTools()
        XCTAssertEqual(tools.map(\.name), ["t1"])
    }

    func testSSENoMatchingIDThrows() async throws {
        let performer = FakeHTTPPerformer()
        let sse = "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n\n"
        performer.responses = [(200, "text/event-stream", sse, nil)]
        let transport = try HTTPMCPTransport(endpoint: endpoint, performer: performer)
        await XCTAssertThrowsErrorAsyncVoid(
            try await transport.request(method: "tools/list", params: nil)
        )
    }

    func testErrorAndStatusPropagation() async throws {
        let performer = FakeHTTPPerformer()
        performer.responses = [
            (200, "application/json",
             #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}"#, nil),
            (503, "application/json", "{}", nil),
        ]
        let transport = try HTTPMCPTransport(endpoint: endpoint, performer: performer)
        do {
            _ = try await transport.request(method: "x", params: nil)
            XCTFail()
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32601)
        }
        do {
            _ = try await transport.request(method: "y", params: nil)
            XCTFail()
        } catch let error as MCPError {
            XCTAssertTrue(error.message.contains("503"))
        }
    }

    func testLoopbackPolicy() {
        XCTAssertThrowsError(
            try HTTPMCPTransport(endpoint: URL(string: "http://example.com/mcp")!)
        )
        XCTAssertNoThrow(
            try HTTPMCPTransport(endpoint: URL(string: "https://mcp.example.com/mcp")!)
        )
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsyncVoid<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected error", file: file, line: line)
        } catch {}
    }
}
