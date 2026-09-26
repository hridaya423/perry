import Foundation

/// `memory.read` / `memory.write` over `MemoryFiles` (PROFILE.md/CONTEXT.md).
public enum MemoryToolExecutors {
    public static func make(files: MemoryFiles) -> [any ToolExecutor] {
        [ReadTool(files: files), WriteTool(files: files)]
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
            tier: .yellow, surfaces: [.agent]
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
}
