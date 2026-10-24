import AppKit
import Foundation
import PerryBrain
import PerryGuide

/// Observation tools (`screen.observe`, `screen.desktop`, `screen.zoom`,
/// `clipboard.read`). Observation is safe on every surface; nothing here
/// moves the pointer or steals focus — capture goes through the background
/// Cua worker.
struct ScreenTools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [
            ScreenObserveExecutor(workers: workers, lease: lease, observations: observations),
            ScreenDesktopExecutor(workers: workers, lease: lease, observations: observations),
            ScreenZoomExecutor(workers: workers, lease: lease, observations: observations),
            ClipboardReadExecutor(),
        ]
    }
}

private struct ScreenObserveExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "screen.observe",
            description: "Capture a window's accessibility tree and screenshot. Returns compact element ids for draw/act tools.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleID": .object(["type": .string("string"), "description": .string("Target app bundle id; defaults to the window captured for this run")]),
                    "windowTitle": .object(["type": .string("string")]),
                ]),
            ]),
            surfaces: [.talk, .guide, .agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let bundleID = call.arguments["bundleID"]?.stringValue
        let windowTitle = call.arguments["windowTitle"]?.stringValue
        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID, windowTitle: windowTitle)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: resources) { worker in
            let content = try await observeWindow(worker: worker, hint: hint, observations: observations, runID: context.runID)
            return ToolResult(callID: call.id, content: content)
        }
    }
}

private struct ScreenDesktopExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "screen.desktop",
            description: "Screenshot the selected window. Returns the image plus its window identity.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            surfaces: [.talk, .guide, .agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let hint = try observations.prepareCapture(runID: context.runID)
        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: []) { worker in
            let captured = try await worker.capture(target: hint)
            observations.setTarget(captured.target.hint, runID: context.runID)
            return ToolResult(
                callID: call.id,
                content: [
                    .text("\(captured.target.bundleID) — \(captured.target.title)"),
                    .image(data: captured.screenshotData, mimeType: captured.screenshotMIMEType),
                ]
            )
        }
    }
}

private struct ScreenZoomExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "screen.zoom",
            description: "Capture a window, cropped to a rect (x, y, w, h in window points).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleID": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "w": .object(["type": .string("number")]),
                    "h": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("x"), .string("y"), .string("w"), .string("h")]),
            ]),
            surfaces: [.talk, .guide, .agent],
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue,
              let w = args["w"]?.doubleValue, let h = args["h"]?.doubleValue, w > 0, h > 0 else {
            return .text(call.id, "screen.zoom: needs positive x, y, w, h", isError: true)
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let bundleID = args["bundleID"]?.stringValue

        // §3.5: a zoom crops the run's cached capture when it's for the same
        // window — a second zoom verifies against the exact frame the model
        // already reasoned about, and no second capture round-trips.
        if let cached = observations.snapshot(runID: context.runID),
           let shot = cached.screenshotData,
           let window = cached.window,
           bundleID == nil || bundleID!.caseInsensitiveCompare(window.bundleID) == .orderedSame,
           let data = ScreenCrop.jpeg(shot, rectInWindowPoints: rect, windowSizePoints: cached.windowBoundsAX?.size ?? CGSize(width: window.width, height: window.height)) {
            return ToolResult(
                callID: call.id,
                content: [
                    .text("\(window.bundleID) — \(window.title) @ (\(x),\(y),\(w),\(h)) [cached capture]"),
                    .image(data: data, mimeType: "image/jpeg"),
                ]
            )
        }

        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: resources) { worker in
            let captured = try await worker.capture(target: hint)
            observations.setTarget(captured.target.hint, runID: context.runID)
            guard let data = ScreenCrop.jpeg(
                captured.screenshotData,
                rectInWindowPoints: rect,
                windowSizePoints: CGSize(width: captured.target.width, height: captured.target.height)
            ) else {
                return .text(call.id, "screen.zoom: could not crop capture", isError: true)
            }
            return ToolResult(
                callID: call.id,
                content: [
                    .text("\(captured.target.bundleID) — \(captured.target.title) @ (\(x),\(y),\(w),\(h))"),
                    .image(data: data, mimeType: "image/jpeg"),
                ]
            )
        }
    }

}

/// Crop args are window points; the capture is pixels — scale the rect so
/// Retina captures don't crop the wrong region.
enum ScreenCrop {
    static func jpeg(_ data: Data, rectInWindowPoints rect: CGRect, windowSizePoints: CGSize) -> Data? {
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = windowSizePoints.width > 0 ? CGFloat(image.width) / windowSizePoints.width : 1
        let pixel = CGRect(
            x: rect.origin.x * scale, y: rect.origin.y * scale,
            width: rect.width * scale, height: rect.height * scale
        ).integral
        guard pixel.width > 0, pixel.height > 0,
              let cropped = image.cropping(to: pixel) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

private struct ClipboardReadExecutor: ToolExecutor {
    var spec: ToolSpec {
        ToolSpec(
            name: "clipboard.read",
            description: "Read the current clipboard text.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            surfaces: [.talk, .guide, .agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        return .text(call.id, text ?? "(clipboard has no text)")
    }
}

func observeWindow(worker: CuaWorkerHandle, hint: CuaTargetHint, observations: AgentObservationStore, runID: UUID) async throws -> [ModelContentPart] {
    let captured = try await worker.capture(target: hint)
    let elements = (captured.accessibilitySnapshotModel?.elements ?? [])
        .filter { $0.sensitivity != .secure }
        .map { element in
            ObservedElement(
                id: element.stableID,
                role: element.rawRole ?? "AX\(element.role.rawValue)",
                label: element.label ?? "",
                frame: CGRect(
                    x: element.frame.x, y: element.frame.y,
                    width: element.frame.width, height: element.frame.height
                ),
                windowID: Int(captured.target.windowID)
            )
        }
    let index = ElementIndex(elements: elements, prefix: observations.nextIDPrefix(runID: runID))
    observations.store(
        AgentObservationStore.Snapshot(
            index: index,
            window: captured.target,
            screenshotData: captured.screenshotData,
            windowBoundsAX: CGRect(
                x: captured.target.x, y: captured.target.y,
                width: captured.target.width, height: captured.target.height
            )
        ),
        runID: runID
    )
    let summary: JSONValue = .object([
        "app": .string(captured.target.bundleID),
        "window": .string(captured.target.title),
        "onScreen": .bool(captured.target.isOnScreen),
        "elements": .array(index.entries.map { entry in
            .object([
                "id": .string(entry.compactID),
                "role": .string(entry.element.role),
                "label": .string(entry.element.label),
                "x": .number(entry.element.frame.origin.x),
                "y": .number(entry.element.frame.origin.y),
                "w": .number(entry.element.frame.width),
                "h": .number(entry.element.frame.height),
            ])
        }),
    ])
    return [
        .text(renderObservation(summary)),
        .image(data: captured.screenshotData, mimeType: captured.screenshotMIMEType)
    ]
}

private func renderObservation(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}
