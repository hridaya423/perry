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
    public let verified: Bool?

    public init(
        timestamp: Date = Date(),
        actionSummary: String,
        targetAppBundleID: String?,
        tier: TrustTier,
        outcome: Outcome,
        reversible: Bool,
        verified: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.actionSummary = actionSummary
        self.targetAppBundleID = targetAppBundleID
        self.tier = tier
        self.outcome = outcome
        self.reversible = reversible
        self.verified = verified
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case actionSummary
        case targetAppBundleID
        case tier
        case outcome
        case reversible
        case verified
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        actionSummary = try values.decode(String.self, forKey: .actionSummary)
        targetAppBundleID = try values.decodeIfPresent(String.self, forKey: .targetAppBundleID)
        tier = try values.decode(TrustTier.self, forKey: .tier)
        outcome = try values.decode(Outcome.self, forKey: .outcome)
        reversible = try values.decode(Bool.self, forKey: .reversible)
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified)
    }
}

public actor ActivityLog {
    private let fileURL: URL?
    private let fileManager: FileManager
    private var entries: [ActivityEntry]
    private var writesBlocked: Bool
    private var persistenceIssue: PersistenceError?

    public init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let storageDirectory {
            let url = storageDirectory.appendingPathComponent("activity-log.json")
            self.fileURL = url
            let loaded = Self.loadEntries(from: url, fileManager: fileManager)
            self.entries = loaded.entries
            self.writesBlocked = loaded.writesBlocked
            self.persistenceIssue = loaded.persistenceIssue
        } else {
            self.fileURL = nil
            self.entries = []
            self.writesBlocked = false
            self.persistenceIssue = nil
        }
    }

    public var lastPersistenceError: PersistenceError? {
        persistenceIssue
    }

    @discardableResult
    public func record(_ entry: ActivityEntry) -> Bool {
        var nextEntries = entries
        nextEntries.append(entry)
        guard persist(nextEntries) else { return false }
        entries = nextEntries
        return true
    }

    public func snapshot() -> [ActivityEntry] {
        entries
    }

    public func search(_ query: String) -> [ActivityEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.actionSummary, entry.targetAppBundleID ?? "", entry.tier.rawValue, entry.outcome.rawValue]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    @discardableResult
    public func wipe() -> Bool {
        guard persist([]) else { return false }
        entries.removeAll()
        return true
    }

    private func persist(_ entries: [ActivityEntry]) -> Bool {
        guard let fileURL else {
            persistenceIssue = nil
            return true
        }
        if writesBlocked {
            if fileManager.fileExists(atPath: fileURL.path) {
                return false
            }
            writesBlocked = false
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            persistenceIssue = .createDirectoryFailed(path: directory.path, reason: error.localizedDescription)
            return false
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(PersistedActivityLog(entries: entries))
        } catch {
            persistenceIssue = .encodeFailed(path: fileURL.path, reason: error.localizedDescription)
            return false
        }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.appendingPathExtension("backup")
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
            persistenceIssue = nil
            return true
        } catch {
            persistenceIssue = .writeFailed(path: fileURL.path, reason: error.localizedDescription)
            return false
        }
    }

    private struct LoadResult {
        let entries: [ActivityEntry]
        let writesBlocked: Bool
        let persistenceIssue: PersistenceError?
    }

    private static func loadEntries(from url: URL, fileManager: FileManager) -> LoadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return LoadResult(entries: [], writesBlocked: false, persistenceIssue: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                reason: "read failed: \(error.localizedDescription)",
                fileManager: fileManager
            )
        }

        do {
            return LoadResult(
                entries: try decodeEntries(data),
                writesBlocked: false,
                persistenceIssue: nil
            )
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
        }
    }

    private static func recoverCorruptFileOrRestoreBackup(
        at url: URL,
        reason: String,
        fileManager: FileManager
    ) -> LoadResult {
        let recovered = recoverCorruptFile(at: url, reason: reason, fileManager: fileManager)
        guard !recovered.writesBlocked else { return recovered }
        let backupURL = url.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return recovered }

        let backupData: Data
        let entries: [ActivityEntry]
        do {
            backupData = try Data(contentsOf: backupURL)
            entries = try decodeEntries(backupData)
        } catch {
            return recoverCorruptFile(at: backupURL, reason: error.localizedDescription, fileManager: fileManager)
        }
        do {
            try backupData.write(to: url, options: .atomic)
            return LoadResult(
                entries: entries,
                writesBlocked: false,
                persistenceIssue: recovered.persistenceIssue
            )
        } catch {
            return LoadResult(
                entries: entries,
                writesBlocked: true,
                persistenceIssue: .writeFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }

    private static func decodeEntries(_ data: Data) throws -> [ActivityEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let persisted = try decoder.decode(PersistedActivityLog.self, from: data)
            return try persisted.validatedEntries()
        } catch let envelopeError {
            do {
                return try decoder.decode([ActivityEntry].self, from: data)
            } catch {
                throw envelopeError
            }
        }
    }

    private static func recoverCorruptFile(at url: URL, reason: String, fileManager: FileManager) -> LoadResult {
        let quarantineURL = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: quarantineURL)
            return LoadResult(
                entries: [],
                writesBlocked: false,
                persistenceIssue: .recoveredCorruptFile(
                    path: url.path,
                    quarantinePath: quarantineURL.path,
                    reason: reason
                )
            )
        } catch {
            return LoadResult(
                entries: [],
                writesBlocked: true,
                persistenceIssue: .quarantineFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }
}

private enum ActivityLogPersistenceValidationError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported activity log persistence version \(version)"
        }
    }
}

private struct PersistedActivityLog: Codable {
    static let currentVersion = 1

    let version: Int
    let entries: [ActivityEntry]

    init(entries: [ActivityEntry]) {
        version = Self.currentVersion
        self.entries = entries
    }

    func validatedEntries() throws -> [ActivityEntry] {
        guard version == Self.currentVersion else {
            throw ActivityLogPersistenceValidationError.unsupportedVersion(version)
        }
        return entries
    }
}
