import Foundation

/// Per-thread computer-use consent ("Allow once / Always for this Perry /
/// Not now"). `once` and `notNow` are answered by the caller and never
/// stored; `always` grants are persisted per thread (each Perry owns a
/// thread) so a remembered choice survives restarts.
public actor ToolConsentStore {
    private var grants: [String: Set<String>]
    private let fileURL: URL?

    /// `directory` nil = in-memory only (tests, previews).
    public init(directory: URL?) {
        if let directory {
            fileURL = directory.appendingPathComponent("tool-consent.json")
            grants = (try? JSONDecoder().decode(
                [String: [String]].self, from: Data(contentsOf: fileURL!)
            ).mapValues(Set.init)) ?? [:]
        } else {
            fileURL = nil
            grants = [:]
        }
    }

    /// An always-grant for this tool on this thread means "don't ask again".
    public func isGranted(tool: String, threadID: String) -> Bool {
        grants[threadID]?.contains(tool) ?? false
    }

    public func grantAlways(tool: String, threadID: String) throws {
        grants[threadID, default: []].insert(tool)
        try persist()
    }

    /// Forget every remembered grant for a thread (or one tool on it).
    public func revoke(threadID: String, tool: String? = nil) throws {
        if let tool {
            grants[threadID]?.remove(tool)
            if grants[threadID]?.isEmpty == true { grants.removeValue(forKey: threadID) }
        } else {
            grants.removeValue(forKey: threadID)
        }
        try persist()
    }

    /// Wrap an approval prompt: remembered grants auto-approve, everything
    /// else falls through to the intent card.
    public func approving(
        threadID: String?,
        ask: @escaping @Sendable (ToolCall, ToolSpec) async -> Bool
    ) -> @Sendable (ToolCall, ToolSpec) async -> Bool {
        { call, spec in
            if let threadID, await self.isGranted(tool: call.name, threadID: threadID) {
                return true
            }
            return await ask(call, spec)
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(grants.mapValues(Array.init))
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
