import Foundation

/// Splits streamed text into speakable sentences. A boundary is a terminator
/// (.?!…。！？) followed by whitespace, or a newline itself. Only text up to
/// the last boundary in the buffer is emitted, so "3." isn't cut before a
/// "3.5" continuation arrives; finish() flushes the remainder.
public struct SentenceChunker: Sendable {
    private var buffer = ""

    public init() {}

    private static let terminators: Set<Character> = [".", "?", "!", "…", "。", "！", "？"]

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        guard let cut = lastBoundary(in: buffer) else { return [] }
        var sentences: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < cut {
            let next = buffer.index(after: index)
            if isBoundary(in: buffer, at: index, next: next) {
                emit(buffer[start..<next], into: &sentences)
                start = next
            }
            index = next
        }
        emit(buffer[start..<cut], into: &sentences)
        buffer = String(buffer[cut...])
        return sentences
    }

    public mutating func finish() -> String? {
        defer { buffer = "" }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Index just past the last commit boundary, if any.
    private func lastBoundary(in text: String) -> String.Index? {
        var last: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if isBoundary(in: text, at: index, next: next) {
                last = next
            }
            index = next
        }
        return last
    }

    private func isBoundary(in text: String, at index: String.Index, next: String.Index) -> Bool {
        let ch = text[index]
        if ch == "\n" { return true }
        guard Self.terminators.contains(ch), next < text.endIndex else { return false }
        return text[next].isWhitespace
    }

    private func emit(_ slice: Substring, into sentences: inout [String]) {
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sentences.append(trimmed)
        }
    }
}
