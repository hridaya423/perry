import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

/// Actuation tools (`ui.click`, `ui.type`, `ui.scroll`, …). Input goes
/// through the Cua worker. When the user is there, the target window comes
/// to the front first and the ghost cursor moves to the target before acting;
/// unattended runs stay in the background. Targets resolve from the thread's
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
            UISetValueExecutor(workers: workers, lease: lease, observations: observations),
            UIStepsExecutor(workers: workers, lease: lease, observations: observations),
            UIScrollExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIKeyExecutor(workers: workers, lease: lease, observations: observations, onActuation: onActuation, locate: locate),
            UIHotkeyExecutor(workers: workers, lease: lease, observations: observations),
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
    var pressable = true

    var pointerTarget: ComputerTarget {
        pressable ? target : ComputerTarget(stableID: nil, label: nil, coordinates: target.coordinates)
    }
}

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
            pressable: element.pressable
        ))
    }
    if let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
        let point = screenPoint(x, y, observations: observations, runID: runID)
        return .success(ResolvedTarget(
            target: ComputerTarget(
                stableID: nil,
                label: args["label"]?.stringValue,
                coordinates: ComputerCoordinates(x: point.x, y: point.y)
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
    let shown = snapshot.imageRect(fromScreen: CGRect(origin: point, size: .zero)).origin
    var note = "Found \"\(description)\" at (\(Int(shown.x)), \(Int(shown.y)))"
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
    "x": .object(["type": .string("number"), "description": .string("Pixel in the latest screen.observe screenshot, from its top-left corner; used when elementID is absent")]),
    "y": .object(["type": .string("number")]),
    "label": .object(["type": .string("string"), "description": .string("Accessible label text to match")]),
    "describe": .object(["type": .string("string"), "description": .string("When the target has no element id: describe it for this Mac's click model. Quote its visible text or name its icon, say where it is relative to nearby controls, and say what it does, e.g. \"gear icon at the top right of the sidebar, opens the action menu\".")]),
    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
])

private func windowPixels(_ target: ComputerTarget, observations: AgentObservationStore, runID: UUID) -> ComputerTarget {
    ComputerTarget(stableID: target.stableID, label: target.label, coordinates: target.coordinates.map { windowPixels($0, observations: observations, runID: runID) })
}

private func windowPixels(_ point: ComputerCoordinates, observations: AgentObservationStore, runID: UUID) -> ComputerCoordinates {
    guard let snapshot = observations.snapshot(runID: runID), let bounds = snapshot.windowBoundsAX else { return point }
    return ComputerCoordinates(x: (point.x - bounds.minX) * snapshot.driverScale, y: (point.y - bounds.minY) * snapshot.driverScale)
}

private func screenPoint(_ x: Double, _ y: Double, observations: AgentObservationStore, runID: UUID) -> CGPoint {
    observations.screenPoint(fromImage: CGPoint(x: x, y: y), runID: runID)
}

/// Brings the window Perry is about to act on to the front, so the app
/// accepts the input and the user sees the change happen. Unattended runs
/// stay in the background.
private func bringForward(_ bundleID: String?, observations: AgentObservationStore, context: ToolContext) async {
    guard !context.unattended else { return }
    let window = observations.snapshot(runID: context.runID)?.window
    let raised = await MainActor.run { () -> Bool in
        let app = window.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            ?? bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let wasActive = app.isActive
        if let window { raise(window, in: app.processIdentifier) }
        if !wasActive { app.activate() }
        return !wasActive
    }
    if raised { try? await Task.sleep(for: .milliseconds(300)) }
}

@MainActor
private func raise(_ window: CuaWindowTarget, in pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return }
    let match = windows.first { element in
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return (title as? String) == window.title
    }
    guard let match else { return }
    AXUIElementPerformAction(match, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
}

/// Moves the ghost cursor to the target and lets it arrive before the action,
/// so the user sees where Perry is about to act.
private func showActuation(_ onActuation: (@Sendable (CGPoint, String?) -> Void)?, at point: CGPoint, label: String?) async {
    guard let onActuation else { return }
    onActuation(point, label)
    try? await Task.sleep(for: .milliseconds(350))
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
        await bringForward(resolved.bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(resolved.bundleID)) { worker in
            if let point = resolved.target.coordinates {
                await showActuation(onActuation, at: CGPoint(x: point.x, y: point.y), label: resolved.target.label)
            }
            let result = try await worker.execute(action)
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
        let action = ComputerAction(stepID: call.id, operation: .typeText(text: text, target: windowPixels(resolved.target, observations: observations, runID: context.runID)))
        await bringForward(resolved.bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(resolved.bundleID)) { worker in
            if let point = resolved.target.coordinates {
                await showActuation(onActuation, at: CGPoint(x: point.x, y: point.y), label: resolved.target.label)
            }
            let result = try await worker.execute(action)
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: resolved.note)
        }
    }
}

private struct UISetValueExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.setValue",
            description: "Replace an element's whole value in one step: a native text field's text, a pop-up menu's chosen item, a slider or stepper. On a Finder file name (not being edited) it renames the file; give the full new name with its extension. Not for web pages: for a web input, click it and use ui.type; for a web dropdown, click it, then pick with ui.key (down, return), because setting it directly makes macOS ask the user for Automation access.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
                    "value": .object(["type": .string("string")]),
                    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
                ]),
                "required": .array([.string("elementID"), .string("value")]),
            ]),
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let elementID = call.arguments["elementID"]?.stringValue, let value = call.arguments["value"]?.stringValue else {
            return .text(call.id, "ui.setValue: needs elementID and value", isError: true)
        }
        guard let element = observations.resolveElement(elementID, runID: context.runID) else {
            return .text(call.id, "ui.setValue: element \(elementID) is stale or unknown — run screen.observe again", isError: true)
        }
        let bundleID = observations.snapshot(runID: context.runID)?.window?.bundleID
        let target = ComputerTarget(stableID: element.id, label: element.label.nilIfEmpty, coordinates: nil)
        let action = ComputerAction(stepID: call.id, operation: .setValue(value: value, target: target))
        await bringForward(bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(bundleID)) { worker in
            let result = try await worker.execute(action)
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID)
        }
    }
}

private struct UIStepsExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "ui.steps",
            description: "Run several actions in one call when you already know them, then see the window once: for example click a row, press return, type a name, press return. Steps run in order and stop at the first failure. Element ids come from the latest screen.observe and stay valid through the batch, so end the batch at a step that opens a new screen and observe before going on.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
                    "steps": .object([
                        "type": .string("array"),
                        "maxItems": .number(20),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "action": .object(["type": .string("string"), "enum": .array(["click", "doubleclick", "rightclick", "type", "setValue", "key", "hotkey", "scroll"].map { .string($0) })]),
                                "elementID": .object(["type": .string("string")]),
                                "x": .object(["type": .string("number"), "description": .string("Screenshot pixel, as in ui.click")]),
                                "y": .object(["type": .string("number")]),
                                "text": .object(["type": .string("string"), "description": .string("For type; with no target it goes to the focused field")]),
                                "value": .object(["type": .string("string"), "description": .string("For setValue")]),
                                "key": .object(["type": .string("string"), "description": .string("For key")]),
                                "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                                "keys": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("For hotkey, like [\"cmd\", \"s\"]")]),
                                "direction": .object(["type": .string("string"), "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])]),
                                "amount": .object(["type": .string("number")]),
                            ]),
                            "required": .array([.string("action")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("steps")]),
            ]),
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let steps = call.arguments["steps"]?.arrayValue, !steps.isEmpty, steps.count <= 20 else {
            return .text(call.id, "ui.steps: needs 1 to 20 steps", isError: true)
        }
        var operations: [ComputerAction.Operation] = []
        for (index, step) in steps.enumerated() {
            switch await stepOperation(step, runID: context.runID) {
            case .success(let operation): operations.append(operation)
            case .failure(let error): return .text(call.id, "ui.steps: step \(index + 1): \(error.message)", isError: true)
            }
        }
        let bundleID = call.arguments["bundleID"]?.stringValue ?? observations.snapshot(runID: context.runID)?.window?.bundleID
        let action = ComputerAction(stepID: call.id, operation: .steps(operations))
        await bringForward(bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(bundleID)) { worker in
            let result = try await worker.execute(action)
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID)
        }
    }

    private func stepOperation(_ step: JSONValue, runID: UUID) async -> Result<ComputerAction.Operation, ToolResolutionError> {
        let targeted = step["elementID"] != nil || (step["x"] != nil && step["y"] != nil)
        let resolved: ResolvedTarget? = targeted ? try? await resolveTarget(args: step, observations: observations, runID: runID, locate: nil).get() : nil
        if targeted, resolved == nil {
            return .failure(ToolResolutionError(message: "element \(step["elementID"]?.stringValue ?? "at x/y") is stale or unknown — run screen.observe again"))
        }
        let pointer = resolved.map { windowPixels($0.pointerTarget, observations: observations, runID: runID) }
        let plain = resolved.map { windowPixels($0.target, observations: observations, runID: runID) }
        switch step["action"]?.stringValue {
        case "click", "doubleclick", "rightclick":
            guard let pointer else { return .failure(ToolResolutionError(message: "needs elementID or x/y")) }
            switch step["action"]?.stringValue {
            case "doubleclick": return .success(.doubleClick(pointer))
            case "rightclick": return .success(.rightClick(pointer))
            default: return .success(.click(pointer))
            }
        case "type":
            guard let text = step["text"]?.stringValue else { return .failure(ToolResolutionError(message: "type needs text")) }
            return .success(.typeText(text: text, target: plain ?? ComputerTarget(stableID: nil, label: nil, coordinates: nil)))
        case "setValue":
            guard let value = step["value"]?.stringValue, let resolved, resolved.target.stableID != nil else {
                return .failure(ToolResolutionError(message: "setValue needs elementID and value"))
            }
            return .success(.setValue(value: value, target: ComputerTarget(stableID: resolved.target.stableID, label: resolved.target.label, coordinates: nil)))
        case "key":
            guard let key = step["key"]?.stringValue else { return .failure(ToolResolutionError(message: "key needs key")) }
            return .success(.pressKey(key: key.lowercased(), modifiers: step["modifiers"]?.arrayValue?.compactMap(\.stringValue), target: plain))
        case "hotkey":
            guard let keys = step["keys"]?.arrayValue?.compactMap(\.stringValue), !keys.isEmpty else { return .failure(ToolResolutionError(message: "hotkey needs keys")) }
            return .success(.hotkey(keys: keys.map { $0.lowercased() }, target: plain))
        case "scroll":
            guard let direction = step["direction"]?.stringValue.flatMap(ComputerAction.Direction.init(rawValue:)) else {
                return .failure(ToolResolutionError(message: "scroll needs a direction"))
            }
            return .success(.scroll(direction: direction, amount: step["amount"]?.doubleValue.map { Int($0) } ?? 3, by: nil, target: plain))
        default:
            return .failure(ToolResolutionError(message: "unknown action"))
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
        await bringForward(target?.bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(target?.bundleID)) { worker in
            if let point = target?.target.coordinates {
                await showActuation(onActuation, at: CGPoint(x: point.x, y: point.y), label: target?.target.label)
            }
            let result = try await worker.execute(action)
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
        await bringForward(target?.bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(target?.bundleID)) { worker in
            if let point = target?.target.coordinates {
                await showActuation(onActuation, at: CGPoint(x: point.x, y: point.y), label: target?.target.label)
            }
            let result = try await worker.execute(action)
            return await verifiedResult(call, result, worker: worker, observations: observations, runID: context.runID, located: target?.note)
        }
    }
}

private struct UIHotkeyExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

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
        await bringForward(bundleID, observations: observations, context: context)
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
            description: "Drag between two pixels of the latest screen.observe screenshot. Reviewed: drags have unknown effects.",
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
            tier: .yellow,
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
        let from = screenPoint(fromX, fromY, observations: observations, runID: context.runID)
        let to = screenPoint(toX, toY, observations: observations, runID: context.runID)
        let action = ComputerAction(
            stepID: call.id,
            operation: .drag(
                from: windowPixels(ComputerCoordinates(x: from.x, y: from.y), observations: observations, runID: context.runID),
                to: windowPixels(ComputerCoordinates(x: to.x, y: to.y), observations: observations, runID: context.runID),
                durationMilliseconds: nil, steps: nil
            )
        )
        let bundleID = args["bundleID"]?.stringValue
        await bringForward(bundleID, observations: observations, context: context)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: targetResources(bundleID)) { worker in
            await showActuation(onActuation, at: to, label: nil)
            let result = try await worker.execute(action)
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
