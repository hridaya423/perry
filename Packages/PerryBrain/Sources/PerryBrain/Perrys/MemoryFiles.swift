import Foundation

/// PROFILE.md (stable preferences) and CONTEXT.md (current project), local and
/// inspectable, injected into Talk and agent prompts via `promptBlock()`.
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

    /// One block for system prompts; empty sections are omitted.
    public func promptBlock() -> String {
        var sections: [String] = []
        let profile = profile().trimmingCharacters(in: .whitespacesAndNewlines)
        let context = context().trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isEmpty { sections.append("About the user:\n\(profile)") }
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
