import XCTest
@testable import PerryBrain

private struct StubBridge: MCPBridge {
    var specs: [ToolSpec] = []
    var result: ToolResult = .text("c1", "done")
    func tools() async throws -> [ToolSpec] { specs }
    func call(name: String, arguments: JSONValue) async throws -> ToolResult { result }
}

final class MCPServerTests: XCTestCase {
    private func parse(_ line: String?) throws -> JSONValue {
        guard let line, let data = line.data(using: .utf8) else {
            XCTFail("no response line")
            return .null
        }
        return try JSONValue(parsing: data)
    }

    func testInitialize() async throws {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ))
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.stringValue, "perry")
        XCTAssertEqual(response["id"], .number(1))
    }

    func testNotificationsGetNoResponse() async {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        let r1 = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let r2 = await server.handle(#"{"jsonrpc":"2.0","method":"ping"}"#) // no id → notification
        let r3 = await server.handle("not json")
        XCTAssertNil(r1)
        XCTAssertNil(r2)
        XCTAssertNil(r3)
    }

    func testPing() async throws {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        let response = try await parse(server.handle(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#))
        XCTAssertEqual(response["id"], .string("p"))
        XCTAssertEqual(response["result"], .object([:]))
    }

    func testToolsList() async throws {
        let spec = ToolSpec(
            name: "ui.click", description: "click",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        )
        let server = MCPServer(bridge: StubBridge(specs: [spec]), version: "1.0")
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        ))
        let tools = response["result"]?["tools"]?.arrayValue
        XCTAssertEqual(tools?.first?["name"]?.stringValue, "ui.click")
        XCTAssertNotNil(tools?.first?["inputSchema"])
    }

    func testToolsCall() async throws {
        let server = MCPServer(
            bridge: StubBridge(result: ToolResult(callID: "x", content: [.text("5 rows added")])),
            version: "1.0"
        )
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui.click","arguments":{"id":"e1"}}}"#
        ))
        XCTAssertEqual(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "5 rows added")
        XCTAssertEqual(response["result"]?["isError"], .bool(false))
    }

    func testToolsCallPreservesCapturedImage() async throws {
        let server = MCPServer(
            bridge: StubBridge(result: ToolResult(callID: "capture", content: [
                .text("Window"), .image(data: Data([1, 2]), mimeType: "image/png")
            ])), version: "1.0"
        )
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screen.observe"}}"#
        ))
        XCTAssertEqual(response["result"]?["content"]?.arrayValue, [
            .object(["type": .string("text"), "text": .string("Window")]),
            .object(["type": .string("image"), "data": .string("AQI="), "mimeType": .string("image/png")])
        ])
    }

    func testToolsCallMissingName() async throws {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}"#
        ))
        XCTAssertEqual(response["error"]?["code"], .number(-32602))
    }

    func testUnknownMethod() async throws {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        let response = try await parse(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"nope"}"#))
        XCTAssertEqual(response["error"]?["code"], .number(-32601))
    }

    func testEmptyResourceAndPromptLists() async throws {
        let server = MCPServer(bridge: StubBridge(), version: "1.0")
        for (method, key) in [
            ("resources/list", "resources"),
            ("resources/templates/list", "resourceTemplates"),
            ("prompts/list", "prompts"),
        ] {
            let response = try await parse(server.handle(
                #"{"jsonrpc":"2.0","id":9,"method":"\#(method)"}"#
            ))
            XCTAssertEqual(response["result"]?[key]?.arrayValue, [])
        }
        let log = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":10,"method":"logging/setLevel","params":{"level":"debug"}}"#
        ))
        XCTAssertEqual(log["result"], .object([:]))
    }

    func testToolsListEmitsAnnotations() async throws {
        let spec = ToolSpec(
            name: "files.read", description: "read",
            inputSchema: .object(["type": .string("object")]),
            tier: .green, readOnly: true
        )
        let server = MCPServer(bridge: StubBridge(specs: [spec]), version: "1.0")
        let response = try await parse(server.handle(
            #"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#
        ))
        let annotations = response["result"]?["tools"]?.arrayValue?.first?["annotations"]
        XCTAssertEqual(annotations?["readOnlyHint"], .bool(true))
        XCTAssertEqual(annotations?["destructiveHint"], .bool(false))
    }
}

final class SocketAuthTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEnsureTokenCreates0600() throws {
        let token = try SocketAuth.ensureToken(in: dir)
        XCTAssertEqual(token.count, 64)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(SocketAuth.tokenFileName).path
        )
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testTokenPersistsAcrossReads() throws {
        let first = try SocketAuth.ensureToken(in: dir)
        XCTAssertEqual(try SocketAuth.ensureToken(in: dir), first)
    }

    func testAuthorize() throws {
        let token = try SocketAuth.ensureToken(in: dir)
        XCTAssertTrue(SocketAuth.authorize(token, in: dir))
        XCTAssertFalse(SocketAuth.authorize("wrong", in: dir))
        XCTAssertFalse(SocketAuth.authorize("", in: dir))
        XCTAssertFalse(SocketAuth.authorize(
            String(repeating: "a", count: 64), in: dir.appendingPathComponent("nope")
        ))
    }
}
