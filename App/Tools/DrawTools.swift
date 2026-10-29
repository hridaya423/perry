import AppKit
import Foundation
import PerryBrain
import PerryGuide
import PerryOverlay

/// The draw verbs (`point`, `ring`, `arrow`, `underline`, `caption`, `path`,
/// `clear`) as tool-host executors. Verb→overlay mapping mirrors
/// `TalkSession.draw` so marks look identical on every surface.
struct DrawTools {
    let overlayState: PerryCursorState
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [
            DrawVerbExecutor(verb: .point, overlayState: overlayState, observations: observations),
            DrawVerbExecutor(verb: .ring, overlayState: overlayState, observations: observations),
            DrawVerbExecutor(verb: .arrow, overlayState: overlayState, observations: observations),
            DrawVerbExecutor(verb: .underline, overlayState: overlayState, observations: observations),
            DrawVerbExecutor(verb: .caption, overlayState: overlayState, observations: observations),
            PathDrawExecutor(overlayState: overlayState, observations: observations),
            ClearDrawExecutor(overlayState: overlayState),
        ]
    }
}

/// Which draw verb is being rendered; `path` and `clear` have their own
/// executors since their arguments differ.
enum DrawVerb: String {
    case point, ring, arrow, underline, caption
}

private struct DrawVerbExecutor: ToolExecutor {
    let verb: DrawVerb
    let overlayState: PerryCursorState
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: verb.rawValue,
            description: "Draw a \(verb.rawValue) mark on an element (compact id like e12) or at x, y pixels in the latest screen.observe screenshot.",
            inputSchema: Self.schema,
            requiredCapabilities: [.tools, .vision]
        )
    }

    private static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "elementID": .object(["type": .string("string"), "description": .string("Compact element id from screen.observe, like e12")]),
            "x": .object(["type": .string("number"), "description": .string("Pixels in the latest screen.observe screenshot, from its top-left corner; used when elementID is absent")]),
            "y": .object(["type": .string("number")]),
            "label": .object(["type": .string("string")]),
            "duration": .object(["type": .string("number"), "description": .string("Seconds the mark stays visible (default 6)")]),
        ]),
    ])

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let args = call.arguments
        let label = args["label"]?.stringValue
        let duration = args["duration"]?.doubleValue ?? 6

        // Resolve the mark rect: elementID → observed frame (AX space), else
        // a small box around an explicit (x, y) point.
        let rect: CGRect
        if let elementID = args["elementID"]?.stringValue {
            guard let element = observations.resolveElement(elementID, runID: context.runID) else {
                return .text(call.id, "\(verb.rawValue): element \(elementID) is stale or unknown — run screen.observe again", isError: true)
            }
            rect = element.frame
        } else if let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
            let point = observations.screenPoint(fromImage: CGPoint(x: x, y: y), runID: context.runID)
            rect = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        } else {
            return .text(call.id, "\(verb.rawValue): needs elementID or x/y", isError: true)
        }

        // Observed frames are AX-space (top-left origin); overlays draw in
        // AppKit space — same conversion TalkSession uses.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let appKitRect = AXCoordinateConverter.appKitRect(
            axX: rect.origin.x, axY: rect.origin.y,
            width: rect.width, height: rect.height,
            primaryScreenMaxY: primaryMaxY
        )

        let overlay: PerryGuidanceOverlay
        switch verb {
        case .point:
            overlay = .pointMark(center: CGPoint(x: appKitRect.midX, y: appKitRect.midY), accentHex: "#34D399", caption: label, duration: duration)
        case .arrow:
            overlay = .arrowMark(to: appKitRect, accentHex: "#34D399", caption: label, duration: duration)
        case .underline:
            overlay = .underlineMark(below: appKitRect, accentHex: "#34D399", caption: label, duration: duration)
        case .ring, .caption:
            overlay = .ringMark(around: appKitRect, accentHex: "#34D399", caption: label, duration: duration)
        }

        await MainActor.run {
            overlayState.visualGuidanceOverlays.append(overlay)
        }
        return .text(call.id, "drew \(verb.rawValue)")
    }
}

private struct PathDrawExecutor: ToolExecutor {
    let overlayState: PerryCursorState
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "path",
            description: "Draw a freehand stroke through points given as pixels in the latest screen.observe screenshot.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "points": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "x": .object(["type": .string("number")]),
                                "y": .object(["type": .string("number")]),
                            ]),
                            "required": .array([.string("x"), .string("y")]),
                        ]),
                    ]),
                    "label": .object(["type": .string("string")]),
                    "duration": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("points")]),
            ]),
            requiredCapabilities: [.tools, .vision]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let points = call.arguments["points"]?.arrayValue?.compactMap { value -> CGPoint? in
            guard let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue else { return nil }
            let point = observations.screenPoint(fromImage: CGPoint(x: x, y: y), runID: context.runID)
            return CGPoint(x: point.x, y: primaryMaxY - point.y)
        } ?? []
        guard points.count >= 2 else {
            return .text(call.id, "path: needs at least 2 points", isError: true)
        }
        let overlay = PerryGuidanceOverlay.scribble(
            points: points,
            accentHex: "#34D399",
            lineWidth: 4,
            caption: call.arguments["label"]?.stringValue,
            duration: call.arguments["duration"]?.doubleValue ?? 6
        )
        await MainActor.run {
            overlayState.visualGuidanceOverlays.append(overlay)
        }
        return .text(call.id, "drew path (\(points.count) points)")
    }
}

private struct ClearDrawExecutor: ToolExecutor {
    let overlayState: PerryCursorState

    var spec: ToolSpec {
        ToolSpec(
            name: "clear",
            description: "Clear all drawn marks.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        )
    }

    func run(_ call: ToolCall, context _: ToolContext) async throws -> ToolResult {
        await MainActor.run {
            overlayState.visualGuidanceOverlays = []
        }
        return .text(call.id, "cleared")
    }
}
