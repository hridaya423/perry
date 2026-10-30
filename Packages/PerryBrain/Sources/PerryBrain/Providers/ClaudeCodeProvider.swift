import Foundation

public final class ClaudeCodeProvider: ModelProvider, @unchecked Sendable {
    public var executesTools: Bool { true }

    public let id: ProviderID = .claudeCode
    public let displayName = "Claude Code"
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming]

    private let executable: URL
    private let helper: URL?
    private let scopes: (any MCPScopeHost)?
    private let models: @Sendable () -> BrainModelDefaults

    public init(executable: URL, helper: URL?, scopes: (any MCPScopeHost)?, models: @escaping @Sendable () -> BrainModelDefaults = { BrainModelCatalog.claudeCode }) {
        self.executable = executable
        self.helper = helper
        self.scopes = scopes
        self.models = models
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
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("perry-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stop = AgentTurnStop()
        var arguments = Self.baseArguments(system: request.system, model: models().model(for: request.tier), effort: Self.effort(for: request.tier))
        var scope: MCPScope?
        defer { scope?.close() }
        if let executeTool, !request.tools.isEmpty {
            guard let helper, let scopes else {
                throw ModelProviderError(kind: .notConfigured, provider: id, message: "Perry’s tool helper is missing from this build, so Claude Code can’t use Perry’s tools.")
            }
            let bridge = AgentTurnBridge(tools: request.tools, execute: executeTool, stop: stop)
            let opened = try scopes.openScope(bridge)
            scope = opened
            arguments += Self.toolArguments(helper: helper, scope: opened, wireNames: bridge.wireNames)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let stderr = StderrTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderr.append(chunk) }
        }
        let (exits, exited) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.finish() }
        stop.onStop = { [weak process] in process?.terminate() }

        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let message = try Self.inputLine(for: request.messages)
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: message)
        } catch {
            process.terminate()
            for await _ in exits {}
            throw ModelProviderError(kind: .unavailable, provider: id, message: Self.failureMessage(stderr: stderr.text, status: process.terminationStatus))
        }
        try? input.fileHandleForWriting.close()

        var finished = false
        do {
            try await withTaskCancellationHandler {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let event = Self.event(from: line, provider: id) else { continue }
                    switch event {
                    case .done(let reason):
                        finished = true
                        continuation.yield(.done(reason))
                    case .failure(let error):
                        throw error
                    case .model(let modelEvent):
                        continuation.yield(modelEvent)
                    }
                }
            } onCancel: {
                process.terminate()
            }
        } catch {
            process.terminate()
            throw stop.reason ?? error
        }
        for await _ in exits {}
        errors.fileHandleForReading.readabilityHandler = nil
        if let reason = stop.reason { throw reason }
        try Task.checkCancellation()
        guard finished else {
            throw ModelProviderError(kind: .unavailable, provider: id, message: Self.failureMessage(stderr: stderr.text, status: process.terminationStatus))
        }
    }

    /// Quick turns answer at low effort; deep work keeps medium.
    static func effort(for tier: ModelTier) -> String {
        tier == .fast ? "low" : "medium"
    }

    static func baseArguments(system: String, model: String?, effort: String? = nil) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--input-format", "stream-json",
            "--verbose", "--include-partial-messages",
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence", "--permission-mode", "dontAsk",
        ]
        if !system.isEmpty { arguments += ["--system-prompt", system] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        return arguments
    }

    static func toolArguments(helper: URL, scope: MCPScope, wireNames: [String: String]) -> [String] {
        let config: JSONValue = .object(["mcpServers": .object(["perry": .object([
            "command": .string(helper.path),
            "args": .array([]),
            "env": .object([
                "PERRY_MCP_SOCKET": .string(scope.socketPath),
                "PERRY_MCP_TOKEN": .string(scope.token),
            ]),
        ])])])
        let json = (try? config.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let allowed = wireNames.keys.sorted().map { "mcp__perry__\($0)" }.joined(separator: ",")
        return ["--mcp-config", json, "--allowedTools", allowed]
    }

    static func inputLine(for messages: [ModelMessage]) throws -> Data {
        let turn = AgentTurnPrompt(messages)
        var blocks = turn.latest.map(block)
        if let earlier = turn.earlier {
            blocks.insert(.object(["type": .string("text"), "text": .string(earlier)]), at: 0)
        }
        let line: JSONValue = .object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array(blocks)]),
        ])
        return try line.data() + Data("\n".utf8)
    }

    private static func block(_ part: ModelContentPart) -> JSONValue {
        switch part {
        case .text(let text):
            .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mimeType):
            .object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string(mimeType), "data": .string(data.base64EncodedString()),
            ])])
        }
    }

    enum StreamEvent {
        case model(ModelEvent)
        case done(ModelStopReason)
        case failure(Error)
    }

    static func event(from line: String, provider: ProviderID) -> StreamEvent? {
        guard let payload = try? JSONValue(parsing: Data(line.utf8)) else { return nil }
        switch payload["type"]?.stringValue {
        case "stream_event":
            guard payload["parent_tool_use_id"]?.stringValue == nil,
                  let event = payload["event"],
                  event["type"]?.stringValue == "content_block_delta",
                  event["delta"]?["type"]?.stringValue == "text_delta",
                  let text = event["delta"]?["text"]?.stringValue else { return nil }
            return .model(.textDelta(text))
        case "result":
            if payload["is_error"]?.boolValue == true || payload["subtype"]?.stringValue != "success" {
                let detail = payload["result"]?.stringValue ?? payload["subtype"]?.stringValue ?? "unknown error"
                let lowered = detail.lowercased()
                let kind: ModelProviderError.Kind = lowered.contains("login") || lowered.contains("auth") ? .unauthenticated : .unavailable
                return .failure(ModelProviderError(kind: kind, provider: provider, message: "Claude Code stopped: \(detail)"))
            }
            return .done(payload["stop_reason"]?.stringValue == "max_tokens" ? .maxTokens : .endTurn)
        default:
            return nil
        }
    }

    static func failureMessage(stderr: String, status: Int32) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "Claude Code exited (\(status)) without an answer." }
        return "Claude Code exited (\(status)): \(detail.suffix(400))"
    }

    private final class StderrTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.withLock {
                data.append(chunk)
                if data.count > 8192 { data = data.suffix(8192) }
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

}
