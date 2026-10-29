import Foundation

public struct DrawCommand: Sendable, Equatable {
    public enum Verb: String, Sendable, CaseIterable {
        case point, ring, arrow, underline, caption, clear
    }

    public var verb: Verb
    public var elementID: String?
    public var label: String?
    /// The element's frame in screen points (top-left origin), when the
    /// emitter resolved the id against a later screen read.
    public var frame: CGRect?
    /// Frames of the controls around the element, same space as `frame`.
    public var nearbyFrames: [CGRect] = []

    public init(verb: Verb, elementID: String? = nil, label: String? = nil, frame: CGRect? = nil) {
        self.verb = verb
        self.elementID = elementID
        self.label = label
        self.frame = frame
    }
}

public struct InlineMarkupParser: Sendable {
    private static let open = "\u{27E6}"
    private static let close = "\u{27E7}"
    private static let bufferLimit = 200

    private let validElementIDs: Set<String>
    private var buffer = ""
    private var buffering = false

    public init(validElementIDs: Set<String>) {
        self.validElementIDs = validElementIDs
    }

    public mutating func feed(_ chunk: String) -> (text: String, commands: [DrawCommand]) {
        var text = ""
        var commands: [DrawCommand] = []
        for ch in chunk {
            if !buffering {
                if String(ch) == Self.open {
                    buffering = true
                    buffer = ""
                } else {
                    text.append(ch)
                }
                continue
            }
            if String(ch) == Self.close {
                let (tagText, command) = resolveTag(buffer)
                text += tagText
                if let command { commands.append(command) }
                buffering = false
                buffer = ""
                continue
            }
            buffer.append(ch)
            if buffer.count > Self.bufferLimit {
                text += Self.open + buffer
                buffering = false
                buffer = ""
            }
        }
        return (text, commands)
    }

    public mutating func finish() -> (text: String, commands: [DrawCommand]) {
        defer { buffer = ""; buffering = false }
        guard buffering else { return ("", []) }
        return (Self.open + buffer, [])
    }

    private func resolveTag(_ inner: String) -> (text: String, command: DrawCommand?) {
        var rest = inner.drop { $0 == " " || $0 == "\t" }
        var verbToken = ""
        while let ch = rest.first, ch != " ", ch != "\t", ch != "\"" {
            verbToken.append(ch)
            rest = rest.dropFirst()
        }
        rest = rest.drop { $0 == " " || $0 == "\t" }

        var target: String?
        var label: String?
        if rest.first == "\"" {
            label = quoted(&rest)
        } else if !rest.isEmpty {
            var token = ""
            while let ch = rest.first, ch.isTargetCharacter {
                token.append(ch)
                rest = rest.dropFirst()
            }
            target = token.isEmpty ? nil : token
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.first == "\"" {
                label = quoted(&rest)
            }
        }

        guard let verb = DrawCommand.Verb(rawValue: verbToken) else {
            return (label ?? "", nil)
        }
        if verb == .clear {
            return (label ?? "", DrawCommand(verb: .clear, label: label))
        }
        guard let target, validElementIDs.contains(target) else {
            return (label ?? "", nil)
        }
        return (label ?? "", DrawCommand(verb: verb, elementID: target, label: label))
    }

    private func quoted(_ rest: inout Substring) -> String? {
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var value = ""
        while let ch = rest.first {
            rest = rest.dropFirst()
            if ch == "\"" { return value }
            value.append(ch)
        }
        return value
    }
}

extension Character {
    fileprivate var isTargetCharacter: Bool {
        guard let byte = asciiValue else { return false }
        return (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || self == "_" || self == "." || self == "-"
    }
}
