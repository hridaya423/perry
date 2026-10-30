import Foundation

public struct MemoryFiles: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var profileURL: URL { directory.appendingPathComponent("PROFILE.md") }
    private var contextURL: URL { directory.appendingPathComponent("CONTEXT.md") }

    public func profile() -> String {
        (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
    }

    public func context() -> String {
        (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
    }

    public func writeProfile(_ text: String) throws {
        try write(text, to: profileURL)
    }

    public func writeContext(_ text: String) throws {
        try write(text, to: contextURL)
    }

    public func profileField(_ name: String) -> String? {
        let prefix = "- \(name.lowercased()):"
        return profile().split(separator: "\n").first { $0.lowercased().hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    public func setProfileField(_ name: String, _ value: String) throws {
        let prefix = "- \(name.lowercased()):"
        var lines = profile().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "- \(name): \(trimmed)"
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix(prefix) }) {
            if trimmed.isEmpty { lines.remove(at: index) } else { lines[index] = line }
        } else if !trimmed.isEmpty {
            lines.append(line)
        }
        try writeProfile(lines.map { $0 + "\n" }.joined())
    }

    public func promptBlock() -> String {
        var sections: [String] = []
        let profile = profile().trimmingCharacters(in: .whitespacesAndNewlines)
        let context = context().trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isEmpty { sections.append("Profile:\n\(profile)") }
        if !context.isEmpty { sections.append("Current context:\n\(context)") }
        return sections.joined(separator: "\n\n")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
