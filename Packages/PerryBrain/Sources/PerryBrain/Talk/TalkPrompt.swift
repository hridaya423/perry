import Foundation

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

public enum TalkPrompt {
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
