import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

typealias LocateTarget = @Sendable (_ description: String, _ screenshot: Data, _ windowSize: CGSize, _ accepts: @escaping @Sendable (CGPoint) -> Bool) async throws -> ClickGrounder.Located

struct UITools {
    let workers: ScreenWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    var onActuation: (@Sendable (CGPoint, String?) -> Void)?
    var locate: LocateTarget?

    var executors: [any ToolExecutor] {
        let worker = ToolWorkerContext(workers: workers, lease: lease, observations: observations)
        return UIToolDefinition.all.map {
            UIToolExecutor(definition: $0, worker: worker, onActuation: onActuation, locate: locate)
        } + [UIStepsExecutor(worker: worker, onActuation: onActuation)]
    }

    static func headline(forTool name: String, target: String?) -> String? {
        if name == UIStepsExecutor.name { return "Do these steps in this app?" }
        return UIToolDefinition.all.first { $0.name == name }?.headline(target)
    }
}

private enum UIClickKind: String {
    case click = "ui.click"
    case doubleClick = "ui.doubleclick"
    case rightClick = "ui.rightclick"

    func operation(_ target: ComputerTarget) -> ComputerAction.Operation {
        switch self {
        case .click: .click(target)
        case .doubleClick: .doubleClick(target)
        case .rightClick: .rightClick(target)
        }
    }
}

private enum UIRealInput: Sendable {
    case click(UIClickKind)
    case key(String, [String]?)
}

private struct UIPlan: Sendable {
    var operation: ComputerAction.Operation
    var bundleID: String?
    var actuation: ComputerCoordinates?
    var actuationLabel: String?
    var movesPointer = true
    var note: String?
    var realInput: UIRealInput?
    var reportsWindow = true
}

private struct UIPlanRequest: Sendable {
    let arguments: JSONValue
    let runID: UUID
    let observations: AgentObservationStore
    let locate: LocateTarget?
}

private struct ToolResolutionError: Error {
    let message: String
}

private struct UIToolDefinition: Sendable {
    typealias Plan = @Sendable (UIPlanRequest) async -> Result<UIPlan, ToolResolutionError>

    let name: String
    let description: String
    let schema: JSONValue
    let headline: @Sendable (String?) -> String
    let plan: Plan

    static let all: [UIToolDefinition] = [
        click(.click, verb: "Click", headline: { $0.map { "Click “\($0)”?" } ?? "Click here?" }),
        click(.doubleClick, verb: "Double-click", headline: { $0.map { "Double-click “\($0)”?" } ?? "Double-click here?" }),
        click(.rightClick, verb: "Right-click", headline: { $0.map { "Right-click “\($0)”?" } ?? "Right-click here?" }),
        UIToolDefinition(
            name: "ui.type",
            description: "Type text into an element or point, without moving the user's cursor. With no target, type into the field that already has focus. The text goes in at the insertion point and does not replace selected text; to replace a native field's text, use ui.setValue.",
            schema: objectSchema(["text": .object(["type": .string("string")])], required: ["text"], target: true),
            headline: { _ in "Type into this field?" },
            plan: { request in
                let arguments = request.arguments
                guard let text = arguments["text"]?.stringValue else {
                    return .failure(ToolResolutionError(message: "missing text"))
                }
                let focused = !["elementID", "x", "y", "label", "describe"].contains { arguments[$0] != nil }
                if focused {
                    return .success(UIPlan(
                        operation: .typeText(text: text, target: nil),
                        bundleID: arguments["bundleID"]?.stringValue
                    ))
                }
                return await resolveTarget(request).map { resolved in
                    UIPlan(
                        operation: .typeText(text: text, target: windowPixels(resolved.target, request)),
                        bundleID: resolved.bundleID,
                        actuation: resolved.target.point,
                        actuationLabel: resolved.target.label,
                        note: resolved.note
                    )
                }
            }
        ),
        UIToolDefinition(
            name: "ui.setValue",
            description: "Replace an element's whole value in one step: a native text field's text, a pop-up menu's chosen item, a slider or stepper. On a Finder file name (not being edited) it renames the file; give the full new name with its extension. Not for web pages: for a web input, click it and use ui.type; for a web dropdown, click it, then pick with ui.key (down, return), because setting it directly makes macOS ask the user for Automation access.",
            schema: objectSchema([
                "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
                "value": .object(["type": .string("string")]),
                "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
            ], required: ["elementID", "value"]),
            headline: { $0.map { "Change “\($0)”?" } ?? "Change this field?" },
            plan: { request in
                guard let elementID = request.arguments["elementID"]?.stringValue,
                      let value = request.arguments["value"]?.stringValue else {
                    return .failure(ToolResolutionError(message: "needs elementID and value"))
                }
                guard let element = request.observations.resolveElement(elementID, runID: request.runID) else {
                    return .failure(staleElement(elementID))
                }
                return .success(UIPlan(
                    operation: .setValue(value: value, target: .element(id: element.id, label: element.label.nilIfEmpty, point: nil)),
                    bundleID: request.observations.snapshot(runID: request.runID)?.window?.bundleID
                ))
            }
        ),
        UIToolDefinition(
            name: "ui.scroll",
            description: "Scroll within an element or window.",
            schema: objectSchema([
                "direction": .object(["type": .string("string"), "enum": .array(directions.map { .string($0) })]),
                "amount": .object(["type": .string("integer"), "description": .string("Scroll units (default 3)")]),
            ], required: ["direction"], target: true),
            headline: { _ in "Scroll this window?" },
            plan: { request in
                guard let direction = request.arguments["direction"]?.stringValue.flatMap(ComputerAction.Direction.init(rawValue:)) else {
                    return .failure(ToolResolutionError(message: "direction must be up/down/left/right"))
                }
                let amount = request.arguments["amount"]?.doubleValue.map { Int($0) } ?? 3
                let resolved = try? await resolveTarget(request).get()
                return .success(UIPlan(
                    operation: .scroll(direction: direction, amount: amount, by: nil, target: resolved.map { windowPixels($0.target, request) }),
                    bundleID: resolved?.bundleID,
                    actuation: resolved?.target.point,
                    actuationLabel: resolved?.target.label,
                    note: resolved?.note
                ))
            }
        ),
        UIToolDefinition(
            name: "ui.key",
            description: "Press a key (optionally with modifiers like cmd/shift) in the target app.",
            schema: objectSchema([
                "key": .object(["type": .string("string")]),
                "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ], required: ["key"], target: true),
            headline: { $0.map { "Press \($0)?" } ?? "Press a key?" },
            plan: { request in
                guard let key = request.arguments["key"]?.stringValue else {
                    return .failure(ToolResolutionError(message: "missing key"))
                }
                let modifiers = request.arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue)
                let resolved = try? await resolveTarget(request).get()
                return .success(UIPlan(
                    operation: .pressKey(key: key.lowercased(), modifiers: modifiers, target: resolved.map { windowPixels($0.target, request) }),
                    bundleID: resolved?.bundleID,
                    actuation: resolved?.target.point,
                    actuationLabel: resolved?.target.label,
                    note: resolved?.note,
                    realInput: .key(key, modifiers)
                ))
            }
        ),
        UIToolDefinition(
            name: "ui.hotkey",
            description: "Press a key chord like [cmd, shift, s] in the target app.",
            schema: objectSchema([
                "keys": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "bundleID": .object(["type": .string("string")]),
            ], required: ["keys"]),
            headline: { _ in "Press a keyboard shortcut?" },
            plan: { request in
                let keys = request.arguments["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !keys.isEmpty else {
                    return .failure(ToolResolutionError(message: "keys must be a non-empty list"))
                }
                return .success(UIPlan(
                    operation: .hotkey(keys: keys.map { $0.lowercased() }, target: nil),
                    bundleID: request.arguments["bundleID"]?.stringValue,
                    reportsWindow: false
                ))
            }
        ),
        UIToolDefinition(
            name: "ui.drag",
            description: "Drag between two pixels of the latest screen.observe screenshot. Reviewed: drags have unknown effects.",
            schema: objectSchema([
                "fromX": .object(["type": .string("number")]),
                "fromY": .object(["type": .string("number")]),
                "toX": .object(["type": .string("number")]),
                "toY": .object(["type": .string("number")]),
                "bundleID": .object(["type": .string("string")]),
            ], required: ["fromX", "fromY", "toX", "toY"]),
            headline: { _ in "Drag here?" },
            plan: { request in
                let arguments = request.arguments
                guard let fromX = arguments["fromX"]?.doubleValue, let fromY = arguments["fromY"]?.doubleValue,
                      let toX = arguments["toX"]?.doubleValue, let toY = arguments["toY"]?.doubleValue else {
                    return .failure(ToolResolutionError(message: "needs fromX/fromY/toX/toY"))
                }
                let from = screenPoint(fromX, fromY, request)
                let to = screenPoint(toX, toY, request)
                return .success(UIPlan(
                    operation: .drag(
                        from: windowPixels(from, request),
                        to: windowPixels(to, request),
                        durationMilliseconds: nil,
                        steps: nil
                    ),
                    bundleID: arguments["bundleID"]?.stringValue,
                    actuation: to,
                    movesPointer: false,
                    reportsWindow: false
                ))
            }
        ),
    ]

    private static func click(_ kind: UIClickKind, verb: String, headline: @escaping @Sendable (String?) -> String) -> UIToolDefinition {
        UIToolDefinition(
            name: kind.rawValue,
            description: "\(verb) an element, a point, or a described target without moving the user's cursor. Prefer elementID from screen.observe; use describe for targets missing from the element list.",
            schema: objectSchema([:], target: true),
            headline: headline,
            plan: { request in
                await resolveTarget(request).map { resolved in
                    UIPlan(
                        operation: kind.operation(windowPixels(resolved.target, request)),
                        bundleID: resolved.bundleID,
                        actuation: resolved.target.point,
                        actuationLabel: resolved.target.label,
                        note: resolved.note,
                        realInput: .click(kind)
                    )
                }
            }
        )
    }
}

private let directions = ["up", "down", "left", "right"]

private let targetSchemaProperties: [String: JSONValue] = [
    "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
    "x": .object(["type": .string("number"), "description": .string("Pixel in the latest screen.observe screenshot, from its top-left corner; used when elementID is absent")]),
    "y": .object(["type": .string("number")]),
    "label": .object(["type": .string("string"), "description": .string("Accessible label text to match")]),
    "describe": .object(["type": .string("string"), "description": .string("When the target has no element id: describe it for this Mac's click model. Quote its visible text or name its icon, say where it is relative to nearby controls, and say what it does, e.g. \"gear icon at the top right of the sidebar, opens the action menu\".")]),
    "bundleID": .object(["type": .string("string"), "description": .string("App to claim and target")]),
]

private func objectSchema(_ properties: [String: JSONValue], required: [String] = [], target: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object((target ? targetSchemaProperties : [:]).merging(properties) { _, new in new }),
    ]
    if !required.isEmpty {
        fields["required"] = .array(required.map { .string($0) })
    }
    return .object(fields)
}

private struct ResolvedTarget {
    let target: ComputerTarget
    let bundleID: String?
    var note: String?
}

private func staleElement(_ elementID: String) -> ToolResolutionError {
    ToolResolutionError(message: "element \(elementID) is stale or unknown — run screen.observe again")
}

private func resolveTarget(_ request: UIPlanRequest) async -> Result<ResolvedTarget, ToolResolutionError> {
    let args = request.arguments
    let observations = request.observations
    if let elementID = args["elementID"]?.stringValue {
        guard let element = observations.resolveElement(elementID, runID: request.runID) else {
            return .failure(staleElement(elementID))
        }
        return .success(ResolvedTarget(
            target: .element(id: element.id, label: element.label.nilIfEmpty, point: ComputerCoordinates(x: element.frame.midX, y: element.frame.midY)),
            bundleID: observations.snapshot(runID: request.runID)?.window?.bundleID
        ))
    }
    if let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
        let screen = screenPoint(x, y, request)
        return .success(ResolvedTarget(
            target: args["label"]?.stringValue.map { ComputerTarget.label($0, point: screen) } ?? ComputerTarget.point(screen),
            bundleID: args["bundleID"]?.stringValue
        ))
    }
    if let description = args["describe"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
        return await locateDescribed(description, request)
    }
    if let label = args["label"]?.stringValue {
        return .success(ResolvedTarget(target: .label(label, point: nil), bundleID: args["bundleID"]?.stringValue))
    }
    return .failure(ToolResolutionError(message: "needs elementID, x/y, or label"))
}

private func locateDescribed(_ description: String, _ request: UIPlanRequest) async -> Result<ResolvedTarget, ToolResolutionError> {
    guard let locate = request.locate else {
        return .failure(ToolResolutionError(message: "describe needs this Mac's click model, which isn't downloaded. Use elementID or x/y instead."))
    }
    guard let snapshot = request.observations.snapshot(runID: request.runID),
          let screenshot = snapshot.screenshotData,
          let bounds = snapshot.windowBoundsAX else {
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
    let coordinates = ComputerCoordinates(x: point.x, y: point.y)
    return .success(ResolvedTarget(
        target: element.map { ComputerTarget.element(id: $0.id, label: $0.label.nilIfEmpty ?? description, point: coordinates) }
            ?? ComputerTarget.label(description, point: coordinates),
        bundleID: snapshot.window?.bundleID,
        note: note
    ))
}

private func windowPixels(_ target: ComputerTarget, _ request: UIPlanRequest) -> ComputerTarget {
    target.mappingPoint { windowPixels($0, request) }
}

private func windowPixels(_ point: ComputerCoordinates, _ request: UIPlanRequest) -> ComputerCoordinates {
    guard let snapshot = request.observations.snapshot(runID: request.runID), let bounds = snapshot.windowBoundsAX else { return point }
    return ComputerCoordinates(x: (point.x - bounds.minX) * snapshot.driverScale, y: (point.y - bounds.minY) * snapshot.driverScale)
}

private func screenPoint(_ x: Double, _ y: Double, _ request: UIPlanRequest) -> ComputerCoordinates {
    let point = request.observations.screenPoint(fromImage: CGPoint(x: x, y: y), runID: request.runID)
    return ComputerCoordinates(x: point.x, y: point.y)
}

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
private func raise(_ window: ScreenWindowTarget, in pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    let match = AXQuery.elements(app, kAXWindowsAttribute).first { AXQuery.string($0, kAXTitleAttribute) == window.title }
    guard let match else { return }
    AXUIElementPerformAction(match, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
}

@discardableResult
private func showActuation(_ onActuation: (@Sendable (CGPoint, String?) -> Void)?, at point: CGPoint, label: String?, movesPointer: Bool = false) async -> Bool {
    onActuation?(point, label)
    let arrived = movesPointer && onActuation != nil ? await glidePointer(to: point) : false
    guard onActuation != nil || movesPointer else { return false }
    try? await Task.sleep(for: .milliseconds(movesPointer ? 120 : 350))
    return arrived
}

private func glidePointer(to target: CGPoint) async -> Bool {
    guard var expected = CGEvent(source: nil)?.location else { return false }
    let start = expected
    let steps = 12
    for step in 1...steps {
        guard let now = CGEvent(source: nil)?.location, hypot(now.x - expected.x, now.y - expected.y) < 3 else { return false }
        let progress = Double(step) / Double(steps)
        let eased = progress * progress * (3 - 2 * progress)
        expected = CGPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: expected, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func pointerClick(at point: CGPoint, kind: UIClickKind) async {
    let right = kind == .rightClick
    let button: CGMouseButton = right ? .right : .left
    for click in 1...(kind == .doubleClick ? 2 : 1) {
        for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(60))
    }
    try? await Task.sleep(for: .milliseconds(400))
}

private func keyboardPress(_ key: String, modifiers: [String]?) -> Bool {
    let codes: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]
    guard let code = codes[key.lowercased()] else { return false }
    var flags: CGEventFlags = []
    for modifier in modifiers ?? [] {
        switch modifier.lowercased() {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default: return false
        }
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    return true
}

private func targetResources(_ bundleID: String?) -> Set<BackgroundTaskResource> {
    bundleID.map { [.application($0.lowercased())] } ?? []
}

private func verifiedResult(
    _ call: ToolCall, _ result: StepResult, worker: ScreenWorkerHandle,
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

private struct UIToolExecutor: ToolExecutor {
    let definition: UIToolDefinition
    let worker: ToolWorkerContext
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?
    let locate: LocateTarget?

    var spec: ToolSpec {
        ToolSpec(
            name: definition.name,
            description: definition.description,
            inputSchema: definition.schema,
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let request = UIPlanRequest(arguments: call.arguments, runID: context.runID, observations: worker.observations, locate: locate)
        let plan: UIPlan
        switch await definition.plan(request) {
        case .success(let built): plan = built
        case .failure(let error): return .text(call.id, "\(definition.name): \(error.message)", isError: true)
        }
        let action = ComputerAction(stepID: call.id, operation: plan.operation)
        await bringForward(plan.bundleID, observations: worker.observations, context: context)
        let onActuation = onActuation
        let observations = worker.observations
        return try await worker.withWorker(runID: context.runID, resources: targetResources(plan.bundleID)) { handle in
            var arrived = false
            if let point = plan.actuation {
                arrived = await showActuation(
                    onActuation, at: CGPoint(x: point.x, y: point.y), label: plan.actuationLabel,
                    movesPointer: plan.movesPointer && !context.unattended
                )
            }
            let result: StepResult
            if let handled = await performRealInput(plan, arrived: arrived, unattended: context.unattended, actuating: onActuation != nil) {
                result = StepResult(stepID: call.id, success: true, message: handled)
            } else {
                result = try await handle.execute(action)
            }
            guard plan.reportsWindow else { return .text(call.id, result.message, isError: !result.success) }
            return await verifiedResult(call, result, worker: handle, observations: observations, runID: context.runID, located: plan.note)
        }
    }

    private func performRealInput(_ plan: UIPlan, arrived: Bool, unattended: Bool, actuating: Bool) async -> String? {
        switch plan.realInput {
        case .click(let kind)?:
            guard arrived, let point = plan.actuation else { return nil }
            await pointerClick(at: CGPoint(x: point.x, y: point.y), kind: kind)
            return "Clicked \(plan.actuationLabel ?? "the target") with the pointer."
        case .key(let key, let modifiers)?:
            guard !unattended, actuating, keyboardPress(key, modifiers: modifiers) else { return nil }
            try? await Task.sleep(for: .milliseconds(150))
            return "Pressed \(key)."
        case nil:
            return nil
        }
    }
}

private enum UIStepsError: LocalizedError {
    case targetNotFrontmost

    var errorDescription: String? {
        "The app I was using is no longer in front, so I stopped."
    }
}

private func targetProcessID(_ bundleID: String?, observations: AgentObservationStore, runID: UUID) async -> pid_t? {
    if let pid = observations.snapshot(runID: runID)?.window?.processID { return pid }
    guard let bundleID else { return nil }
    return await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier }
}

private struct UIStepsExecutor: ToolExecutor {
    static let name = "ui.steps"

    let worker: ToolWorkerContext
    let onActuation: (@Sendable (CGPoint, String?) -> Void)?

    private struct PlannedStep {
        let operation: ComputerAction.Operation
        let target: ComputerTarget?
    }

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Run several actions in one call when you already know them, then see the window once: for example click a row, press return, type a name, press return. Steps run in order and stop at the first failure. Element ids come from the latest screen.observe and stay valid through the batch, so end the batch at a step that opens a new screen and observe before going on.",
            inputSchema: objectSchema([
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
                            "direction": .object(["type": .string("string"), "enum": .array(directions.map { .string($0) })]),
                            "amount": .object(["type": .string("number")]),
                        ]),
                        "required": .array([.string("action")]),
                    ]),
                ]),
            ], required: ["steps"]),
            tier: .yellow,
            surfaces: [.agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let steps = call.arguments["steps"]?.arrayValue, !steps.isEmpty, steps.count <= 20 else {
            return .text(call.id, "ui.steps: needs 1 to 20 steps", isError: true)
        }
        var planned: [PlannedStep] = []
        for (index, step) in steps.enumerated() {
            let request = UIPlanRequest(arguments: step, runID: context.runID, observations: worker.observations, locate: nil)
            switch await plannedStep(request) {
            case .success(let next): planned.append(next)
            case .failure(let error): return .text(call.id, "ui.steps: step \(index + 1): \(error.message)", isError: true)
            }
        }
        let bundleID = call.arguments["bundleID"]?.stringValue ?? worker.observations.snapshot(runID: context.runID)?.window?.bundleID
        await bringForward(bundleID, observations: worker.observations, context: context)
        let observations = worker.observations
        let onActuation = onActuation
        let targetPID = await targetProcessID(bundleID, observations: observations, runID: context.runID)
        return try await worker.withWorker(runID: context.runID, resources: targetResources(bundleID)) { handle in
            guard !context.unattended else {
                let result = try await handle.execute(ComputerAction(stepID: call.id, operation: .steps(planned.map(\.operation))))
                return await verifiedResult(call, result, worker: handle, observations: observations, runID: context.runID)
            }
            var last: StepResult?
            for (index, step) in planned.enumerated() {
                try Task.checkCancellation()
                var arrived = false
                if let point = step.target?.point {
                    arrived = await showActuation(onActuation, at: CGPoint(x: point.x, y: point.y), label: step.target?.label, movesPointer: true)
                }
                if let handled = try await performWithPointer(step.operation, at: step.target?.point, arrived: arrived, targetPID: targetPID) {
                    last = StepResult(stepID: "\(call.id)-\(index)", success: true, message: handled)
                    continue
                }
                let result = try await handle.execute(ComputerAction(stepID: "\(call.id)-\(index)", operation: step.operation))
                guard result.success else { return .text(call.id, "ui.steps: step \(index + 1): \(result.message)", isError: true) }
                last = result
            }
            guard let last else { return .text(call.id, "ui.steps: needs 1 to 20 steps", isError: true) }
            return await verifiedResult(call, last, worker: handle, observations: observations, runID: context.runID)
        }
    }

    private func performWithPointer(_ operation: ComputerAction.Operation, at point: ComputerCoordinates?, arrived: Bool, targetPID: pid_t?) async throws -> String? {
        switch operation {
        case .click, .doubleClick, .rightClick:
            guard arrived, let point else { return nil }
            try await requireFrontmost(targetPID)
            let kind: UIClickKind = switch operation {
            case .doubleClick: .doubleClick
            case .rightClick: .rightClick
            default: .click
            }
            await pointerClick(at: CGPoint(x: point.x, y: point.y), kind: kind)
            return "Clicked with the pointer."
        case .pressKey(let key, let modifiers, _):
            guard onActuation != nil else { return nil }
            try await requireFrontmost(targetPID)
            guard keyboardPress(key, modifiers: modifiers) else { return nil }
            try? await Task.sleep(for: .milliseconds(150))
            return "Pressed \(key)."
        default:
            return nil
        }
    }

    private func requireFrontmost(_ targetPID: pid_t?) async throws {
        guard let targetPID else { return }
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontmost == targetPID else { throw UIStepsError.targetNotFrontmost }
    }

    private func plannedStep(_ request: UIPlanRequest) async -> Result<PlannedStep, ToolResolutionError> {
        let step = request.arguments
        let targeted = step["elementID"] != nil || (step["x"] != nil && step["y"] != nil)
        let resolved: ResolvedTarget? = targeted ? try? await resolveTarget(request).get() : nil
        if targeted, resolved == nil {
            return .failure(ToolResolutionError(message: "element \(step["elementID"]?.stringValue ?? "at x/y") is stale or unknown — run screen.observe again"))
        }
        let pointer = resolved.map { windowPixels($0.target, request) }
        func planned(_ operation: ComputerAction.Operation) -> Result<PlannedStep, ToolResolutionError> {
            .success(PlannedStep(operation: operation, target: resolved?.target))
        }
        switch step["action"]?.stringValue {
        case "click", "doubleclick", "rightclick":
            guard let pointer else { return .failure(ToolResolutionError(message: "needs elementID or x/y")) }
            switch step["action"]?.stringValue {
            case "doubleclick": return planned(.doubleClick(pointer))
            case "rightclick": return planned(.rightClick(pointer))
            default: return planned(.click(pointer))
            }
        case "type":
            guard let text = step["text"]?.stringValue else { return .failure(ToolResolutionError(message: "type needs text")) }
            return planned(.typeText(text: text, target: pointer))
        case "setValue":
            guard let value = step["value"]?.stringValue, let id = resolved?.target.id else {
                return .failure(ToolResolutionError(message: "setValue needs elementID and value"))
            }
            return planned(.setValue(value: value, target: .element(id: id, label: resolved?.target.label, point: nil)))
        case "key":
            guard let key = step["key"]?.stringValue else { return .failure(ToolResolutionError(message: "key needs key")) }
            return planned(.pressKey(key: key.lowercased(), modifiers: step["modifiers"]?.arrayValue?.compactMap(\.stringValue), target: pointer))
        case "hotkey":
            guard let keys = step["keys"]?.arrayValue?.compactMap(\.stringValue), !keys.isEmpty else { return .failure(ToolResolutionError(message: "hotkey needs keys")) }
            return planned(.hotkey(keys: keys.map { $0.lowercased() }, target: pointer))
        case "scroll":
            guard let direction = step["direction"]?.stringValue.flatMap(ComputerAction.Direction.init(rawValue:)) else {
                return .failure(ToolResolutionError(message: "scroll needs a direction"))
            }
            return planned(.scroll(direction: direction, amount: step["amount"]?.doubleValue.map { Int($0) } ?? 3, by: nil, target: pointer))
        default:
            return .failure(ToolResolutionError(message: "unknown action"))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
