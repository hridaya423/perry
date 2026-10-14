import Foundation
import PerryCore

/// What the perry-mcp helper needs from the running app: the agent-surface
/// tool list and call dispatch. The Unix-socket client implements this.
public protocol MCPBridge: Sendable {
    func tools() async throws -> [ToolSpec]
    func call(name: String, arguments: JSONValue) async throws -> ToolResult
}

/// Minimal MCP (Model Context Protocol) server core: newline-delimited
/// JSON-RPC over stdio. Pure string-in/string-out so it is fully testable;
/// `Sources/perry-mcp/main.swift` wires stdin/stdout to it.
public final class MCPServer: Sendable {
    public static let protocolVersion = "2024-11-05"

    private let bridge: any MCPBridge
    private let serverName: String
    private let version: String

    public init(bridge: any MCPBridge, serverName: String = "perry", version: String) {
        self.bridge = bridge
        self.serverName = serverName
        self.version = version
    }

    /// Handles one JSON-RPC line. Returns the response line, or nil for
    /// notifications and unparseable input (MCP drops both silently).
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let request = try? JSONValue(parsing: data),
              let method = request["method"]?.stringValue else { return nil }
        let id = request["id"]

        // Notifications carry no id and never get a response.
        if method.hasPrefix("notifications/") || id == nil { return nil }

        return await respond(to: method, id: id!, params: request["params"])
    }

    private func respond(to method: String, id: JSONValue, params: JSONValue?) async -> String? {
        func ok(_ value: JSONValue) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
        }
        func err(_ code: Int, _ message: String) -> JSONValue {
            .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .number(Double(code)), "message": .string(message)]),
            ])
        }

        let response: JSONValue
        switch method {
        case "initialize":
            response = ok(.object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(version),
                ]),
            ]))
        case "ping":
            response = ok(.object([:]))
        case "tools/list":
            do {
                let specs = try await bridge.tools()
                response = ok(.object([
                    "tools": .array(specs.map { spec in
                        .object([
                            "name": .string(spec.name),
                            "description": .string(spec.description),
                            "inputSchema": spec.inputSchema,
                            "annotations": .object([
                                "readOnlyHint": .bool(spec.readOnly),
                                "destructiveHint": .bool(spec.tier >= .orange),
                            ]),
                        ])
                    }),
                ]))
            } catch {
                response = err(-32603, "tools/list failed")
            }
        case "resources/list":
            response = ok(.object(["resources": .array([])]))
        case "resources/templates/list":
            response = ok(.object(["resourceTemplates": .array([])]))
        case "prompts/list":
            response = ok(.object(["prompts": .array([])]))
        case "logging/setLevel":
            response = ok(.object([:]))
        case "tools/call":
            guard let name = params?["name"]?.stringValue else {
                response = err(-32602, "tools/call requires params.name")
                break
            }
            do {
                let toolResult = try await bridge.call(
                    name: name, arguments: params?["arguments"] ?? .object([:])
                )
                let content: [JSONValue] = toolResult.content.map { part in
                    switch part {
                    case .text(let text):
                        .object(["type": .string("text"), "text": .string(text)])
                    case .image(let data, let mimeType):
                        .object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)])
                    }
                }
                response = ok(.object([
                    "content": .array(content),
                    "isError": .bool(toolResult.isError),
                ]))
            } catch {
                response = err(-32603, "tools/call failed")
            }
        default:
            response = err(-32601, "unknown method: \(method)")
        }

        guard let encoded = try? response.data(),
              let line = String(data: encoded, encoding: .utf8) else { return nil }
        return line
    }
}

/// Per-launch authenticated socket: a random 0600 token file in Perry's
/// support directory. perry-mcp presents it; the app refuses anything else.
public enum SocketAuth {
    public static let tokenFileName = "perry-mcp.token"

    /// Loads the token, creating a fresh random 64-hex one with 0600 perms
    /// when absent or unreadable.
    @discardableResult
    public static func ensureToken(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(tokenFileName)
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        return try mintToken(in: directory)
    }

    /// Always mints a fresh token, replacing any existing file. Perry calls
    /// this at each socket admission era (start/resume): a token captured
    /// during one era stops working in the next, matching the per-launch
    /// contract. Connected clients are unaffected — the token is checked
    /// once at handshake, and connected fds close when admission ends.
    @discardableResult
    public static func mintToken(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(tokenFileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    public static func authorize(_ presented: String, in directory: URL) -> Bool {
        guard let stored = try? String(contentsOf: directory.appendingPathComponent(tokenFileName),
                                     encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else { return false }
        let a = Array(presented.utf8), b = Array(stored.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
