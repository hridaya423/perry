import Foundation

struct AgentTurnPrompt {
    let earlier: String?
    let latest: [ModelContentPart]

    init(_ messages: [ModelMessage]) {
        let lastUser = messages.lastIndex { if case .user = $0 { return true } else { return false } }
        var transcript: [String] = []
        var latest: [ModelContentPart] = []
        for (index, message) in messages.enumerated() {
            switch message {
            case .user(let parts) where index == lastUser:
                latest = parts
            case .user(let parts):
                let text = parts.joinedText
                if !text.isEmpty { transcript.append("User: \(text)") }
            case .assistant(let text, _):
                if !text.isEmpty { transcript.append("You: \(text)") }
            case .toolResult:
                break
            }
        }
        self.earlier = transcript.isEmpty ? nil : "Earlier in this conversation:\n" + transcript.joined(separator: "\n")
        self.latest = latest
    }
}

final class AgentTurnStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var onStop: (@Sendable () -> Void)?

    var reason: Error? { lock.withLock { stored } }

    func stop(_ error: Error) {
        let first = lock.withLock {
            guard stored == nil else { return false }
            stored = error
            return true
        }
        if first { onStop?() }
    }
}

struct AgentTurnBridge: MCPBridge {
    let specs: [ToolSpec]
    let wireNames: [String: String]
    let execute: ToolExecutionHandler
    let stop: AgentTurnStop
    let dropsImages: Bool

    init(tools: [ToolSpec], execute: @escaping ToolExecutionHandler, stop: AgentTurnStop, dropsImages: Bool = false) {
        self.dropsImages = dropsImages
        var names: [String: String] = [:]
        var specs: [ToolSpec] = []
        for tool in tools {
            let wire = tool.name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            guard names[wire] == nil else { continue }
            names[wire] = tool.name
            specs.append(ToolSpec(
                name: wire, description: tool.description, inputSchema: tool.inputSchema, tier: tool.tier,
                surfaces: tool.surfaces, readOnly: tool.readOnly, requiredCapabilities: tool.requiredCapabilities
            ))
        }
        self.specs = specs
        self.wireNames = names
        self.execute = execute
        self.stop = stop
    }

    func tools() async throws -> [ToolSpec] { specs }

    func call(name: String, arguments: JSONValue) async throws -> ToolResult {
        guard let original = wireNames[name] else {
            return ToolResult(callID: UUID().uuidString, content: [.text("Unknown tool \(name).")], isError: true)
        }
        do {
            var result = try await execute(ToolCall(id: UUID().uuidString, name: original, arguments: arguments))
            if dropsImages {
                result.content = result.content.map { part in
                    if case .image = part { return .text("[A screenshot was here. This agent can’t read images.]") }
                    return part
                }
            }
            return result
        } catch {
            stop.stop(error)
            throw error
        }
    }
}
