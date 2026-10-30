import Foundation
import OSLog

public enum ToolSurface: String, Sendable, Hashable {
    case talk, guide, agent, suggestions
}

public enum ToolGate {
    public static let observeTools: Set<String> = [
        "screen.observe", "screen.desktop", "screen.zoom",
        "document.read", "clipboard.read",
    ]
    public static let drawTools: Set<String> = [
        "point", "ring", "arrow", "underline", "caption", "path", "clear",
    ]

    private static let logger = Logger(subsystem: "ai.perry.brain", category: "tool-gate")

    public static func allows(_ name: String, on surface: ToolSurface) -> Bool {
        switch surface {
        case .agent: return true
        case .suggestions: return name == "integrations.list" || name == "integrations.read"
        case .talk: return true
        case .guide: return observeTools.contains(name) || drawTools.contains(name)
        }
    }

    public static func filter(_ specs: [ToolSpec], for surface: ToolSurface) -> [ToolSpec] {
        specs.filter { allows($0.name, on: surface) }
    }

    /// Guide never acts: calls outside the surface's allowlist are rejected and logged
    /// (tool name only — arguments may carry sensitive content).
    public static func check(_ call: ToolCall, on surface: ToolSurface) -> ToolRejection? {
        guard !allows(call.name, on: surface) else { return nil }
        logger.warning("rejected tool call on \(surface.rawValue): \(call.name, privacy: .public)")
        return ToolRejection(callID: call.id, toolName: call.name, surface: surface)
    }
}

extension ToolSpec {
    /// Talk does what the user asks, so it offers every agent tool.
    public func isOffered(on surface: ToolSurface) -> Bool {
        surfaces.contains(surface) || (surface == .talk && surfaces.contains(.agent))
    }
}

public struct ToolRejection: Error, Sendable, Equatable {
    public var callID: String
    public var toolName: String
    public var surface: ToolSurface

    public init(callID: String, toolName: String, surface: ToolSurface) {
        self.callID = callID
        self.toolName = toolName
        self.surface = surface
    }
}
