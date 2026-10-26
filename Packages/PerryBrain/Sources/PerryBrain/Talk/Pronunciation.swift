import Foundation

public struct Pronunciation: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case user
        case learned
    }

    public var written: String
    public var spoken: String
    public var source: Source

    public var id: String { written.lowercased() }

    public init(written: String, spoken: String, source: Source = .user) {
        self.written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        self.spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }
}

public struct PronunciationStore: Sendable {
    private let fileURL: URL?

    public init(directory: URL?) {
        fileURL = directory?.appendingPathComponent("pronunciations.json")
    }

    public func entries() -> [Pronunciation] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Pronunciation].self, from: data)) ?? []
    }

    public func set(_ entry: Pronunciation) throws {
        guard !entry.written.isEmpty, !entry.spoken.isEmpty else { return }
        var all = entries().filter { $0.id != entry.id }
        all.append(entry)
        try save(all.sorted { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending })
    }

    public func remove(written: String) throws {
        try save(entries().filter { $0.id != written.lowercased() })
    }

    private func save(_ entries: [Pronunciation]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    public static func respell(_ text: String, with entries: [Pronunciation]) -> String {
        entries.sorted { $0.written.count > $1.written.count }.reduce(text) { text, entry in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: entry.written) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: entry.spoken))
        }
    }
}
