import Foundation
import OSLog
import PerryCore

/// Line-oriented JSON-RPC transport for a user-added MCP server.
/// `request` returns the server's `result` or throws its `error`.
public protocol MCPTransport: Sendable {
    func request(method: String, params: JSONValue?) async throws -> JSONValue
    func notify(method: String, params: JSONValue?) async throws
    func close() async
}

public struct MCPError: Error, Sendable, Equatable, LocalizedError {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// One tool advertised by a remote MCP server.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// From the server's tool annotations; nil means unknown.
    public var readOnlyHint: Bool?

    public init(name: String, description: String, inputSchema: JSONValue, readOnlyHint: Bool? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }
}

/// Client for a user-added MCP server (Phase 9 custom connectors). Speaks
/// the same NDJSON dialect as `MCPServer`. Remote tools are bridged into
/// `ToolExecutor`s on the `.agent` surface; unknown-effect tools default to
/// `.orange` so every call passes the approval path.
public actor MCPConnector {
    public struct Info: Sendable, Equatable {
        public var serverName: String
        public var serverVersion: String
        public var protocolVersion: String
    }

    private let transport: any MCPTransport
    private let clientName: String
    private let clientVersion: String
    private var ready = false
    private var serverName = "mcp"

    public init(transport: any MCPTransport, clientName: String = "perry", clientVersion: String) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    @discardableResult
    public func initialize() async throws -> Info {
        let result = try await transport.request(method: "initialize", params: .object([
            "protocolVersion": .string(MCPServer.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]))
        try await transport.notify(method: "notifications/initialized", params: nil)
        ready = true
        let serverInfo = result["serverInfo"]
        serverName = serverInfo?["name"]?.stringValue ?? "mcp"
        return Info(
            serverName: serverName,
            serverVersion: serverInfo?["version"]?.stringValue ?? "",
            protocolVersion: result["protocolVersion"]?.stringValue ?? MCPServer.protocolVersion
        )
    }

    /// All tools the server advertises, following `nextCursor` pagination.
    public func listTools() async throws -> [MCPTool] {
        try requireReady()
        var tools: [MCPTool] = []
        var cursor: String? = nil
        repeat {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await transport.request(method: "tools/list", params: params)
            for tool in result["tools"]?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                tools.append(MCPTool(
                    name: name,
                    description: tool["description"]?.stringValue ?? "",
                    inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")]),
                    readOnlyHint: tool["annotations"]?["readOnlyHint"]?.boolValue
                ))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return tools
    }

    /// `tools/call`; returns content parts and the server's isError flag.
    public func callTool(name: String, arguments: JSONValue) async throws -> (content: [ModelContentPart], isError: Bool) {
        try requireReady()
        let result = try await transport.request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        var content: [ModelContentPart] = []
        for part in result["content"]?.arrayValue ?? [] {
            switch part["type"]?.stringValue {
            case "text":
                if let text = part["text"]?.stringValue { content.append(.text(text)) }
            case "image":
                if let base64 = part["data"]?.stringValue, let data = Data(base64Encoded: base64) {
                    content.append(.image(data: data, mimeType: part["mimeType"]?.stringValue ?? "image/png"))
                }
            default:
                if let text = part["text"]?.stringValue { content.append(.text(text)) }
            }
        }
        return (content, result["isError"]?.boolValue ?? false)
    }

    /// Bridge every remote tool into a `ToolExecutor` named
    /// `mcp.<prefix>.<tool>` on the `.agent` surface. `tierOverrides` is keyed
    /// by the remote tool name; anything without a `readOnlyHint` defaults to
    /// `.orange` (unknown effect gets human review).
    public func makeExecutors(
        prefix: String? = nil,
        tierOverrides: [String: TrustTier] = [:]
    ) async throws -> [any ToolExecutor] {
        try requireReady()
        let name = prefix ?? serverName
        return try await listTools().map { tool in
            MCPToolExecutor(
                spec: ToolSpec(
                    name: "mcp.\(Self.sanitize(name)).\(tool.name)",
                    description: tool.description.isEmpty ? tool.name : tool.description,
                    inputSchema: tool.inputSchema,
                    tier: tierOverrides[tool.name] ?? (tool.readOnlyHint == true ? .green : .orange),
                    surfaces: [.agent],
                    readOnly: tool.readOnlyHint ?? false
                ),
                toolName: tool.name,
                connector: self
            )
        }
    }

    public func close() async {
        await transport.close()
    }

    private func requireReady() throws {
        guard ready else {
            throw MCPError(code: -32002, message: "MCP server not initialized")
        }
    }

    private static func sanitize(_ raw: String) -> String {
        let cleaned = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "mcp" : collapsed
    }
}

private struct MCPToolExecutor: ToolExecutor {
    let spec: ToolSpec
    let toolName: String
    let connector: MCPConnector

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let result = try await connector.callTool(name: toolName, arguments: call.arguments)
        return ToolResult(callID: call.id, content: result.content.isEmpty ? [.text("ok")] : result.content, isError: result.isError)
    }
}

/// NDJSON MCP transport over a child process's stdio. Requests are matched
/// to responses by `id`; a process exit fails every pending call.
public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 0
    private var buffer = Data()
    private var finished = false
    private let logger = Logger(subsystem: "ai.perry.brain", category: "mcp-stdio")

    /// `command` is an absolute executable path or a name resolved via PATH
    /// through `/usr/bin/env`. Extra `environment` entries are merged onto the
    /// inherited environment minus the usual host secrets are NOT filtered —
    /// the caller chooses the command; keep that in mind for user-added
    /// connectors. Perry sets this transport up only for explicitly added
    /// connector commands.
    public init(command: String, arguments: [String] = [], environment: [String: String]? = nil) throws {
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        if let environment {
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        self.process = process

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in self?.failAll() }
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public func request(method: String, params: JSONValue?) async throws -> JSONValue {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        let message = try JSONValue.object(fields).data()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: message + Data("\n".utf8))
            } catch {
                lock.withLock { pending.removeValue(forKey: id) }
                continuation.resume(throwing: error)
            }
        }
    }

    public func notify(method: String, params: JSONValue?) async throws {
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        try stdinPipe.fileHandleForWriting.write(contentsOf: JSONValue.object(fields).data() + Data("\n".utf8))
    }

    public func close() async {
        lock.withLock { finished = true }
        if process.isRunning { process.terminate() }
        failAll()
    }

    private func consume(_ data: Data) {
        if data.isEmpty { failAll(); return }
        lock.withLock { buffer.append(data) }
        while let newline = lock.withLock({ buffer.firstIndex(of: 0x0A) }) {
            let line = lock.withLock { () -> Data in
                let line = buffer.prefix(newline)
                buffer = buffer.dropFirst(newline + 1)
                return Data(line)
            }
            guard let message = try? JSONValue(parsing: line),
                  let id = message["id"]?.doubleValue.map(Int.init) else { continue }
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if let error = message["error"] {
                continuation?.resume(throwing: MCPError(
                    code: Int(error["code"]?.doubleValue ?? -32603),
                    message: error["message"]?.stringValue ?? "MCP error"
                ))
            } else {
                continuation?.resume(with: .success(message["result"] ?? .object([:])))
            }
        }
    }

    private func failAll() {
        let stranded = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for continuation in stranded {
            continuation.resume(throwing: MCPError(code: -32000, message: "MCP server exited"))
        }
    }
}
