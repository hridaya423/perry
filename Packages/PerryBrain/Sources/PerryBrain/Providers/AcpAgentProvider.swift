import Foundation

public struct AcpAgent: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(id: String = UUID().uuidString, name: String, command: String, arguments: [String], environment: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decode([String].self, forKey: .arguments)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
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

public final class AcpAgentProvider: ModelProvider, @unchecked Sendable {
    public var executesTools: Bool { true }

    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming]

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let helper: URL?
    private let scopes: (any MCPScopeHost)?

    public init(agent: AcpAgent, executable: URL, helper: URL?, scopes: (any MCPScopeHost)?) {
        self.id = ProviderID(rawValue: "acp.\(agent.id)")
        self.displayName = agent.name
        self.executable = executable
        self.arguments = agent.arguments
        self.environment = agent.environment
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
        BrainHTTP.eventStream { try await self.execute(request, executeTool: executeTool, continuation: $0) }
    }

    private func execute(
        _ request: ModelRequest, executeTool: ToolExecutionHandler?,
        continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("perry-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stop = AgentTurnStop()
        let ledger = AcpToolCallLedger()
        var scope: MCPScope?
        defer { scope?.close() }
        if executeTool != nil, !request.tools.isEmpty, helper == nil || scopes == nil {
            throw ModelProviderError(kind: .notConfigured, provider: id, message: "Perry’s tool helper is missing from this build, so \(displayName) can’t use Perry’s tools.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        process.environment = Self.environment(adding: environment)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
                    ledger.record(note.params["update"])
                    if let text = Self.messageText(note.params) { continuation.yield(.textDelta(text)) }
                case .incomingRequest(let incoming):
                    await Self.answer(incoming, on: connection, ledger: ledger)
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
            if !acceptsImages, Self.hasImages(request.messages) {
                throw ModelProviderError(kind: .unavailable, provider: id, message: "\(displayName) can’t read screenshots. Choose a model that can see your screen in Settings, Models.")
            }
            var mcpServers: [JSONValue] = []
            let negotiated: ModelCapabilities = acceptsImages ? [.vision, .tools, .streaming] : [.tools, .streaming]
            let tools = request.tools.filter { $0.requiredCapabilities.isSubset(of: negotiated) }
            if let executeTool, let helper, let scopes, !tools.isEmpty {
                let bridge = AgentTurnBridge(tools: tools, execute: executeTool, stop: stop, dropsImages: !acceptsImages)
                let opened = try scopes.openScope(bridge)
                scope = opened
                ledger.allow(Set(bridge.wireNames.keys))
                mcpServers = [Self.perryServer(helper: helper, scope: opened)]
            }
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
                    "prompt": .array(Self.prompt(request.messages, system: request.system, images: acceptsImages)),
                ]))
            } onCancel: {
                Task { try? await connection.notify("session/cancel", params: .object(["sessionId": .string(sessionID)])) }
            }
            if let reason = stop.reason { throw reason }
            await connection.close()
            await listener.value
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
    }

    static func hasImages(_ messages: [ModelMessage]) -> Bool {
        messages.contains { message in
            guard case .user(let parts) = message else { return false }
            return parts.contains { if case .image = $0 { true } else { false } }
        }
    }

    static func environment(adding extra: [String: String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = base.merging(extra) { _, new in new }
        let path = (AcpAgent.searchPaths + [base["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        result["PATH"] = path
        return result
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

    static func permissionOutcome(_ params: JSONValue, ledger: AcpToolCallLedger) -> JSONValue {
        ledger.record(params["toolCall"])
        let options = params["options"]?.arrayValue ?? []
        let wanted = ledger.isPerryTool(params["toolCall"]?["toolCallId"]?.stringValue) ? "allow_once" : "reject_once"
        guard let option = options.first(where: { $0["kind"]?.stringValue == wanted })?["optionId"] else {
            return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": option])])
    }

    private static func answer(_ incoming: JSONRPCIncomingRequest, on connection: JSONRPCConnection, ledger: AcpToolCallLedger) async {
        if incoming.method == "session/request_permission" {
            try? await connection.respond(to: incoming.id, result: permissionOutcome(incoming.params, ledger: ledger))
        } else {
            try? await connection.respondError(to: incoming.id, code: -32601, message: "Perry does not offer \(incoming.method).")
        }
    }

    static func prompt(_ messages: [ModelMessage], system: String = "", images: Bool) -> [JSONValue] {
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
        if !system.isEmpty {
            blocks.insert(.object(["type": .string("text"), "text": .string("Instructions from Perry, the app you are working inside:\n" + system)]), at: 0)
        }
        return blocks
    }
}

final class AcpToolCallLedger: @unchecked Sendable {
    private struct Call {
        var kinds: Set<String> = []
        var titles: Set<String> = []
        var provider: String?
        var toolName: String?
        var metaToolName: String?
    }

    private let lock = NSLock()
    private var allowed: Set<String> = []
    private var calls: [String: Call] = [:]

    func allow(_ names: Set<String>) {
        lock.withLock { allowed = Set(names.map { $0.lowercased() }) }
    }

    func record(_ update: JSONValue?) {
        guard let update, let id = update["toolCallId"]?.stringValue else { return }
        lock.withLock {
            var call = calls[id] ?? Call()
            if let kind = update["kind"]?.stringValue { call.kinds.insert(kind) }
            if let title = update["title"]?.stringValue { call.titles.insert(title.lowercased().trimmingCharacters(in: .whitespaces)) }
            if let provider = update["rawInput"]?["providerIdentifier"]?.stringValue { call.provider = provider.lowercased() }
            if let tool = update["rawInput"]?["toolName"]?.stringValue { call.toolName = tool.lowercased() }
            if let tool = update["_meta"]?.objectValue?.first(where: { $0.key.hasSuffix("/toolName") })?.value.stringValue {
                call.metaToolName = tool.lowercased()
            }
            calls[id] = call
        }
    }

    func isPerryTool(_ id: String?) -> Bool {
        guard let id else { return false }
        return lock.withLock {
            guard let call = calls[id], call.kinds.isSubset(of: ["other"]) else { return false }
            if call.provider == "perry", let tool = call.toolName, allowed.contains(tool) { return true }
            if let tool = call.metaToolName, allowed.contains(where: { "mcp__perry__\($0)" == tool }) { return true }
            guard !call.titles.isEmpty else { return false }
            return call.titles.allSatisfy { title in
                allowed.contains { name in
                    ["perry: \(name)", "perry-\(name): \(name)", "mcp__perry__\(name)", "perry__\(name)", "perry/\(name)", "calling \(name) from perry"].contains(title)
                }
            }
        }
    }
}
