import Foundation

public struct SentenceChunker: Sendable {
    private var buffer = ""
    private var started = false

    public init() {}

    private static let terminators: Set<Character> = [".", "?", "!", "…", "。", "！", "？"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "，", "；", "："]
    private static let firstClauseMinimum = 28

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        guard let cut = lastBoundary(in: buffer) ?? firstClauseCut() else { return [] }
        started = true
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

    private func firstClauseCut() -> String.Index? {
        guard !started else { return nil }
        var count = 0
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let next = buffer.index(after: index)
            count += 1
            if count >= Self.firstClauseMinimum, Self.clauseMarks.contains(buffer[index]),
               next < buffer.endIndex, buffer[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }

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
