import Foundation

/// Maps observed elements to the compact ids ("e17") sent to the model, and back.
/// Deterministic by observation order so prompts are stable across re-renders.
/// Sensitive elements must be filtered by the caller before indexing —
/// ObservedElement carries no sensitivity flag by design (Phase 2a spec).
public struct ElementIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var compactID: String
        public var element: ObservedElement
    }

    public let entries: [Entry]

    public init(elements: [ObservedElement]) {
        entries = elements.enumerated().map { Entry(compactID: "e\($0.offset + 1)", element: $0.element) }
    }

    public var validIDs: Set<String> { Set(entries.map(\.compactID)) }

    public func element(for compactID: String) -> ObservedElement? {
        entries.first { $0.compactID == compactID }?.element
    }

    public func compactID(forElementID elementID: String) -> String? {
        entries.first { $0.element.id == elementID }?.compactID
    }
}

/// System prompt contract for Talk: compact element index, deixis bindings,
/// memory, and the active app's skill — plus the draw/act rules of the
/// `.talk` tool surface (point and describe, never act).
public enum TalkPrompt {
    /// Stable behavioral rules — safe to pin at thread start. Anything that
    /// changes between turns of a conversation belongs in `context` instead.
    public static var rules: String {
        """
        You are Perry, a screen-aware companion. The user holds a key, points at the \
        screen, and talks. Answer in short spoken sentences.

        Draw attention with: point, ring, arrow, underline, caption, path, clear — as tools \
        or inline ⟦verb e1 "label"⟧ tags referencing element ids supplied in the current turn. \
        You can point and describe, but never act on the user's behalf.
        """
    }

    /// Per-turn spatial payload: the observed element index, deixis bindings,
    /// memory, and the active app's skill. This is turn input, not
    /// instruction — providers with server-side threads can reuse a thread
    /// while this changes underneath it.
    public static func context(
        index: ElementIndex,
        bindings: [DeixisBinding] = [],
        memory: String? = nil,
        skill: String? = nil
    ) -> String {
        var parts: [String] = []
        if !index.entries.isEmpty {
            let lines = index.entries.map { entry in
                "\(entry.compactID) \(entry.element.role) \"\(entry.element.label)\" window \(entry.element.windowID)"
            }
            parts.append("Elements on screen:\n" + lines.joined(separator: "\n"))
        }
        let contextLines = DeixisResolver.contextLines(bindings)
        if !contextLines.isEmpty {
            parts.append("What the user pointed at:\n" + contextLines.joined(separator: "\n"))
        }
        if let memory, !memory.isEmpty {
            parts.append("Memory:\n" + memory)
        }
        if let skill, !skill.isEmpty {
            parts.append(skill)
        }
        return parts.joined(separator: "\n\n")
    }

    public static func system(
        index: ElementIndex,
        bindings: [DeixisBinding] = [],
        memory: String? = nil,
        skill: String? = nil
    ) -> String {
        let context = context(index: index, bindings: bindings, memory: memory, skill: skill)
        return context.isEmpty ? rules : rules + "\n\n" + context
    }
}
