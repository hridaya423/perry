import Foundation
import PerryBrain
import PerryCore

/// Actuation tools (`ui.click`, `ui.type`, `ui.scroll`, …) — agent surface
/// only. All input goes through the background Cua worker: the real pointer
/// never moves and focus is never stolen. Targets resolve from the thread's
/// last `screen.observe` (compact element id), a label, or raw coordinates.
struct UITools {
    let workers: CuaWorkerService
    let observations: AgentObservationStore
    /// Ghost cursor hook: called with the AX-space point each ui.* tool acts
    /// on, so the overlay can show where the agent is working without ever
    /// moving the real pointer.
    var onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var executors: [any ToolExecutor] {
        [
            UIActionExecutor(kind: .click, workers: workers, observations: observations, onActuation: onActuation),
            UIActionExecutor(kind: .doubleClick, workers: workers, observations: observations, onActuation: onActuation),
            UIActionExecutor(kind: .rightClick, workers: workers, observations: observations, onActuation: onActuation),
            UITypeExecutor(workers: workers, observations: observations, onActuation: onActuation),
            UIScrollExecutor(workers: workers, observations: observations, onActuation: onActuation),
            UIKeyExecutor(workers: workers, observations: observations, onActuation: onActuation),
            UIHotkeyExecutor(workers: workers),
            UIDragExecutor(workers: workers, onActuation: onActuation),
        ]
    }
}

private extension ToolContext {
    var threadKey: String { threadID ?? "" }
}

private enum UIClickKind: String {
    case click = "ui.click"
    case doubleClick = "ui.doubleclick"
    case rightClick = "ui.rightclick"
}

/// Shared argument→target resolution. An elementID wins, then an explicit
/// label, then raw (x, y). Returns the ComputerTarget plus the owning
/// bundleID so the worker can claim the app resource.
private struct ResolvedTarget {
    let target: ComputerTarget
    let bundleID: String?
}

private struct ToolResolutionError: Error {
    let message: String
}

private func resolveTarget(
    args: JSONValue,
    observations: AgentObservationStore,
    threadID: String?
) -> Result<ResolvedTarget, ToolResolutionError> {
    if let elementID = args["elementID"]?.stringValue {
        guard let element = observations.resolveElement(elementID, threadID: threadID) else {
            return .failure(ToolResolutionError(message: "element \(elementID) is stale or unknown — run screen.observe again"))
        }
        let window = observations.snapshot(threadID: threadID)?.window
        return .success(ResolvedTarget(
            target: ComputerTarget(
                stableID: element.id,
                label: element.label.nilIfEmpty,
                coordinates: ComputerCoordinates(x: element.frame.midX, y: element.frame.midY)
            ),
            bundleID: window?.bundleID
        ))
    }
    if let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
        return .success(ResolvedTarget(
            target: ComputerTarget(
                stableID: nil,
                label: args["label"]?.stringValue,
                coordinates: ComputerCoordinates(x: x, y: y)
            ),
            bundleID: args["bundleID"]?.stringValue
        ))
    }
    if let label = args["label"]?.stringValue {
        return .success(ResolvedTarget(
            target: ComputerTarget(stableID: nil, label: label, coordinates: nil),
            bundleID: args["bundleID"]?.stringValue
        ))
    }
    return .failure(ToolResolutionError(message: "needs elementID, x/y, or label"))
}

private let targetSchemaProperties: JSONValue = .object([
    "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
    "x": .object(["type": .string("number"), "description": .string("AX-space screen coordinate; used when elementID is absent")]),
    "y": .object(["type": .string("number")]),
    "label": .object(["type": .string("string"), "description": .string("Accessible label text to match")]),
    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
])

private func targetResources(_ bundleID: String?) -> Set<BackgroundTaskResource> {
    bundleID.map { [.application($0.lowercased())] } ?? []
}

private struct UIActionExecutor: ToolExecutor {
    let kind: UIClickKind
    let workers: CuaWorkerService
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var spec: ToolSpec {
        ToolSpec(
            name: kind.rawValue,
            description: "\(kind == .click ? "Click" : kind == .doubleClick ? "Double-click" : "Right-click") an element or point without moving the user's cursor.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": targetSchemaProperties,
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let resolved = resolveTarget(args: call.arguments, observations: observations, threadID: context.threadKey)
        guard case .success(let resolved) = resolved else {
            return .text(call.id, "\(kind.rawValue): \(resolved.errorMessage)", isError: true)
        }
        let operation: ComputerAction.Operation = switch kind {
        case .click: .click(resolved.target)
        case .doubleClick: .doubleClick(resolved.target)
        case .rightClick: .rightClick(resolved.target)
        }
        let action = ComputerAction(stepID: call.id, operation: operation)
        return try await workers.withWorker(scope: .background, resources: targetResources(resolved.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = resolved.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), resolved.target.label)
            }
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UITypeExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.type",
            description: "Type text into an element or point, without moving the user's cursor.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetSchemaProperties.objectValue!.merging(
                    ["text": .object(["type": .string("string")])]
                ) { _, new in new }),
                "required": .array([.string("text")]),
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let text = call.arguments["text"]?.stringValue else {
            return .text(call.id, "ui.type: missing text", isError: true)
        }
        let resolved = resolveTarget(args: call.arguments, observations: observations, threadID: context.threadKey)
        guard case .success(let resolved) = resolved else {
            return .text(call.id, "ui.type: \(resolved.errorMessage)", isError: true)
        }
        let action = ComputerAction(stepID: call.id, operation: .typeText(text: text, target: resolved.target))
        return try await workers.withWorker(scope: .background, resources: targetResources(resolved.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = resolved.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), resolved.target.label)
            }
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UIScrollExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.scroll",
            description: "Scroll within an element or window.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetSchemaProperties.objectValue!.merging([
                    "direction": .object(["type": .string("string"), "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])]),
                    "amount": .object(["type": .string("integer"), "description": .string("Scroll units (default 3)")]),
                ]) { _, new in new }),
                "required": .array([.string("direction")]),
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        guard let directionRaw = args["direction"]?.stringValue,
              let direction = ComputerAction.Direction(rawValue: directionRaw) else {
            return .text(call.id, "ui.scroll: direction must be up/down/left/right", isError: true)
        }
        let amount = args["amount"]?.doubleValue.map { Int($0) } ?? 3
        let resolved = resolveTarget(args: args, observations: observations, threadID: context.threadKey)
        let target = try? resolved.get()
        let action = ComputerAction(
            stepID: call.id,
            operation: .scroll(direction: direction, amount: amount, by: nil, target: target?.target)
        )
        return try await workers.withWorker(scope: .background, resources: targetResources(target?.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = target?.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), target?.target.label)
            }
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UIKeyExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.key",
            description: "Press a key (optionally with modifiers like cmd/shift) in the target app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetSchemaProperties.objectValue!.merging([
                    "key": .object(["type": .string("string")]),
                    "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                ]) { _, new in new }),
                "required": .array([.string("key")]),
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let key = call.arguments["key"]?.stringValue else {
            return .text(call.id, "ui.key: missing key", isError: true)
        }
        let modifiers = call.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue)
        let resolved = resolveTarget(args: call.arguments, observations: observations, threadID: context.threadKey)
        let target = try? resolved.get()
        let action = ComputerAction(
            stepID: call.id,
            operation: .pressKey(key: key.lowercased(), modifiers: modifiers, target: target?.target)
        )
        return try await workers.withWorker(scope: .background, resources: targetResources(target?.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = target?.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), target?.target.label)
            }
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UIHotkeyExecutor: ToolExecutor {
    let workers: CuaWorkerService

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.hotkey",
            description: "Press a key chord like [cmd, shift, s] in the target app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "keys": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "bundleID": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("keys")]),
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context _: ToolContext) async throws -> ToolResult {
        let keys = call.arguments["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !keys.isEmpty else {
            return .text(call.id, "ui.hotkey: keys must be a non-empty list", isError: true)
        }
        let bundleID = call.arguments["bundleID"]?.stringValue
        let action = ComputerAction(stepID: call.id, operation: .hotkey(keys: keys.map { $0.lowercased() }, target: nil))
        return try await workers.withWorker(scope: .background, resources: targetResources(bundleID)) { worker in
            let result = try await worker.execute(action)
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UIDragExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.drag",
            description: "Drag from one screen point to another. Reviewed: drags have unknown effects.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromX": .object(["type": .string("number")]),
                    "fromY": .object(["type": .string("number")]),
                    "toX": .object(["type": .string("number")]),
                    "toY": .object(["type": .string("number")]),
                    "bundleID": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("fromX"), .string("fromY"), .string("toX"), .string("toY")]),
            ]),
            // Unknown-effect GUI input defaults to orange review (Phase 7 spec).
            tier: .orange,
            surfaces: [.agent]
        )
    }

    func run(_ call: ToolCall, context _: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        guard let fromX = args["fromX"]?.doubleValue, let fromY = args["fromY"]?.doubleValue,
              let toX = args["toX"]?.doubleValue, let toY = args["toY"]?.doubleValue else {
            return .text(call.id, "ui.drag: needs fromX/fromY/toX/toY", isError: true)
        }
        let action = ComputerAction(
            stepID: call.id,
            operation: .drag(
                from: ComputerCoordinates(x: fromX, y: fromY),
                to: ComputerCoordinates(x: toX, y: toY),
                durationMilliseconds: nil, steps: nil
            )
        )
        let bundleID = args["bundleID"]?.stringValue
        return try await workers.withWorker(scope: .background, resources: targetResources(bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success {
                onActuation?(CGPoint(x: toX, y: toY), nil)
            }
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private extension Result where Failure == ToolResolutionError {
    var errorMessage: String {
        if case .failure(let error) = self { return error.message }
        return "unknown error"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
