import Foundation
import NaturalLanguage

public enum PersonalDetailKind: String, CaseIterable, Sendable {
    case secret = "SECRET"
    case email = "EMAIL"
    case card = "CARD"
    case iban = "IBAN"
    case phone = "PHONE"
    case address = "ADDRESS"
    case person = "PERSON"
}

public struct PersonalDetail: Equatable, Sendable {
    public let kind: PersonalDetailKind
    public let range: Range<String.Index>
}

public enum PersonalDetails {
    public static let note = "Some personal details in this conversation are replaced by placeholders such as ⟨PERSON_1⟩ or ⟨EMAIL_1⟩. Use each placeholder exactly as written, including in tool arguments. Never guess the real value."

    public static func find(in text: String, knownNames: [String] = []) -> [PersonalDetail] {
        var found: [PersonalDetail] = []
        func add(_ kind: PersonalDetailKind, _ range: Range<String.Index>) {
            guard !found.contains(where: { $0.range.overlaps(range) }) else { return }
            found.append(PersonalDetail(kind: kind, range: range))
        }
        for (kind, pattern, accepts) in patterns {
            for range in matches(pattern, in: text) where accepts(String(text[range])) {
                add(kind, range)
            }
        }
        for name in knownNames where name.count > 1 {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            for range in matches("(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", in: text) {
                add(.person, range)
            }
        }
        for range in personNames(in: text) {
            add(.person, range)
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let patterns: [(PersonalDetailKind, String, (String) -> Bool)] = [
        (.secret, #"(?<![A-Za-z0-9])(?:sk-(?:proj-)?[A-Za-z0-9_-]{16,}|sk_[A-Za-z0-9_]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})"#, { _ in true }),
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, { _ in true }),
        (.card, #"(?<![\d])\d(?:[ -]?\d){12,18}(?![\d])"#, { luhn($0) }),
        (.iban, #"(?<![A-Z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Z0-9])"#, { ibanChecksum($0) }),
        (.phone, #"(?<![\w+])\+?(?:\(\d{1,4}\)|\d{1,4})(?:[ .-]?(?:\(\d{1,4}\)|\d{2,5})){2,4}(?![\w])"#, { phoneLike($0) }),
        (.address, #"(?<![\d])\d{1,5}[A-Za-z]?\s+(?:[A-Z][a-z]+\s+){1,3}(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Dr|Boulevard|Blvd|Way|Court|Ct|Place|Pl|Terrace|Close|Crescent|Square)\b"#, { _ in true }),
    ]

    private static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    private static func personNames(in text: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard tag == .personalName, !text[range].contains("⟨") else { return true }
            if let last = ranges.last, text[last.upperBound..<range.lowerBound] == " " {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
            return true
        }
        return ranges.compactMap { withoutLeadingCommand($0, in: text) }
    }

    private static let commandVerbs: Set<String> = ["tell", "ask", "call", "email", "text", "message", "remind", "invite", "ping", "meet", "thank", "add", "send", "ring", "show", "write", "reply"]

    private static func withoutLeadingCommand(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        let before = text[..<range.lowerBound].last { !$0.isWhitespace }
        guard before == nil || ".!?:".contains(before!),
              let space = text[range].firstIndex(of: " "),
              commandVerbs.contains(text[range.lowerBound..<space].lowercased()) else { return range }
        let rest = text.index(after: space)..<range.upperBound
        return rest.isEmpty ? nil : rest
    }

    static func luhn(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            guard item.offset % 2 == 1 else { return total + item.element }
            let doubled = item.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    static func ibanChecksum(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let value = character.wholeNumberValue ?? character.asciiValue.map({ Int($0) - 55 }) else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    static func phoneLike(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isNumber).count
        guard (9...15).contains(digits) else { return false }
        if candidate.hasPrefix("+") || candidate.contains(where: { ".-()".contains($0) }) { return true }
        return (2...3).contains(candidate.split(separator: " ").count)
    }
}

public final class Redactor: @unchecked Sendable {
    private let lock = NSLock()
    private let knownNames: [String]
    private var placeholders: [String: String] = [:]
    private var originals: [String: String] = [:]
    private var counts: [PersonalDetailKind: Int] = [:]

    public init(knownNames: [String] = []) {
        self.knownNames = knownNames
    }

    public var hiddenCount: Int {
        lock.withLock { originals.count }
    }

    public func redact(_ text: String) -> String {
        let seen = lock.withLock { placeholders.keys.compactMap { $0.hasPrefix("PERSON:") ? originals[placeholders[$0]!] : nil } }
        let details = PersonalDetails.find(in: text, knownNames: seen + knownNames)
        guard !details.isEmpty else { return text }
        return lock.withLock {
            var result = text
            for detail in details.reversed() {
                let original = String(text[detail.range])
                result.replaceSubrange(detail.range, with: placeholder(for: original, kind: detail.kind))
            }
            return result
        }
    }

    public func restore(_ text: String) -> String {
        guard text.contains("⟨") else { return text }
        return lock.withLock {
            originals.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        value.mapStrings(redact)
    }

    public func restore(_ value: JSONValue) -> JSONValue {
        value.mapStrings(restore)
    }

    private func placeholder(for original: String, kind: PersonalDetailKind) -> String {
        let key = "\(kind.rawValue):\(original.lowercased())"
        if let existing = placeholders[key] { return existing }
        let number = (counts[kind] ?? 0) + 1
        counts[kind] = number
        let token = "⟨\(kind.rawValue)_\(number)⟩"
        placeholders[key] = token
        originals[token] = original
        return token
    }
}

public struct RestoringText {
    private let redactor: Redactor
    private var pending = ""

    public init(redactor: Redactor) {
        self.redactor = redactor
    }

    public mutating func feed(_ chunk: String) -> String {
        pending += chunk
        if let open = pending.lastIndex(of: "⟨"), !pending[open...].contains("⟩"), pending.distance(from: open, to: pending.endIndex) < 24 {
            let ready = redactor.restore(String(pending[..<open]))
            pending = String(pending[open...])
            return ready
        }
        return flush()
    }

    public mutating func flush() -> String {
        defer { pending = "" }
        return redactor.restore(pending)
    }
}

extension JSONValue {
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let text): .string(transform(text))
        case .array(let items): .array(items.map { $0.mapStrings(transform) })
        case .object(let fields): .object(fields.mapValues { $0.mapStrings(transform) })
        default: self
        }
    }
}
