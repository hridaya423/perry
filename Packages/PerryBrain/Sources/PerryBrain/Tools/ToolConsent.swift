import Foundation

public actor ToolConsentStore {
    private var grants: [String: Set<String>]
    private let fileURL: URL?

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

    public func isGranted(tool: String, threadID: String) -> Bool {
        grants[threadID]?.contains(tool) ?? false
    }

    public func grantAlways(tool: String, threadID: String) throws {
        grants[threadID, default: []].insert(tool)
        try persist()
    }

    public func revoke(threadID: String, tool: String? = nil) throws {
        if let tool {
            grants[threadID]?.remove(tool)
            if grants[threadID]?.isEmpty == true { grants.removeValue(forKey: threadID) }
        } else {
            grants.removeValue(forKey: threadID)
        }
        try persist()
    }

    public func approving(
        threadID: String?,
        ask: @escaping @Sendable (ToolCall, ToolSpec) async -> ToolApproval
    ) -> @Sendable (ToolCall, ToolSpec) async -> ToolApproval {
        { call, spec in
            if spec.tier < .red,
               let threadID,
               await self.isGranted(tool: call.name, threadID: threadID) {
                return .approvedOnce
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
