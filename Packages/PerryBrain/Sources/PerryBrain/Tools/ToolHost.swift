import Foundation
import OSLog
import PerryCore

public struct ToolResult: Sendable, Equatable {
    public var callID: String
    public var content: [ModelContentPart]
    public var isError: Bool

    public init(callID: String, content: [ModelContentPart], isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }

    public static func text(_ callID: String, _ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(callID: callID, content: [.text(text)], isError: isError)
    }
}

public struct ToolContext: Sendable {
    public var surface: ToolSurface
    public var threadID: String?
    /// Set by the UI only after the user typed the confirmation phrase for this call.
    public var redConfirmed: Bool
    /// App-injected approval for orange/red intent cards; nil means nobody is there to ask.
    public var approve: (@Sendable (ToolCall, ToolSpec) async -> Bool)?

    public init(
        surface: ToolSurface,
        threadID: String? = nil,
        redConfirmed: Bool = false,
        approve: (@Sendable (ToolCall, ToolSpec) async -> Bool)? = nil
    ) {
        self.surface = surface
        self.threadID = threadID
        self.redConfirmed = redConfirmed
        self.approve = approve
    }
}

public enum ToolHostError: Error, Sendable, Equatable, LocalizedError {
    case unknownTool(String)
    case surfaceDenied(name: String, surface: ToolSurface)
    case schemaViolation(name: String, detail: String)
    case confirmationRequired(name: String, tier: TrustTier)
    case approvalDenied(name: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "unknown tool: \(name)"
        case .surfaceDenied(let name, let surface): return "\(name) is not allowed on \(surface.rawValue)"
        case .schemaViolation(let name, let detail): return "\(name): invalid arguments — \(detail)"
        case .confirmationRequired(let name, let tier): return "\(name) needs \(tier.rawValue) confirmation"
        case .approvalDenied(let name): return "\(name) was not approved"
        }
    }
}

public protocol ToolExecutor: Sendable {
    var spec: ToolSpec { get }
    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult
}

/// The only path by which a model can touch the world. Registry of executors,
/// surface gating, schema validation, and tiered approval — in that order.
public final class PerryToolHost: Sendable {
    private let executors: [String: any ToolExecutor]
    private let specsByName: [String: ToolSpec]
    private let logger = Logger(subsystem: "ai.perry.brain", category: "tool-host")

    public init(executors: [any ToolExecutor]) {
        var byName: [String: any ToolExecutor] = [:]
        var specs: [String: ToolSpec] = [:]
        for executor in executors {
            byName[executor.spec.name] = executor
            specs[executor.spec.name] = executor.spec
        }
        self.executors = byName
        self.specsByName = specs
    }

    public func specs(for surface: ToolSurface) -> [ToolSpec] {
        specsByName.values
            .filter { $0.surfaces.contains(surface) && ToolGate.allows($0.name, on: surface) }
            .sorted { $0.name < $1.name }
    }

    public func handle(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        func fail(_ error: ToolHostError) -> ToolResult {
            .text(call.id, error.localizedDescription, isError: true)
        }
        guard let executor = executors[call.name], let spec = specsByName[call.name] else {
            return fail(.unknownTool(call.name))
        }
        if let rejection = ToolGate.check(call, on: context.surface) {
            return fail(.surfaceDenied(name: rejection.toolName, surface: rejection.surface))
        }
        guard spec.surfaces.contains(context.surface) else {
            return fail(.surfaceDenied(name: call.name, surface: context.surface))
        }
        if let detail = Self.validate(call.arguments, against: spec.inputSchema) {
            return fail(.schemaViolation(name: call.name, detail: detail))
        }
        switch spec.tier {
        case .green, .yellow:
            break
        case .orange:
            guard let approve = context.approve else {
                return fail(.confirmationRequired(name: call.name, tier: spec.tier))
            }
            guard await approve(call, spec) else { return fail(.approvalDenied(name: call.name)) }
        case .red:
            guard let approve = context.approve, context.redConfirmed else {
                return fail(.confirmationRequired(name: call.name, tier: spec.tier))
            }
            guard await approve(call, spec) else { return fail(.approvalDenied(name: call.name)) }
        }
        do {
            return try await executor.run(call, context: context)
        } catch {
            logger.warning("tool \(call.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .text(call.id, "\(call.name) failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// JSON-Schema subset validator. Returns a violation detail or nil.
    /// Strict by default: unknown keys and missing required keys are violations.
    public static func validate(_ arguments: JSONValue, against schema: JSONValue) -> String? {
        guard let type = schema["type"]?.stringValue ?? (schema["properties"] != nil ? "object" : nil) else {
            return nil
        }
        return validateValue(arguments, schema, path: "arguments", expectedType: type)
    }

    private static func validateValue(_ value: JSONValue, _ schema: JSONValue, path: String, expectedType: String) -> String? {
        if let allowed = schema["enum"]?.arrayValue,
           !allowed.contains(where: { $0 == value }) {
            return "\(path): not in enum"
        }
        switch expectedType {
        case "object":
            guard case .object(let object) = value else { return "\(path): expected object" }
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard object[required] != nil else { return "\(path): missing required key \"\(required)\"" }
            }
            for key in object.keys where properties[key] == nil {
                return "\(path): unknown key \"\(key)\""
            }
            for (key, child) in object {
                guard let childSchema = properties[key] else { continue }
                if let childType = childSchema["type"]?.stringValue ?? (childSchema["properties"] != nil ? "object" : nil),
                   let detail = validateValue(child, childSchema, path: "\(path).\(key)", expectedType: childType) {
                    return detail
                }
                if childSchema["type"] == nil, let allowed = childSchema["enum"]?.arrayValue,
                   !allowed.contains(where: { $0 == child }) {
                    return "\(path).\(key): not in enum"
                }
            }
            return nil
        case "array":
            guard case .array = value else { return "\(path): expected array" }
            if let items = schema["items"], let itemType = items["type"]?.stringValue {
                for (index, child) in value.arrayValue!.enumerated() {
                    if let detail = validateValue(child, items, path: "\(path)[\(index)]", expectedType: itemType) {
                        return detail
                    }
                }
            }
            return nil
        case "string":
            return value.stringValue == nil ? "\(path): expected string" : nil
        case "integer":
            if case .number(let d) = value, d == d.rounded() { return nil }
            return "\(path): expected integer"
        case "number":
            if case .number = value { return nil }
            return "\(path): expected number"
        case "boolean":
            return value.boolValue == nil ? "\(path): expected boolean" : nil
        default:
            return nil
        }
    }
}
