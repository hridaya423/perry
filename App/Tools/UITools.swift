import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

/// Actuation tools (`ui.click`, `ui.type`, `ui.scroll`, …) — agent surface
/// only. All input goes through the background Cua worker: the real pointer
/// never moves and focus is never stolen. Targets resolve from the thread's
/// last `screen.observe` (compact element id), a label, or raw coordinates.
struct UITools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    /// Ghost cursor hook: called with the AX-space point each ui.* tool acts
    /// on, so the overlay can show where the agent is working without ever
    /// moving the real pointer.
    var onActuation: (@Sendable (CGPoint, String?) -> Void)?
    var locate: LocateTarget?

    var executors: [any ToolExecutor] {
        [
            UIActionExecutor(kind: .click, workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIActionExecutor(kind: .doubleClick, workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIActionExecutor(kind: .rightClick, workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UITypeExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIScrollExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIKeyExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIHotkeyExecutor(workers: workers, lease: lease),
            UIDragExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation),
        ]
    }
}

private enum UIClickKind: String {
    case click = "ui.click"
    case doubleClick = "ui.doubleclick"
    case rightClick = "ui.rightclick"
}

/// Shared argument→target resolution. An elementID wins, then an explicit
/// label, then raw (x, y). Returns the ComputerTarget plus the owning
/// bundleID so the worker can claim the app resource.
typealias LocateTarget = @Sendable (_ description: String, _ screenshot: Data, _ windowSize: CGSize, _ accepts: @escaping @Sendable (CGPoint) -> Bool) async throws -> ClickGrounder.Located

private struct ResolvedTarget {
    let target: ComputerTarget
    let bundleID: String?
    var note: String? = nil
    var role: String? = nil

    var pointerTarget: ComputerTarget {
        guard let role, pointerOnlyRoles.contains(role) else { return target }
        return ComputerTarget(stableID: nil, label: nil, coordinates: target.coordinates)
    }
}

private func finderRenameText(_ text: String, name: String?, bundleID: String?) -> String {
    guard bundleID?.lowercased() == "com.apple.finder", let name else { return text }
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, text.count > ext.count + 1, text.lowercased().hasSuffix(".\(ext.lowercased())") else { return text }
    return String(text.dropLast(ext.count + 1))
}

private let pointerOnlyRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXCell", "AXRow", "AXGroup",
]

private struct ToolResolutionError: Error {
    let message: String
}

private func resolveTarget(
    args: JSONValue,
    observations: AgentObservationStore,
    runID: UUID,
    locate: LocateTarget?
) async -> Result<ResolvedTarget, ToolResolutionError> {
    if let elementID = args["elementID"]?.stringValue {
        guard let element = observations.resolveElement(elementID, runID: runID) else {
            return .failure(ToolResolutionError(message: "element \(elementID) is stale or unknown — run screen.observe again"))
        }
        let window = observations.snapshot(runID: runID)?.window
        return .success(ResolvedTarget(
            target: ComputerTarget(
                stableID: element.id,
                label: element.label.nilIfEmpty,
                coordinates: ComputerCoordinates(x: element.frame.midX, y: element.frame.midY)
            ),
            bundleID: window?.bundleID,
            role: element.role
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
    if let description = args["describe"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
        return await locateDescribed(description, observations: observations, runID: runID, locate: locate)
    }
    if let label = args["label"]?.stringValue {
        return .success(ResolvedTarget(
            target: ComputerTarget(stableID: nil, label: label, coordinates: nil),
            bundleID: args["bundleID"]?.stringValue
        ))
    }
    return .failure(ToolResolutionError(message: "needs elementID, x/y, or label"))
}

private func locateDescribed(
    _ description: String,
    observations: AgentObservationStore,
    runID: UUID,
    locate: LocateTarget?
) async -> Result<ResolvedTarget, ToolResolutionError> {
    guard let locate else {
        return .failure(ToolResolutionError(message: "describe needs this Mac's click model, which isn't downloaded. Use elementID or x/y instead."))
    }
    guard let snapshot = observations.snapshot(runID: runID), let screenshot = snapshot.screenshotData, let bounds = snapshot.windowBoundsAX else {
        return .failure(ToolResolutionError(message: "run screen.observe first so there is a screenshot to search"))
    }
    let elements = snapshot.index.entries.map(\.element)
    let wanted = description.lowercased()
    let named = elements.filter { $0.label.count >= 3 && wanted.contains($0.label.lowercased()) }
    let accepts: @Sendable (CGPoint) -> Bool = { point in
        let found = CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y)
        if let label = ClickGrounder.snapTarget(found, elements: elements, window: bounds)?.label.lowercased(),
           label.count >= 3, wanted.contains(label) {
            return true
        }
        guard named.count == 1, let row = named.first else { return false }
        return abs(found.y - row.frame.midY) <= max(row.frame.height / 2, 8)
    }
    let located: ClickGrounder.Located
    do {
        located = try await locate(description, screenshot, bounds.size, accepts)
    } catch {
        return .failure(ToolResolutionError(message: "describe: \(error.localizedDescription)"))
    }
    let found = CGPoint(x: bounds.minX + located.point.x, y: bounds.minY + located.point.y)
    let element = ClickGrounder.snapTarget(found, elements: elements, window: bounds)
    let point = element.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? found
    var note = "Found \"\(description)\" at (\(Int(point.x)), \(Int(point.y)))"
    if let element { note += " on \(element.role) \"\(element.label)\"" }
    note += located.confident ? "." : ". The click model was unsure, so check the window below before going on."
    return .success(ResolvedTarget(
        target: ComputerTarget(
            stableID: element?.id,
            label: element?.label.nilIfEmpty ?? description,
            coordinates: ComputerCoordinates(x: point.x, y: point.y)
        ),
        bundleID: snapshot.window?.bundleID,
        note: note
    ))
}

private let targetSchemaProperties: JSONValue = .object([
    "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
    "x": .object(["type": .string("number"), "description": .string("AX-space screen coordinate; used when elementID is absent")]),
    "y": .object(["type": .string("number")]),
    "label": .object(["type": .string("string"), "description": .string("Accessible label text to match")]),
    "describe": .object(["type": .string("string"), "description": .string("When the target has no element id: describe it for this Mac's click model. Quote its visible text or name its icon, say where it is relative to nearby controls, and say what it does, e.g. \"gear icon at the top right of the sidebar, opens the action menu\".")]),
    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
])

private func windowPixels(_ target: ComputerTarget, observations: AgentObservationStore, runID: UUID) -> ComputerTarget {
    ComputerTarget(stableID: target.stableID, label: target.label, coordinates: target.coordinates.map { windowPixels($0, observations: observations, runID: runID) })
}

private func windowPixels(_ point: ComputerCoordinates, observations: AgentObservationStore, runID: UUID) -> ComputerCoordinates {
    guard let snapshot = observations.snapshot(runID: runID), let bounds = snapshot.windowBoundsAX, bounds.width > 0 else { return point }
    let pixelWidth = snapshot.screenshotData.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width }
    let scale = pixelWidth.map { Double($0) / bounds.width } ?? 1
    return ComputerCoordinates(x: (point.x - bounds.minX) * scale, y: (point.y - bounds.minY) * scale)
}

private func targetResources(_ bundleID: String?) -> Set<BackgroundTaskResource> {
    bundleID.map { [.application($0.lowercased())] } ?? []
}

private func verifiedResult(
    _ call: ToolCall, _ result: StepResult, worker: CuaWorkerHandle,
    observations: AgentObservationStore, runID: UUID, located: String? = nil
) async -> ToolResult {
    let message = [located, result.message].compactMap { $0 }.joined(separator: "\n")
    guard result.success,
          let hint = try? observations.prepareCapture(runID: runID),
          let after = try? await observeWindow(worker: worker, hint: hint, observations: observations, runID: runID) else {
        return .text(call.id, message, isError: !result.success)
    }
    let note = "\(message)\nThe window after this action is below. Element ids are refreshed, so use these ids from now on."
    return ToolResult(callID: call.id, content: [.text(note)] + after)
}

private struct UIActionExecutor: ToolExecutor {
    let kind: UIClickKind
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?
    let locate: LocateTarget?

    var spec: ToolSpec {
        ToolSpec(
            name: kind.rawValue,
            description: "\(kind == .click ? "Click" : kind == .doubleClick ? "Double-click" : "Right-click") an element, a point, or a described target without moving the user's cursor. Prefer elementID from screen.observe; use describe for targets missing from the element list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": targetSchemaProperties,
            ]),
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let resolved = await resolveTarget(args: call.arguments, observations: observations, runID: context.runID, locate: locate)
        guard case .success(let resolved) = resolved else {
            return .text(call.id, "\(kind.rawValue): \(resolved.errorMessage)", isError: true)
        }
        let onWindow = windowPixels(resolved.pointerTarget, observations: observations, runID: context.runID)
        let operation: ComputerAction.Operation = switch kind {
        case .click: .click(onWindow)
        case .doubleClick: .doubleClick(onWindow)
        case .rightClick: .rightClick(onWindow)
        }
        let action = ComputerAction(stepID: call.id, operation: operation)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(resolved.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success { observations.noteClicked(resolved.target.label, runID: context.runID) }
            if result.success, let point = resolved.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), resolved.target.label)
            }
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: resolved.note)
        }
    }
}

private struct UITypeExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?
    let locate: LocateTarget?

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.type",
            description: "Type text into an element or point, without moving the user's cursor. With no target, type into the field that already has focus.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetSchemaProperties.objectValue!.merging(
                    ["text": .object(["type": .string("string")])]
                ) { _, new in new }),
                "required": .array([.string("text")]),
            ]),
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let text = call.arguments["text"]?.stringValue else {
            return .text(call.id, "ui.type: missing text", isError: true)
        }
        let focused = !["elementID", "x", "y", "label", "describe"].contains { call.arguments[$0] != nil }
        let resolved: Result<ResolvedTarget, ToolResolutionError> = focused
            ? .success(ResolvedTarget(target: ComputerTarget(stableID: nil, label: nil, coordinates: nil), bundleID: call.arguments["bundleID"]?.stringValue))
            : await resolveTarget(args: call.arguments, observations: observations, runID: context.runID, locate: locate)
        guard case .success(let resolved) = resolved else {
            return .text(call.id, "ui.type: \(resolved.errorMessage)", isError: true)
        }
        let name = focused ? observations.lastClicked(runID: context.runID) : (resolved.role == "AXTextField" ? resolved.target.label : nil)
        let bundleID = resolved.bundleID ?? observations.snapshot(runID: context.runID)?.window?.bundleID
        let action = ComputerAction(stepID: call.id, operation: .typeText(text: finderRenameText(text, name: name, bundleID: bundleID), target: windowPixels(resolved.target, observations: observations, runID: context.runID)))
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(resolved.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = resolved.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), resolved.target.label)
            }
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: resolved.note)
        }
    }
}

private struct UIScrollExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?
    let locate: LocateTarget?

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
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        guard let directionRaw = args["direction"]?.stringValue,
              let direction = ComputerAction.Direction(rawValue: directionRaw) else {
            return .text(call.id, "ui.scroll: direction must be up/down/left/right", isError: true)
        }
        let amount = args["amount"]?.doubleValue.map { Int($0) } ?? 3
        let resolved = await resolveTarget(args: args, observations: observations, runID: context.runID, locate: locate)
        let target = try? resolved.get()
        let action = ComputerAction(
            stepID: call.id,
            operation: .scroll(direction: direction, amount: amount, by: nil, target: target.map { windowPixels($0.target, observations: observations, runID: context.runID) })
        )
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(target?.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = target?.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), target?.target.label)
            }
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: target?.note)
        }
    }
}

private struct UIKeyExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?
    let locate: LocateTarget?

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
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let key = call.arguments["key"]?.stringValue else {
            return .text(call.id, "ui.key: missing key", isError: true)
        }
        let modifiers = call.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue)
        let resolved = await resolveTarget(args: call.arguments, observations: observations, runID: context.runID, locate: locate)
        let target = try? resolved.get()
        let action = ComputerAction(
            stepID: call.id,
            operation: .pressKey(key: key.lowercased(), modifiers: modifiers, target: target.map { windowPixels($0.target, observations: observations, runID: context.runID) })
        )
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(target?.bundleID)) { worker in
            let result = try await worker.execute(action)
            if result.success, let point = target?.target.coordinates {
                onActuation?(CGPoint(x: point.x, y: point.y), target?.target.label)
            }
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: target?.note)
        }
    }
}

private struct UIHotkeyExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?

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
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let keys = call.arguments["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !keys.isEmpty else {
            return .text(call.id, "ui.hotkey: keys must be a non-empty list", isError: true)
        }
        let bundleID = call.arguments["bundleID"]?.stringValue
        let action = ComputerAction(stepID: call.id, operation: .hotkey(keys: keys.map { $0.lowercased() }, target: nil))
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(bundleID)) { worker in
            let result = try await worker.execute(action)
            return .text(call.id, result.message, isError: !result.success)
        }
    }
}

private struct UIDragExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
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
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        guard let fromX = args["fromX"]?.doubleValue, let fromY = args["fromY"]?.doubleValue,
              let toX = args["toX"]?.doubleValue, let toY = args["toY"]?.doubleValue else {
            return .text(call.id, "ui.drag: needs fromX/fromY/toX/toY", isError: true)
        }
        let action = ComputerAction(
            stepID: call.id,
            operation: .drag(
                from: windowPixels(ComputerCoordinates(x: fromX, y: fromY), observations: observations, runID: context.runID),
                to: windowPixels(ComputerCoordinates(x: toX, y: toY), observations: observations, runID: context.runID),
                durationMilliseconds: nil, steps: nil
            )
        )
        let bundleID = args["bundleID"]?.stringValue
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(bundleID)) { worker in
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
