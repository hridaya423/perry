import Foundation

/// Rolling local backup of final dictation transcripts: one JSONL file per
/// day under `directory`, pruned after `retentionDays` (7). Erasable —
/// dictation audio is never stored, only the inserted text.
public struct DictationBackupStore: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var at: Date
        public var text: String
        public var language: String?

        public init(at: Date, text: String, language: String? = nil) {
            self.at = at
            self.text = text
            self.language = language
        }
    }

    public static let retentionDays = 7

    private let directory: URL
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    /// Append a transcript to today's day-file. Empty text is not recorded.
    public func record(text: String, language: String? = nil, at: Date = Date()) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Entry(at: at, text: trimmed, language: language)
        let data = try JSONEncoder().encode(entry) + Data("\n".utf8)
        let url = dayURL(for: at)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        try prune(now: at)
    }

    /// All entries, oldest day first.
    public func entries() -> [Entry] {
        dayFiles().flatMap { url in
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
        }
    }

    /// Delete day-files older than the retention window.
    public func prune(now: Date = Date()) throws {
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now
        for file in dayFiles() where dayDate(for: file).map({ $0 < cutoff }) ?? false {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Remove the whole backup store (Memory & privacy "erase").
    public func eraseAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func dayURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return directory.appendingPathComponent(
            String(format: "%04d-%02d-%02d.jsonl", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        )
    }

    private func dayFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func dayDate(for url: URL) -> Date? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
