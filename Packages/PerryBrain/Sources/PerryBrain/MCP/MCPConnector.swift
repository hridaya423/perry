import Foundation
import OSLog
import PerryCore

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

public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnlyHint: Bool?

    public init(name: String, description: String, inputSchema: JSONValue, readOnlyHint: Bool? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }
}

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

    public static func sanitize(_ raw: String) -> String {
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

public protocol MCPHTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data)
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public struct URLSessionMCPHTTP: MCPHTTPPerforming {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError(code: -32000, message: "non-HTTP response")
        }
        return (http, data)
    }
    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        try await URLSessionLineStreaming(session: session).lines(for: request)
    }
}

public actor HTTPMCPTransport: MCPTransport {
    private let endpoint: URL
    private let performer: any MCPHTTPPerforming
    private let headers: [String: String]
    private let auth: MCPOAuthSession?
    private var sessionID: String?
    private var nextID = 0
    private var closed = false

    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        auth: MCPOAuthSession? = nil,
        performer: any MCPHTTPPerforming = URLSessionMCPHTTP()
    ) throws {
        try NetworkEndpointPolicy.requireSafe(endpoint)
        self.endpoint = endpoint
        self.performer = performer
        self.headers = headers
        self.auth = auth
    }

    public func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard !closed else { throw MCPError(code: -32000, message: "transport closed") }
        nextID += 1
        let id = nextID
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        let response = try await post(.object(fields))
        guard let messageID = response["id"]?.doubleValue.map(Int.init), messageID == id else {
            throw MCPError(code: -32000, message: "MCP response id mismatch")
        }
        if let error = response["error"] {
            throw MCPError(
                code: Int(error["code"]?.doubleValue ?? -32603),
                message: error["message"]?.stringValue ?? "MCP error"
            )
        }
        return response["result"] ?? .object([:])
    }

    public func notify(method: String, params: JSONValue?) async throws {
        guard !closed else { return }
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        _ = try? await post(.object(fields))
    }

    public func close() async {
        closed = true
        guard sessionID != nil else { return }
        var request = baseRequest(token: await auth?.currentAccessToken)
        request.httpMethod = "DELETE"
        _ = try? await performer.data(for: request)
        sessionID = nil
    }

    private func baseRequest(token: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MCPServer.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        return request
    }

    private func post(_ message: JSONValue, mayRefresh: Bool = true) async throws -> JSONValue {
        let token: String?
        do {
            token = try await auth?.accessToken()
        } catch MCPAuthError.signInRequired {
            throw MCPUnauthorized(challenge: MCPAuthChallenge())
        }
        var request = baseRequest(token: token)
        request.httpMethod = "POST"
        request.httpBody = try message.data()
        let wantsID = message["id"]?.doubleValue.map(Int.init)

        let (response, lines) = try await performer.lines(for: request)
        if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        if response.statusCode == 401 {
            let challenge = MCPAuthChallenge(wwwAuthenticate: response.value(forHTTPHeaderField: "WWW-Authenticate"))
            guard let auth, let token, mayRefresh else { throw MCPUnauthorized(challenge: challenge) }
            do {
                _ = try await auth.refreshed(after: token)
            } catch MCPAuthError.signInRequired {
                throw MCPUnauthorized(challenge: challenge)
            }
            return try await post(message, mayRefresh: false)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPError(code: -32000, message: "MCP HTTP \(response.statusCode)")
        }
        let isSSE = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") ?? false

        var parser = SSEParser()
        var jsonBody = ""
        for try await line in lines {
            if isSSE {
                guard let event = parser.feed(line: line) else { continue }
                guard let parsed = try? JSONValue(parsing: Data(event.data.utf8)) else { continue }
                if wantsID == nil {
                    return parsed
                }
                if parsed["id"]?.doubleValue.map(Int.init) == wantsID {
                    return parsed
                }
            } else {
                jsonBody += line
            }
        }
        if !isSSE {
            if jsonBody.isEmpty { return .object([:]) }
            if let parsed = try? JSONValue(parsing: Data(jsonBody.utf8)) {
                return parsed
            }
            throw MCPError(code: -32000, message: "malformed MCP response body")
        }
        if let event = parser.finish(),
           let parsed = try? JSONValue(parsing: Data(event.data.utf8)),
           parsed["id"]?.doubleValue.map(Int.init) == wantsID {
            return parsed
        }
        throw MCPError(code: -32000, message: "MCP stream ended without a matching response")
    }
}

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

    public init(command: String, arguments: [String] = [], environment: [String: String]? = nil, onExit: (@Sendable () -> Void)? = nil) throws {
        signal(SIGPIPE, SIG_IGN)
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
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            lock.withLock { self.finished = true }
            failAll()
            onExit?()
        }
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
        guard !lock.withLock({ finished }) else { throw MCPError(code: -32000, message: "MCP server exited") }
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
