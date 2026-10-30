import AppKit
import Foundation
import PerryBrain
import PerryGuide

struct ScreenTools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore
    var skills: AppSkillLibrary?

    var executors: [any ToolExecutor] {
        let worker = ToolWorkerContext(workers: workers, lease: lease, observations: observations)
        return [
            ScreenObserveExecutor(worker: worker, skills: skills),
            ScreenDesktopExecutor(worker: worker),
            ScreenZoomExecutor(worker: worker),
            ClipboardReadExecutor(),
        ]
    }
}

private struct ScreenObserveExecutor: ToolExecutor {
    let worker: ToolWorkerContext
    let skills: AppSkillLibrary?

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
        let observations = worker.observations
        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID, windowTitle: windowTitle)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await worker.withWorker(runID: context.runID, resources: resources) { handle in
            var content = try await observeWindow(worker: handle, hint: hint, observations: observations, runID: context.runID)
            if context.surface == .agent,
               let skill = skills?.promptContext(for: observations.snapshot(runID: context.runID)?.window?.bundleID) {
                content.append(.text(skill))
            }
            return ToolResult(callID: call.id, content: content)
        }
    }
}

private struct ScreenDesktopExecutor: ToolExecutor {
    let worker: ToolWorkerContext

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
        let observations = worker.observations
        let hint = try observations.prepareCapture(runID: context.runID)
        return try await worker.withWorker(runID: context.runID) { handle in
            let captured = try await handle.capture(target: hint)
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
    let worker: ToolWorkerContext

    var spec: ToolSpec {
        ToolSpec(
            name: "screen.zoom",
            description: "Capture a window, cropped to a rect (x, y, w, h in the same screenshot pixels screen.observe reports).",
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
        let observations = worker.observations

        if let cached = observations.snapshot(runID: context.runID),
           let shot = cached.screenshotData,
           let window = cached.window,
           bundleID == nil || bundleID!.caseInsensitiveCompare(window.bundleID) == .orderedSame,
           let data = ScreenCrop.jpeg(shot, rectInWindowPoints: rect, windowSizePoints: cached.imageSize ?? CGSize(width: window.width, height: window.height)) {
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

        return try await worker.withWorker(runID: context.runID, resources: resources) { handle in
            let captured = try await handle.capture(target: hint)
            observations.setTarget(captured.target.hint, runID: context.runID)
            let image = ModelImage.fitting(captured.screenshotData, mimeType: captured.screenshotMIMEType)
            guard let data = ScreenCrop.jpeg(image.data, rectInWindowPoints: rect, windowSizePoints: image.size) else {
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
    PerfMark.mark("observe.begin")
    defer { PerfMark.mark("observe.end") }
    let captured = try await worker.capture(target: hint)
    let window = CGRect(x: captured.target.x, y: captured.target.y, width: captured.target.width, height: captured.target.height)
    let elements = (captured.accessibilitySnapshotModel?.elements ?? [])
        .filter { $0.sensitivity != .secure }
        .compactMap { element -> ObservedElement? in
            let detail = captured.elementDetails[element.stableID]
            let frame = CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
            let named = !(element.label ?? "").isEmpty || detail?.value != nil
            guard frame.intersects(window), named || !unlabeledContainers.contains(element.rawRole ?? "") else { return nil }
            return ObservedElement(element, windowID: Int(captured.target.windowID), detail: detail)
        }
    let index = ElementIndex(elements: elements, prefix: observations.nextIDPrefix(runID: runID))
    let image = ModelImage.fitting(captured.screenshotData, mimeType: captured.screenshotMIMEType)
    let snapshot = AgentObservationStore.Snapshot(
        index: index,
        window: captured.target,
        screenshotData: image.data,
        windowBoundsAX: window,
        imageSize: image.size,
        driverScale: window.width > 0 ? image.sourceWidth / window.width : 1
    )
    observations.store(snapshot, runID: runID)
    var summary: [String: JSONValue] = [
        "app": .string(captured.target.bundleID),
        "window": .string(captured.target.title),
        "onScreen": .bool(captured.target.isOnScreen),
        "coordinates": .string("x, y, w, h are pixels in the screenshot below, from its top-left corner; ui and zoom tools take the same pixels"),
        "elements": .array(index.entries.map { entry in
            let rect = snapshot.imageRect(fromScreen: entry.element.frame)
            var fields: [String: JSONValue] = [
                "id": .string(entry.compactID),
                "role": .string(entry.element.role),
                "label": .string(entry.element.label),
                "x": .number(rect.origin.x.rounded()),
                "y": .number(rect.origin.y.rounded()),
                "w": .number(rect.width.rounded()),
                "h": .number(rect.height.rounded()),
            ]
            if let value = entry.element.value { fields["value"] = .string(String(value.prefix(200))) }
            return .object(fields)
        }),
    ]
    if !captured.treeComplete {
        summary["complete"] = .string("no: the window's accessibility tree was cut short, so some controls are missing; use the screenshot")
    }
    return [
        .text(renderObservation(.object(summary))),
        .image(data: image.data, mimeType: image.mimeType)
    ]
}

enum ModelImage {
    static let maxLongEdge = 1568.0

    static func fitting(_ data: Data, mimeType: String, maxWidth: Double? = nil) -> (data: Data, mimeType: String, size: CGSize, sourceWidth: Double) {
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (data, mimeType, .zero, 0)
        }
        let source = CGSize(width: image.width, height: image.height)
        let scale = min(1, maxLongEdge / max(source.width, source.height), (maxWidth ?? source.width) / source.width)
        guard scale < 1 else { return (data, mimeType, source, source.width) }
        let size = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return (data, mimeType, source, source.width) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return (data, mimeType, source, source.width)
        }
        return (jpeg, "image/jpeg", size, source.width)
    }
}

private let unlabeledContainers: Set<String> = [
    "AXRow", "AXCell", "AXList", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXColumn",
]

private func renderObservation(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
}
