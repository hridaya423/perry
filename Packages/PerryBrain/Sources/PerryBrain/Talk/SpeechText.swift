import Foundation

public enum SpeechText {
    public struct Stream: Sendable {
        private var inFence = false

        public init() {}

        public mutating func next(_ text: String, spellNumbers: Bool = false) -> String {
            var lines: [String] = []
            for raw in text.components(separatedBy: .newlines) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") { inFence.toggle(); continue }
                if inFence || line.allSatisfy({ "-=*_|: ".contains($0) }) { continue }
                line = line.replacing(#/^#{1,6}\s+/#, with: "")
                line = line.replacing(#/^(?:[-*+•]|\d{1,2}[.)])\s+/#, with: "")
                line = line.replacing(#/^>\s*/#, with: "")
                lines.append(line)
            }
            return SpeechText.speakable(lines, spellNumbers: spellNumbers)
        }
    }

    public static func prepare(_ text: String, spellNumbers: Bool = false) -> String {
        var stream = Stream()
        return stream.next(text, spellNumbers: spellNumbers)
    }

    private static func speakable(_ lines: [String], spellNumbers: Bool) -> String {
        var spoken = lines.map(endSentence).joined(separator: " ")
        spoken = spoken.replacing(#/!?\[([^\]]+)\]\([^)]*\)/#) { String($0.1) }
        spoken = spoken.replacing(#/https?://(?:www\.)?([^/\s)]+)[^\s)]*/#) { spokenHost(String($0.1)) }
        spoken = spoken.replacing(#/(?:~|/Users/[^/\s]+)?(?:/[\w.\- ]+)+/([\w.\-]+\.\w+)/#) { String($0.1) }
        spoken = spoken.replacing(#/(\*\*|__|\*|`)(.+?)\1/#) { String($0.2) }
        spoken = spoken.replacing("`", with: "")
        spoken = expandSymbols(spoken)
        if spellNumbers { spoken = expandNumbers(spoken) }
        return spoken.replacing(#/\s{2,}/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func endSentence(_ line: String) -> String {
        guard let last = line.last, !".?!…:;,".contains(last) else { return line }
        return line + "."
    }

    private static func spokenHost(_ host: String) -> String {
        host.split(separator: ".").joined(separator: " dot ")
    }

    private static let keys: [(String, String)] = [
        ("⌘", "Command "), ("⌥", "Option "), ("⌃", "Control "), ("⇧", "Shift "),
        ("↩", "Return "), ("⎋", "Escape "), ("⌫", "Delete "), ("→", " to "), ("←", " from "),
        (" & ", " and "), ("≈", "about "), ("±", "plus or minus "), ("°", " degrees"),
    ]

    private static func expandSymbols(_ text: String) -> String {
        var text = text
        for (symbol, word) in keys { text = text.replacing(symbol, with: word) }
        text = text.replacing(#/(\d)\s?%/#) { "\($0.1) percent" }
        text = text.replacing(#/\$(\d[\d,]*(?:\.\d+)?)([kKmMbB])?\b/#) { match in
            let scale = match.2.map { ["k": " thousand", "m": " million", "b": " billion"][$0.lowercased()] ?? "" } ?? ""
            return "\(match.1)\(scale) dollars"
        }
        text = text.replacing(#/(\d)\s?–\s?(\d)/#) { "\($0.1) to \($0.2)" }
        text = text.replacing(#/\be\.g\.\s?/#, with: "for example ")
        text = text.replacing(#/\bi\.e\.\s?/#, with: "that is ")
        text = text.replacing(#/\betc\./#, with: "and so on.")
        return text
    }

    private static let spellOut: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static func expandNumbers(_ text: String) -> String {
        text.replacing(#/\b\d{1,3}(?:,\d{3})+\b|\b\d+(?:\.\d+)?\b/#) { match in
            let digits = String(match.0).replacing(",", with: "")
            if digits.count == 4, !digits.contains("."), let year = Int(digits), (1900...2099).contains(year) {
                return spokenYear(year)
            }
            guard let value = Double(digits) else { return String(match.0) }
            return spellOut.string(from: NSNumber(value: value)) ?? String(match.0)
        }
    }

    private static func spokenYear(_ year: Int) -> String {
        let high = year / 100, low = year % 100
        if year % 1000 < 10 && year >= 2000 { return spellOut.string(from: NSNumber(value: year)) ?? "\(year)" }
        let tail = low == 0 ? "hundred" : low < 10 ? "oh " + (spellOut.string(from: NSNumber(value: low)) ?? "") : spellOut.string(from: NSNumber(value: low)) ?? ""
        return (spellOut.string(from: NSNumber(value: high)) ?? "") + " " + tail
    }
}
