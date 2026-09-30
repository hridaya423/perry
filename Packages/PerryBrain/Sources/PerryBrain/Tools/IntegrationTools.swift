import Foundation
import PerryCore

/// One callable operation on a connected service (e.g. "search pages").
public struct IntegrationOperation: Sendable, Equatable {
    public var name: String
    public var description: String
    /// True when the operation changes remote state.
    public var isWrite: Bool
    /// JSON-schema object validated against the call's `arguments` field.
    public var inputSchema: JSONValue

    public init(name: String, description: String, isWrite: Bool, inputSchema: JSONValue = .object(["type": .string("object")])) {
        self.name = name
        self.description = description
        self.isWrite = isWrite
        self.inputSchema = inputSchema
    }
}

public struct IntegrationService: Sendable, Equatable {
    public var id: String
    public var name: String
    /// False when the OAuth grant is missing or expired — reads should fail
    /// with a reconnect message rather than guessing.
    public var connected: Bool
    /// Remote writes stay off until the user enables them per service.
    public var writeEnabled: Bool
    public var operations: [IntegrationOperation]

    public init(id: String, name: String, connected: Bool, writeEnabled: Bool, operations: [IntegrationOperation]) {
        self.id = id
        self.name = name
        self.connected = connected
        self.writeEnabled = writeEnabled
        self.operations = operations
    }
}

/// What the app wires in over `RemoteIntegrations`. Reads/writes are split
/// into separate tools so the trust tier is decided by the spec, not the call.
public protocol IntegrationBackend: Sendable {
    func services() async throws -> [IntegrationService]
    func perform(service: String, operation: String, arguments: JSONValue) async throws -> JSONValue
}

/// `integrations.*` executors.
public enum IntegrationToolExecutors {
    public static func make(backend: any IntegrationBackend) -> [any ToolExecutor] {
        [ListTool(backend: backend), ReadTool(backend: backend), WriteTool(backend: backend)]
    }

    // `arguments` is declared without a type so the host's strict validator
    // passes it through; the executor validates it against the operation's
    // own inputSchema instead.
    private static let callSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "service": .object(["type": .string("string")]),
            "operation": .object(["type": .string("string")]),
            "arguments": .object(["description": .string("operation-specific arguments")]),
        ]),
        "required": .array([.string("service"), .string("operation")]),
    ])

    private static func resolve(
        _ call: ToolCall, backend: any IntegrationBackend, wantWrite: Bool
    ) async throws -> (IntegrationService, IntegrationOperation, JSONValue) {
        guard let serviceID = call.arguments["service"]?.stringValue,
              let opName = call.arguments["operation"]?.stringValue else {
            throw WorkspaceFileError("missing service or operation")
        }
        let services = try await backend.services()
        guard let service = services.first(where: { $0.id == serviceID || $0.name == serviceID }) else {
            let known = services.map(\.id).joined(separator: ", ")
            throw WorkspaceFileError("unknown service \"\(serviceID)\" (connected: \(known.isEmpty ? "none" : known))")
        }
        guard service.connected else {
            throw WorkspaceFileError("\(service.name) is not connected — reconnect it in Home > Apps")
        }
        guard let operation = service.operations.first(where: { $0.name == opName }) else {
            let known = service.operations.map(\.name).joined(separator: ", ")
            throw WorkspaceFileError("unknown operation \"\(opName)\" on \(service.id) (has: \(known))")
        }
        if wantWrite {
            guard operation.isWrite else {
                throw WorkspaceFileError("\(opName) is read-only — use integrations.read")
            }
            guard service.writeEnabled else {
                throw WorkspaceFileError("remote writes are off for \(service.name) — enable them in Home > Apps")
            }
        } else {
            guard !operation.isWrite else {
                throw WorkspaceFileError("\(opName) changes remote state — use integrations.write")
            }
        }
        let arguments = call.arguments["arguments"] ?? .object([:])
        if let detail = PerryToolHost.validate(arguments, against: operation.inputSchema) {
            throw WorkspaceFileError("invalid operation arguments — \(detail)")
        }
        return (service, operation, arguments)
    }

    private struct ListTool: ToolExecutor {
        let backend: any IntegrationBackend
        let spec = ToolSpec(
            name: "integrations.list",
            description: "List connected services and their operations.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            surfaces: [.agent, .suggestions], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let services = try await backend.services().filter(\.connected)
            let value: JSONValue = .object(["services": .array(services.map { service in
                .object([
                    "id": .string(service.id),
                    "name": .string(service.name),
                    "connected": .bool(service.connected),
                    "writeEnabled": .bool(service.writeEnabled),
                    "operations": .array(service.operations.map { op in
                        .object([
                            "name": .string(op.name),
                            "description": .string(op.description),
                            "isWrite": .bool(op.isWrite),
                        ])
                    }),
                ])
            })])
            return .text(call.id, String(data: (try? value.data()) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }

    private struct ReadTool: ToolExecutor {
        let backend: any IntegrationBackend
        let spec = ToolSpec(
            name: "integrations.read",
            description: "Run a read-only operation on a connected service.",
            inputSchema: IntegrationToolExecutors.callSchema,
            surfaces: [.agent, .suggestions], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let (service, operation, arguments) = try await IntegrationToolExecutors.resolve(
                call, backend: backend, wantWrite: false
            )
            let value = try await backend.perform(service: service.id, operation: operation.name, arguments: arguments)
            return .text(call.id, String(data: (try? value.data()) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }

    private struct WriteTool: ToolExecutor {
        let backend: any IntegrationBackend
        let spec = ToolSpec(
            name: "integrations.write",
            description: "Run an operation that changes a connected service. Requires approval.",
            inputSchema: IntegrationToolExecutors.callSchema,
            tier: .orange, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let (service, operation, arguments) = try await IntegrationToolExecutors.resolve(
                call, backend: backend, wantWrite: true
            )
            let value = try await backend.perform(service: service.id, operation: operation.name, arguments: arguments)
            return .text(call.id, String(data: (try? value.data()) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }
}
