import Foundation
import OSLog
import os
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

/// What the approval surface decided. `.approvedTyped` means the surface
/// itself collected the red-tier typed confirmation (the intent card enforces
/// the phrase before its approve button enables); `.approvedOnce` is a plain
/// yes without typing.
public enum ToolApproval: Sendable, Equatable {
    case denied, approvedOnce, approvedTyped
}

public struct ToolContext: Sendable {
    public let runID: UUID
    public var surface: ToolSurface
    public var threadID: String?
    /// Set by the UI only after the user typed the confirmation phrase for this call.
    public var redConfirmed: Bool
    /// App-injected approval for orange/red intent cards; nil means nobody is there to ask.
    public var approve: (@Sendable (ToolCall, ToolSpec) async -> ToolApproval)?
    /// True when the turn runs without a user present (scheduled Perrys). The
    /// loop fails answers that park the job on an unanswerable question.
    public var unattended: Bool

    public init(
        surface: ToolSurface,
        runID: UUID = UUID(),
        threadID: String? = nil,
        redConfirmed: Bool = false,
        approve: (@Sendable (ToolCall, ToolSpec) async -> ToolApproval)? = nil,
        unattended: Bool = false
    ) {
        self.runID = runID
        self.surface = surface
        self.threadID = threadID
        self.redConfirmed = redConfirmed
        self.approve = approve
        self.unattended = unattended
    }
}

public enum ToolHostError: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case unknownTool(String)
    case surfaceDenied(name: String, surface: ToolSurface)
    case schemaViolation(name: String, detail: String)
    case confirmationRequired(name: String, tier: TrustTier)
    case approvalDenied(name: String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The task was stopped before this action ran."
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
    private let groups = OSAllocatedUnfairLock(initialState: [String: [String: any ToolExecutor]]())
    private let logger = Logger(subsystem: "ai.perry.brain", category: "tool-host")

    public init(executors: [any ToolExecutor]) {
        var byName: [String: any ToolExecutor] = [:]
        for executor in executors {
            byName[executor.spec.name] = executor
        }
        self.executors = byName
    }

    public func setExecutors(_ executors: [any ToolExecutor], group: String) {
        let byName = Dictionary(executors.map { ($0.spec.name, $0) }) { first, _ in first }
            .filter { self.executors[$0.key] == nil }
        groups.withLock { $0[group] = byName.isEmpty ? nil : byName }
    }

    private func executor(named name: String) -> (any ToolExecutor)? {
        executors[name] ?? groups.withLock { state in state.values.lazy.compactMap { $0[name] }.first }
    }

    public func spec(named name: String) -> ToolSpec? {
        executor(named: name)?.spec
    }

    public func specs(for surface: ToolSurface) -> [ToolSpec] {
        (executors.values.map(\.spec) + groups.withLock { $0.values.flatMap { $0.values.map(\.spec) } })
            .filter { $0.surfaces.contains(surface) && ToolGate.allows($0.name, on: surface) }
            .sorted { $0.name < $1.name }
    }

    public func handle(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        func fail(_ error: ToolHostError) -> ToolResult {
            .text(call.id, error.localizedDescription, isError: true)
        }
        guard !Task.isCancelled else { return fail(.cancelled) }
        guard let executor = executor(named: call.name) else {
            return fail(.unknownTool(call.name))
        }
        let spec = executor.spec
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
            guard await approve(call, spec) != .denied else {
                return fail(.approvalDenied(name: call.name))
            }
        case .red:
            // Red needs typed confirmation: either the caller preflighted it
            // (`redConfirmed`) plus an approve, or the approval surface
            // collected the phrase itself and answered `.approvedTyped`.
            guard let approve = context.approve else {
                return fail(.confirmationRequired(name: call.name, tier: spec.tier))
            }
            let approval = await approve(call, spec)
            let typed = approval == .approvedTyped
                || (approval == .approvedOnce && context.redConfirmed)
            guard approval != .denied, typed else {
                return fail(approval == .denied
                    ? .approvalDenied(name: call.name)
                    : .confirmationRequired(name: call.name, tier: spec.tier))
            }
        }
        guard !Task.isCancelled else { return fail(.cancelled) }
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
            let rejectsUnknownKeys = schema["additionalProperties"].map { $0 == .bool(false) } ?? (schema["properties"] != nil)
            for key in object.keys where rejectsUnknownKeys && properties[key] == nil {
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
