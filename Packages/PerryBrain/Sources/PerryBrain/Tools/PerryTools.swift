import Foundation

/// `perry.*` executors over `PerryStore`. `perry.settings.open` needs a UI
/// handler injected by the app (Home's Settings pages).
public enum PerryToolExecutors {
    /// `openSettings` receives the requested Home settings page identifier,
    /// or nil for the default page. When nil the tool reports unavailable.
    public static func make(
        store: PerryStore,
        openSettings: (@Sendable (String?) async -> Void)? = nil
    ) -> [any ToolExecutor] {
        [
            ListTool(store: store),
            CreateTool(store: store),
            ScheduleTool(store: store),
            SettingsOpenTool(openSettings: openSettings),
        ]
    }

    private static func json(_ call: ToolCall, _ object: [String: JSONValue]) -> ToolResult {
        let data = (try? JSONValue.object(object).data()) ?? Data()
        return .text(call.id, String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func find(_ store: PerryStore, _ idOrName: String) async throws -> Perry {
        let all = await store.list()
        if let match = all.first(where: { $0.id.uuidString == idOrName || $0.name == idOrName }) {
            return match
        }
        throw WorkspaceFileError("unknown Perry \"\(idOrName)\" (have: \(all.map(\.name).joined(separator: ", ")))")
    }

    private struct ListTool: ToolExecutor {
        let store: PerryStore
        let spec = ToolSpec(
            name: "perry.list",
            description: "List the user's named Perrys (persistent agents).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            surfaces: [.agent], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let perrys = await store.list()
            return PerryToolExecutors.json(call, [
                "perrys": .array(perrys.map { perry in
                    .object([
                        "id": .string(perry.id.uuidString),
                        "name": .string(perry.name),
                        "job": .string(perry.job),
                        "hasSchedule": .bool(perry.schedule != nil),
                    ])
                }),
            ])
        }
    }

    private struct CreateTool: ToolExecutor {
        let store: PerryStore
        let spec = ToolSpec(
            name: "perry.createPerry",
            description: "Create a named persistent Perry with a job. Use perry.schedule to add a routine.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "job": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "folderPath": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("job")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            guard let job = call.arguments["job"]?.stringValue, !job.isEmpty else {
                throw WorkspaceFileError("missing job")
            }
            let perry = try await store.create(
                job: job,
                name: call.arguments["name"]?.stringValue,
                folderPath: call.arguments["folderPath"]?.stringValue
            )
            return PerryToolExecutors.json(call, [
                "id": .string(perry.id.uuidString),
                "name": .string(perry.name),
                "threadID": .string(perry.threadID),
            ])
        }
    }

    private struct ScheduleTool: ToolExecutor {
        let store: PerryStore
        let spec = ToolSpec(
            name: "perry.schedule",
            description: "Set or clear a Perry's routine schedule.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "perry": .object(["type": .string("string")]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("daily"), .string("interval"), .string("once"), .string("off")]),
                    ]),
                    "hour": .object(["type": .string("integer")]),
                    "minute": .object(["type": .string("integer")]),
                    "seconds": .object(["type": .string("number")]),
                    "at": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("perry"), .string("kind")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            guard let idOrName = call.arguments["perry"]?.stringValue,
                  let kind = call.arguments["kind"]?.stringValue else {
                throw WorkspaceFileError("missing perry or kind")
            }
            var perry = try await PerryToolExecutors.find(store, idOrName)
            switch kind {
            case "daily":
                guard let hour = call.arguments["hour"]?.doubleValue.map(Int.init), (0...23).contains(hour) else {
                    throw WorkspaceFileError("daily schedule needs hour 0-23")
                }
                let minute = call.arguments["minute"]?.doubleValue.map(Int.init) ?? 0
                guard (0...59).contains(minute) else {
                    throw WorkspaceFileError("daily schedule needs minute 0-59")
                }
                perry.schedule = RoutineSchedule(kind: .daily(hour: hour, minute: minute))
            case "interval":
                guard let seconds = call.arguments["seconds"]?.doubleValue, seconds > 0 else {
                    throw WorkspaceFileError("interval schedule needs positive seconds")
                }
                perry.schedule = RoutineSchedule(kind: .interval(seconds))
            case "once":
                guard let raw = call.arguments["at"]?.stringValue,
                      let at = ISO8601DateFormatter().date(from: raw) else {
                    throw WorkspaceFileError("once schedule needs ISO-8601 \"at\"")
                }
                perry.schedule = RoutineSchedule(kind: .once(at))
            case "off":
                perry.schedule = nil
            default:
                throw WorkspaceFileError("unknown kind: \(kind)")
            }
            try await store.update(perry)
            return PerryToolExecutors.json(call, [
                "id": .string(perry.id.uuidString), "kind": .string(kind),
            ])
        }
    }

    private struct SettingsOpenTool: ToolExecutor {
        let openSettings: (@Sendable (String?) async -> Void)?
        let spec = ToolSpec(
            name: "perry.settings.open",
            description: "Open Perry's Settings page in Home.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "page": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("brain"), .string("voice"), .string("shortcuts"),
                            .string("apps"), .string("memory"), .string("perrys"), .string("about"),
                        ]),
                    ]),
                ]),
            ]),
            surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            guard let openSettings else {
                throw WorkspaceFileError("settings are not available")
            }
            await openSettings(call.arguments["page"]?.stringValue)
            return .text(call.id, "{\"opened\":true}")
        }
    }
}
