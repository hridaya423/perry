import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
public struct AppleFoundationModelProvider: ModelProvider {
    public let id: ProviderID = .apple
    public let displayName = "Apple Intelligence"
    public let capabilities: ModelCapabilities = [.local, .streaming]

    public init() {}

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func warm() async {
        _ = SystemLanguageModel.default.availability
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        BrainHTTP.eventStream { continuation in
                    guard Self.isAvailable else {
                        throw ModelProviderError(kind: .unavailable, provider: id, message: "Apple Intelligence is not available on this device")
                    }
                    var transcript = ""
                    var prompt = ""
                    for message in request.messages {
                        switch message {
                        case .user(let parts):
                            for part in parts {
                                if case .text(let text) = part { prompt += "User: \(text)\n" }
                            }
                        case .assistant(let text, _):
                            if !text.isEmpty { prompt += "Assistant: \(text)\n" }
                        case .toolResult(let callID, let content, _):
                            let text = content.compactMap { part -> String? in
                                if case .text(let t) = part { return t }
                                return nil
                            }.joined(separator: "\n")
                            prompt += "Tool result (\(callID)): \(text)\n"
                        }
                    }
                    let session = LanguageModelSession(instructions: request.system)
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        let content = snapshot.content
                        if content.count > transcript.count {
                            continuation.yield(.textDelta(String(content.dropFirst(transcript.count))))
                            transcript = content
                        }
                    }
                    continuation.yield(.done(.endTurn))
        }
    }
}
#else
public struct AppleFoundationModelProvider: ModelProvider {
    public let id: ProviderID = .apple
    public let displayName = "Apple Intelligence"
    public let capabilities: ModelCapabilities = [.local, .streaming]

    public init() {}

    public static var isAvailable: Bool { false }

    public func warm() async {}

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ModelProviderError(
                kind: .unavailable, provider: id,
                message: "FoundationModels is not available on this SDK"
            ))
        }
    }
}
#endif
