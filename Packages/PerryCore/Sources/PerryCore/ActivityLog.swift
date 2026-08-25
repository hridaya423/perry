import Foundation

public struct ActivityEntry: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case allowed
        case confirmed
        case denied
    }

    public let timestamp: Date
    public let actionSummary: String
    public let targetAppBundleID: String?
    public let tier: TrustTier
    public let outcome: Outcome
    public let reversible: Bool

    public init(
        timestamp: Date = Date(),
        actionSummary: String,
        targetAppBundleID: String?,
        tier: TrustTier,
        outcome: Outcome,
        reversible: Bool
    ) {
        self.timestamp = timestamp
        self.actionSummary = actionSummary
        self.targetAppBundleID = targetAppBundleID
        self.tier = tier
        self.outcome = outcome
        self.reversible = reversible
    }
}

public actor ActivityLog {
    private let fileURL: URL?
    private var entries: [ActivityEntry]

    public init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        if let storageDirectory {
            let url = storageDirectory.appendingPathComponent("activity-log.json")
            self.fileURL = url
            self.entries = Self.loadEntries(from: url, fileManager: fileManager)
        } else {
            self.fileURL = nil
            self.entries = []
        }
    }

    public func record(_ entry: ActivityEntry) {
        entries.append(entry)
        persistIfNeeded()
    }

    public func snapshot() -> [ActivityEntry] {
        entries
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    public func wipe() {
        entries.removeAll()
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            entries.append(
                ActivityEntry(
                    actionSummary: "failed to persist activity log: \(error.localizedDescription)",
                    targetAppBundleID: nil,
                    tier: .red,
                    outcome: .allowed,
                    reversible: true
                )
            )
        }
    }

    private static func loadEntries(from url: URL, fileManager: FileManager) -> [ActivityEntry] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ActivityEntry].self, from: Data(contentsOf: url))
        } catch {
            return []
        }
    }
}
