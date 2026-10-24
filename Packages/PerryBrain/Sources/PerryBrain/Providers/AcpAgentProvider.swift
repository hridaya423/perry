import Foundation

public struct AcpAgent: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var command: String
    public var arguments: [String]

    public init(id: String = UUID().uuidString, name: String, command: String, arguments: [String]) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
    }

    public static let known: [AcpAgent] = [
        AcpAgent(id: "cursor", name: "Cursor", command: "cursor-agent", arguments: ["acp"]),
        AcpAgent(id: "gemini", name: "Gemini CLI", command: "gemini", arguments: ["--experimental-acp"]),
        AcpAgent(id: "opencode", name: "OpenCode", command: "opencode", arguments: ["acp"]),
        AcpAgent(id: "goose", name: "Goose", command: "goose", arguments: ["acp"]),
    ]

    public func executable(searching paths: [String] = AcpAgent.searchPaths) -> URL? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        return paths.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var searchPaths: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin"]
    }
}

public final class AcpAgentProvider: ToolExecutingModelProvider, @unchecked Sendable {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming]

    private let executable: URL
    private let arguments: [String]
    private let helper: URL?
    private let scopes: (any MCPScopeHost)?

    public init(agent: AcpAgent, executable: URL, helper: URL?, scopes: (any MCPScopeHost)?) {
        self.id = ProviderID(rawValue: "acp.\(agent.id)")
        self.displayName = agent.name
        self.executable = executable
        self.arguments = agent.arguments
        self.helper = helper
        self.scopes = scopes
    }

    public func warm() async {}

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        var request = request
        request.tools = []
        return run(request, executeTool: nil)
    }

    public func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        run(request, executeTool: executeTool)
    }

    private func run(_ request: ModelRequest, executeTool: ToolExecutionHandler?) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.execute(request, executeTool: executeTool, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ request: ModelRequest, executeTool: ToolExecutionHandler?,
        continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("perry-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stop = AgentTurnStop()
        var mcpServers: [JSONValue] = []
        var wireNames: Set<String> = []
        var scope: MCPScope?
        defer { scope?.close() }
        if let executeTool, !request.tools.isEmpty {
            guard let helper, let scopes else {
                throw ModelProviderError(kind: .notConfigured, provider: id, message: "Perry’s tool helper is missing from this build, so \(displayName) can’t use Perry’s tools.")
            }
            let bridge = AgentTurnBridge(tools: request.tools, execute: executeTool, stop: stop)
            let opened = try scopes.openScope(bridge)
            scope = opened
            wireNames = Set(bridge.wireNames.keys)
            mcpServers = [Self.perryServer(helper: helper, scope: opened)]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let connection = JSONRPCConnection(readHandle: output.fileHandleForReading, writeHandle: input.fileHandleForWriting, stampsVersion: true)
        let events = await connection.events
        await connection.start()
        stop.onStop = { [weak process] in process?.terminate() }

        let listener = Task {
            for await event in events {
                switch event {
                case .notification(let note) where note.method == "session/update":
                    if let text = Self.messageText(note.params) { continuation.yield(.textDelta(text)) }
                case .incomingRequest(let incoming):
                    await Self.answer(incoming, on: connection, perryTools: wireNames)
                default:
                    break
                }
            }
        }
        defer { listener.cancel() }

        do {
            let initialized = try await connection.request("initialize", params: .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                    "terminal": .bool(false),
                ]),
            ]))
            let acceptsImages = initialized["agentCapabilities"]?["promptCapabilities"]?["image"]?.boolValue == true
            let session = try await connection.request("session/new", params: .object([
                "cwd": .string(workspace.path),
                "mcpServers": .array(mcpServers),
            ]))
            guard let sessionID = session["sessionId"]?.stringValue else {
                throw ModelProviderError(kind: .malformed, provider: id, message: "\(displayName) did not start a session.")
            }
            if let mode = Self.readOnlyMode(session) {
                _ = try await connection.request("session/set_mode", params: .object([
                    "sessionId": .string(sessionID), "modeId": .string(mode),
                ]))
            }
            let result = try await withTaskCancellationHandler {
                try await connection.request("session/prompt", params: .object([
                    "sessionId": .string(sessionID),
                    "prompt": .array(Self.prompt(request.messages, images: acceptsImages)),
                ]))
            } onCancel: {
                Task { try? await connection.notify("session/cancel", params: .object(["sessionId": .string(sessionID)])) }
            }
            if let reason = stop.reason { throw reason }
            continuation.yield(.done(result["stopReason"]?.stringValue == "max_tokens" ? .maxTokens : .endTurn))
        } catch {
            if let reason = stop.reason { throw reason }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let rpc = error as? JSONRPCError {
                let kind: ModelProviderError.Kind = rpc.message.lowercased().contains("auth") ? .unauthenticated : .unavailable
                throw ModelProviderError(kind: kind, provider: id, message: "\(displayName) stopped: \(rpc.message)")
            }
            throw error
        }
        await connection.close()
    }

    static func perryServer(helper: URL, scope: MCPScope) -> JSONValue {
        .object([
            "name": .string("perry"),
            "command": .string(helper.path),
            "args": .array([]),
            "env": .array([
                .object(["name": .string("PERRY_MCP_SOCKET"), "value": .string(scope.socketPath)]),
                .object(["name": .string("PERRY_MCP_TOKEN"), "value": .string(scope.token)]),
            ]),
        ])
    }

    static func readOnlyMode(_ session: JSONValue) -> String? {
        let modes = session["modes"]?["availableModes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        return ["ask", "plan", "read-only"].first { modes.contains($0) }
    }

    static func messageText(_ params: JSONValue) -> String? {
        guard let update = params["update"], update["sessionUpdate"]?.stringValue == "agent_message_chunk",
              update["content"]?["type"]?.stringValue == "text" else { return nil }
        return update["content"]?["text"]?.stringValue
    }

    static func permissionOutcome(_ params: JSONValue, perryTools: Set<String>) -> JSONValue {
        let title = (params["toolCall"]?["title"]?.stringValue ?? "").lowercased()
        let isPerry = title.contains("perry") && perryTools.contains { title.contains($0.lowercased()) }
        let options = params["options"]?.arrayValue ?? []
        let wanted = isPerry ? "allow_once" : "reject_once"
        guard let option = options.first(where: { $0["kind"]?.stringValue == wanted })?["optionId"] else {
            return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": option])])
    }

    private static func answer(_ incoming: JSONRPCIncomingRequest, on connection: JSONRPCConnection, perryTools: Set<String>) async {
        if incoming.method == "session/request_permission" {
            try? await connection.respond(to: incoming.id, result: permissionOutcome(incoming.params, perryTools: perryTools))
        } else {
            try? await connection.respondError(to: incoming.id, code: -32601, message: "Perry does not offer \(incoming.method).")
        }
    }

    static func prompt(_ messages: [ModelMessage], images: Bool) -> [JSONValue] {
        let turn = AgentTurnPrompt(messages)
        var blocks: [JSONValue] = turn.latest.compactMap { part in
            switch part {
            case .text(let text):
                .object(["type": .string("text"), "text": .string(text)])
            case .image(let data, let mimeType):
                images ? .object(["type": .string("image"), "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())]) : nil
            }
        }
        if let earlier = turn.earlier {
            blocks.insert(.object(["type": .string("text"), "text": .string(earlier)]), at: 0)
        }
        return blocks
    }
}
