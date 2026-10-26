import Foundation

public final class RedactionVaults: @unchecked Sendable {
    private let lock = NSLock()
    private let knownNames: @Sendable () -> [String]
    private var vaults: [String: Redactor] = [:]

    public init(knownNames: @escaping @Sendable () -> [String]) {
        self.knownNames = knownNames
    }

    public func redactor(for conversationKey: String?) -> Redactor {
        guard let conversationKey else { return Redactor(knownNames: knownNames()) }
        return lock.withLock {
            if let existing = vaults[conversationKey] { return existing }
            let redactor = Redactor(knownNames: knownNames())
            vaults[conversationKey] = redactor
            return redactor
        }
    }
}

public struct RedactingProvider: ModelProvider {
    let base: any ModelProvider
    let vaults: RedactionVaults

    public static func wrap(_ base: any ModelProvider, vaults: RedactionVaults) -> any ModelProvider {
        if let native = base as? any ToolExecutingModelProvider {
            return RedactingToolProvider(native: native, vaults: vaults)
        }
        return RedactingProvider(base: base, vaults: vaults)
    }

    public var id: ProviderID { base.id }
    public var displayName: String { base.displayName }
    public var capabilities: ModelCapabilities { base.capabilities }
    public func warm() async { await base.warm() }
    public func contextWindow(for tier: ModelTier) async throws -> Int? {
        try await base.contextWindow(for: tier)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let redactor = vaults.redactor(for: request.conversationKey)
        return Self.restoring(base.stream(Self.redacted(request, with: redactor)), with: redactor)
    }

    static func redacted(_ request: ModelRequest, with redactor: Redactor) -> ModelRequest {
        var request = request
        request.system = [redactor.redact(request.system), PersonalDetails.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        request.messages = request.messages.map { message in
            switch message {
            case .user(let parts):
                .user(parts.map { redact($0, with: redactor) })
            case .assistant(let text, let calls):
                .assistant(text: redactor.redact(text), toolCalls: calls.map { ToolCall(id: $0.id, name: $0.name, arguments: redactor.redact($0.arguments)) })
            case .toolResult(let id, let parts, let isError):
                .toolResult(callID: id, content: parts.map { redact($0, with: redactor) }, isError: isError)
            }
        }
        return request
    }

    static func redact(_ part: ModelContentPart, with redactor: Redactor) -> ModelContentPart {
        guard case .text(let text) = part else { return part }
        return .text(redactor.redact(text))
    }

    static func restoring(_ events: AsyncThrowingStream<ModelEvent, Error>, with redactor: Redactor) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var text = RestoringText(redactor: redactor)
                do {
                    for try await event in events {
                        switch event {
                        case .textDelta(let chunk):
                            let ready = text.feed(chunk)
                            if !ready.isEmpty { continuation.yield(.textDelta(ready)) }
                        case .toolCall(let call):
                            let held = text.flush()
                            if !held.isEmpty { continuation.yield(.textDelta(held)) }
                            continuation.yield(.toolCall(ToolCall(id: call.id, name: call.name, arguments: redactor.restore(call.arguments))))
                        default:
                            let held = text.flush()
                            if !held.isEmpty { continuation.yield(.textDelta(held)) }
                            continuation.yield(event)
                        }
                    }
                    let held = text.flush()
                    if !held.isEmpty { continuation.yield(.textDelta(held)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension RouteDecision {
    public func hidingPersonalDetails(with vaults: RedactionVaults) -> RouteDecision {
        guard !provider.capabilities.contains(.local), provider.id != .apple else { return self }
        return RouteDecision(provider: RedactingProvider.wrap(provider, vaults: vaults), explanation: explanation)
    }
}

struct RedactingToolProvider: ToolExecutingModelProvider {
    let native: any ToolExecutingModelProvider
    let vaults: RedactionVaults

    var id: ProviderID { native.id }
    var displayName: String { native.displayName }
    var capabilities: ModelCapabilities { native.capabilities }
    func warm() async { await native.warm() }
    func contextWindow(for tier: ModelTier) async throws -> Int? {
        try await native.contextWindow(for: tier)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        RedactingProvider(base: native, vaults: vaults).stream(request)
    }

    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        let redactor = vaults.redactor(for: request.conversationKey)
        let events = native.stream(RedactingProvider.redacted(request, with: redactor)) { call in
            var result = try await executeTool(ToolCall(id: call.id, name: call.name, arguments: redactor.restore(call.arguments)))
            result.content = result.content.map { RedactingProvider.redact($0, with: redactor) }
            return result
        }
        return RedactingProvider.restoring(events, with: redactor)
    }
}
