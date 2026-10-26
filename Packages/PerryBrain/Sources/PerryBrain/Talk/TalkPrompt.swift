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

    public init(elements: [ObservedElement], prefix: String = "e") {
        entries = elements.enumerated().map { Entry(compactID: "\(prefix)\($0.offset + 1)", element: $0.element) }
    }

    public var validIDs: Set<String> { Set(entries.map(\.compactID)) }

    public func element(for compactID: String) -> ObservedElement? {
        entries.first { $0.compactID == compactID }?.element
    }

    public func compactID(forElementID elementID: String) -> String? {
        entries.first { $0.element.id == elementID }?.compactID
    }
}

/// Per-turn input for Talk: the compact element index, deixis bindings,
/// memory, and the active app's skill. The rules live in PromptAssembler.
public enum TalkPrompt {
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
}
