import Foundation

public struct ToolCallResult: Sendable {
    public var content: [ModelContentPart]
    public var isError: Bool

    public init(content: [ModelContentPart], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.content = [.text(text)]
        self.isError = isError
    }
}

public typealias ToolCallHandler = @Sendable (ToolCall) async -> ToolCallResult

public final class CodexAppServerProvider: ModelProvider, @unchecked Sendable {
    public let id: ProviderID = .codex
    public let displayName = "ChatGPT (Codex)"
    public let capabilities: ModelCapabilities
    public let account: CodexAccount

    private let process: CodexAppServerProcess
    private let toolHandler: ToolCallHandler?
    private let modelOverride: String?
    private let supportsDynamicTools: Bool
    private let lock = NSLock()
    private var monitorTask: Task<Void, Never>?
    private var monitoredConnection: JSONRPCConnection?
    private var turns: [String: TurnContext] = [:]

    private final class TurnContext: @unchecked Sendable {
        var turnID: String?
        let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
        var imageFiles: [URL] = []

        init(continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) {
            self.continuation = continuation
        }

        func cleanup() {
            for file in imageFiles { try? FileManager.default.removeItem(at: file) }
            imageFiles = []
        }
    }

    public init(
        process: CodexAppServerProcess,
        toolHandler: ToolCallHandler? = nil,
        modelOverride: String? = nil,
        supportsDynamicTools: Bool = true
    ) {
        self.process = process
        self.toolHandler = toolHandler
        self.modelOverride = modelOverride
        self.supportsDynamicTools = supportsDynamicTools
        self.account = CodexAccount(process: process)
        var capabilities: ModelCapabilities = [.vision, .streaming]
        if supportsDynamicTools { capabilities.insert(.tools) }
        self.capabilities = capabilities
    }

    public func warm() async {
        guard let connection = try? await process.connection() else { return }
        await monitor(connection)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let box = TurnIdentityBox()
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.run(request, box: box, into: continuation)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] termination in
                task.cancel()
                guard let self else { return }
                if case .cancelled = termination {
                    Task { await self.interruptTurn(box) }
                }
                self.finishTurn(box: box)
            }
        }
    }

    private final class TurnIdentityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _threadID: String?
        private var _turnID: String?

        var threadID: String? { lock.withLock { _threadID } }
        var turnID: String? { lock.withLock { _turnID } }
        func set(threadID: String) { lock.withLock { _threadID = threadID } }
        func set(turnID: String) { lock.withLock { _turnID = turnID } }
    }

    private func run(_ request: ModelRequest, box: TurnIdentityBox, into continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) async throws {
        let connection = try await process.connection()
        await monitor(connection)

        var threadParams: [String: JSONValue] = [
            "ephemeral": .bool(true),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "cwd": .string(await process.workingDirectoryPath()),
        ]
        if !request.system.isEmpty {
            threadParams["developerInstructions"] = .string(request.system)
        }
        if let modelOverride {
            threadParams["model"] = .string(modelOverride)
        }
        if supportsDynamicTools, !request.tools.isEmpty {
            threadParams["dynamicTools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                ])
            })
        }

        let context = TurnContext(continuation: continuation)
        var input: [JSONValue] = []
        for message in request.messages {
            switch message {
            case .user(let parts):
                for part in parts {
                    switch part {
                    case .text(let text):
                        input.append(.object(["type": .string("text"), "text": .string(text)]))
                    case .image(let data, _):
                        let file = try Self.writeImage(data)
                        context.imageFiles.append(file)
                        input.append(.object(["type": .string("localImage"), "path": .string(file.path)]))
                    }
                }
            case .assistant(let text, _):
                if !text.isEmpty {
                    input.append(.object(["type": .string("text"), "text": .string("Assistant: \(text)")]))
                }
            case .toolResult(let callID, let content, _):
                let text = content.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined(separator: "\n")
                if !text.isEmpty {
                    input.append(.object(["type": .string("text"), "text": .string("Tool result (\(callID)): \(text)")]))
                }
            }
        }

        let threadResult = try await connection.request("thread/start", params: .object(threadParams))
        guard let threadID = threadResult["thread"]?["id"]?.stringValue else {
            context.cleanup()
            throw ModelProviderError(kind: .malformed, provider: id, message: "thread/start returned no thread id")
        }
        box.set(threadID: threadID)
        lock.withLock { turns[threadID] = context }

        var turnParams: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object(["type": .string("readOnly")]),
        ]
        if let modelOverride {
            turnParams["model"] = .string(modelOverride)
        }
        if request.tier == .fast {
            turnParams["effort"] = .string("low")
        }
        let turnResult = try await connection.request("turn/start", params: .object(turnParams))
        guard let turnID = turnResult["turn"]?["id"]?.stringValue else {
            throw ModelProviderError(kind: .malformed, provider: id, message: "turn/start returned no turn id")
        }
        box.set(turnID: turnID)
        lock.withLock { turns[threadID]?.turnID = turnID }
    }

    private func finishTurn(box: TurnIdentityBox) {
        guard let threadID = box.threadID else { return }
        let context = lock.withLock { turns.removeValue(forKey: threadID) }
        context?.cleanup()
    }

    private func interruptTurn(_ box: TurnIdentityBox) async {
        guard let threadID = box.threadID, let turnID = box.turnID,
              let connection = monitoredConnection else { return }
        _ = try? await connection.request("turn/interrupt", params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
        ]))
    }

    /// Subscribes before returning so no notification sent after the next request can be missed.
    private func monitor(_ connection: JSONRPCConnection) async {
        if lock.withLock({ monitoredConnection === connection && monitorTask != nil }) { return }
        let events = await connection.events
        lock.withLock {
            guard monitoredConnection !== connection else { return }
            monitorTask?.cancel()
            monitoredConnection = connection
            monitorTask = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
                guard let self else { return }
                self.lock.withLock {
                    if self.monitoredConnection === connection {
                        self.monitorTask = nil
                        self.monitoredConnection = nil
                    }
                }
            }
        }
    }

    private func handle(_ event: JSONRPCEvent) async {
        switch event {
        case .notification(let note):
            await handleNotification(note)
        case .incomingRequest(let request):
            await handleServerRequest(request)
        case .closed:
            failAllTurns()
        }
    }

    private func context(for threadID: String) -> TurnContext? {
        lock.withLock { turns[threadID] }
    }

    private func handleNotification(_ note: JSONRPCNotification) async {
        guard let threadID = note.params["threadId"]?.stringValue else { return }
        switch note.method {
        case "item/agentMessage/delta":
            if let delta = note.params["delta"]?.stringValue {
                context(for: threadID)?.continuation.yield(.textDelta(delta))
            }
        case "thread/tokenUsage/updated":
            if let last = note.params["tokenUsage"]?["last"]?.objectValue,
               let input = last["inputTokens"]?.doubleValue,
               let output = last["outputTokens"]?.doubleValue {
                context(for: threadID)?.continuation.yield(.usage(inputTokens: Int(input), outputTokens: Int(output)))
            }
        case "turn/completed":
            guard let turn = note.params["turn"]?.objectValue,
                  let context = context(for: threadID) else { return }
            switch turn["status"]?.stringValue ?? "completed" {
            case "completed":
                context.continuation.yield(.done(.endTurn))
                context.continuation.finish()
            case "interrupted":
                context.continuation.yield(.done(.cancelled))
                context.continuation.finish()
            case "failed":
                let message = turn["error"]?["message"]?.stringValue ?? "turn failed"
                context.continuation.finish(throwing: ModelProviderError(kind: .unavailable, provider: id, message: message))
            default:
                break
            }
        case "error":
            let willRetry = note.params["willRetry"]?.boolValue ?? false
            if !willRetry {
                let message = note.params["error"]?["message"]?.stringValue ?? "turn error"
                context(for: threadID)?.continuation.finish(throwing: ModelProviderError(kind: .unavailable, provider: id, message: message))
            }
        default:
            break
        }
    }

    private func handleServerRequest(_ request: JSONRPCIncomingRequest) async {
        switch request.method {
        case "item/tool/call":
            await handleToolCall(request)
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            _ = try? await respond(request, result: .object(["decision": .string("decline")]))
        case "execCommandApproval", "applyPatchApproval":
            _ = try? await respond(request, result: .object(["decision": .string("denied")]))
        case "item/permissions/requestApproval":
            _ = try? await respondError(request, message: "Perry auto-denies permission escalation")
        case "item/tool/requestUserInput":
            _ = try? await respond(request, result: .object(["answers": .object([:])]))
        case "mcpServer/elicitation/request":
            _ = try? await respond(request, result: .object(["action": .string("decline")]))
        case "account/chatgptAuthTokens/refresh", "attestation/generate":
            _ = try? await respondError(request, message: "not supported by Perry")
        default:
            _ = try? await respondError(request, message: "unsupported request \(request.method)")
        }
    }

    private func handleToolCall(_ request: JSONRPCIncomingRequest) async {
        guard let threadID = request.params["threadId"]?.stringValue,
              let name = request.params["tool"]?.stringValue,
              let callID = request.params["callId"]?.stringValue else {
            _ = try? await respondError(request, message: "malformed tool call")
            return
        }
        let call = ToolCall(id: callID, name: name, arguments: request.params["arguments"] ?? .object([:]))
        context(for: threadID)?.continuation.yield(.toolCall(call))
        let result: ToolCallResult
        if let toolHandler {
            result = await toolHandler(call)
        } else {
            result = ToolCallResult(text: "Perry tool host is not configured", isError: true)
        }
        let items: [JSONValue] = result.content.map { part in
            switch part {
            case .text(let text):
                return .object(["type": .string("inputText"), "text": .string(text)])
            case .image(let data, let mimeType):
                return .object([
                    "type": .string("inputImage"),
                    "imageUrl": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
                ])
            }
        }
        _ = try? await respond(request, result: .object([
            "contentItems": .array(items),
            "success": .bool(!result.isError),
        ]))
    }

    private func respond(_ request: JSONRPCIncomingRequest, result: JSONValue) async throws {
        guard let connection = monitoredConnection else { return }
        try await connection.respond(to: request.id, result: result)
    }

    private func respondError(_ request: JSONRPCIncomingRequest, message: String) async throws {
        guard let connection = monitoredConnection else { return }
        try await connection.respondError(to: request.id, message: message)
    }

    private func failAllTurns() {
        let stranded = lock.withLock { () -> [String: TurnContext] in
            let stranded = turns
            turns.removeAll()
            return stranded
        }
        for (_, context) in stranded {
            context.cleanup()
            context.continuation.finish(throwing: ModelProviderError(kind: .unavailable, provider: id, message: "codex app-server exited mid-turn"))
        }
    }

    private static func writeImage(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-brain", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".img")
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }
}
