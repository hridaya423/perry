import Foundation

public enum MemoryToolExecutors {
    public static func make(files: MemoryFiles, pronunciations: PronunciationStore? = nil) -> [any ToolExecutor] {
        [ReadTool(files: files), WriteTool(files: files)] + (pronunciations.map { [PronunciationTool(store: $0)] } ?? [])
    }

    private static let sectionSchema: JSONValue = .object([
        "type": .string("string"),
        "enum": .array([.string("profile"), .string("context")]),
    ])

    private struct ReadTool: ToolExecutor {
        let files: MemoryFiles
        let spec = ToolSpec(
            name: "memory.read",
            description: "Read Perry's memory files (stable profile and current context).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["section": MemoryToolExecutors.sectionSchema]),
            ]),
            surfaces: [.agent], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            switch call.arguments["section"]?.stringValue {
            case "profile": return .text(call.id, files.profile())
            case "context": return .text(call.id, files.context())
            default:
                return .text(call.id, files.promptBlock())
            }
        }
    }

    private struct WriteTool: ToolExecutor {
        let files: MemoryFiles
        let spec = ToolSpec(
            name: "memory.write",
            description: "Update Perry's memory files (profile = stable preferences, context = current project).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "section": MemoryToolExecutors.sectionSchema,
                    "text": .object(["type": .string("string")]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("replace"), .string("append")]),
                    ]),
                ]),
                "required": .array([.string("section"), .string("text")]),
            ]),
            surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            guard let section = call.arguments["section"]?.stringValue,
                  let text = call.arguments["text"]?.stringValue else {
                throw WorkspaceFileError("missing section or text")
            }
            let append = call.arguments["mode"]?.stringValue == "append"
            switch section {
            case "profile":
                try files.writeProfile(append ? files.profile() + text : text)
            case "context":
                try files.writeContext(append ? files.context() + text : text)
            default:
                throw WorkspaceFileError("unknown section: \(section)")
            }
            return .text(call.id, "{\"updated\":\"\(section)\"}")
        }
    }

    private struct PronunciationTool: ToolExecutor {
        let store: PronunciationStore
        let spec = ToolSpec(
            name: "pronunciation.remember",
            description: "Save how to say a name or word when the user corrects you or explains it, e.g. \"it's pronounced Hrid-yah\". Use a simple respelling with hyphens between syllables.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "written": .object(["type": .string("string"), "description": .string("The word as it is spelled")]),
                    "spoken": .object(["type": .string("string"), "description": .string("A respelling that sounds right, e.g. Hrid-yah")]),
                ]),
                "required": .array([.string("written"), .string("spoken")]),
            ]),
            surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            guard let written = call.arguments["written"]?.stringValue, let spoken = call.arguments["spoken"]?.stringValue else {
                throw WorkspaceFileError("missing written or spoken")
            }
            try store.set(Pronunciation(written: written, spoken: spoken, source: .learned))
            return .text(call.id, "{\"saved\":\"\(written)\"}")
        }
    }
}
