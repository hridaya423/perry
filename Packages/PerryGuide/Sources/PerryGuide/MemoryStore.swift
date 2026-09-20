import Foundation
import PerryCore

public struct MemoryRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case appWorkflow
        case preference
        case pastSession
    }

    public let id: UUID
    public let category: Category
    public let appBundleID: String?
    public let summary: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        category: Category,
        appBundleID: String? = nil,
        summary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.appBundleID = appBundleID
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct MemoryConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var categoryToggles: [MemoryRecord.Category: Bool]

    public init(enabled: Bool = false, categoryToggles: [MemoryRecord.Category: Bool] = [:]) {
        self.enabled = enabled
        self.categoryToggles = MemoryRecord.Category.allCases.reduce(into: [:]) { result, category in
            result[category] = categoryToggles[category] ?? true
        }
    }

    public static let goldfish = MemoryConfiguration(enabled: false)
}

public actor MemoryStore {
    private let fileURL: URL?
    private let fileManager: FileManager
    private var configuration: MemoryConfiguration
    private var records: [MemoryRecord]
    private var writesBlocked: Bool
    private var persistenceIssue: PersistenceError?

    public init(
        storageDirectory: URL?,
        configuration: MemoryConfiguration = MemoryConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let storageDirectory {
            self.fileURL = storageDirectory.appendingPathComponent("memory.json")
        } else {
            self.fileURL = nil
        }
        let loaded = Self.load(
            from: self.fileURL,
            defaultConfiguration: configuration,
            fileManager: fileManager
        )
        self.configuration = loaded.configuration
        self.records = loaded.records
        self.writesBlocked = loaded.writesBlocked
        self.persistenceIssue = loaded.persistenceIssue
    }

    public var lastPersistenceError: PersistenceError? {
        persistenceIssue
    }

    public func currentConfiguration() -> MemoryConfiguration {
        configuration
    }

    @discardableResult
    public func setConfiguration(_ newConfiguration: MemoryConfiguration) -> Bool {
        guard persist(configuration: newConfiguration, records: records, includeMarkdown: true) else {
            return false
        }
        configuration = newConfiguration
        return true
    }

    @discardableResult
    public func remember(_ record: MemoryRecord) -> Bool {
        guard configuration.enabled,
              configuration.categoryToggles[record.category] == true else {
            return false
        }
        var nextRecords = records
        nextRecords.append(record)
        guard persist(configuration: configuration, records: nextRecords, includeMarkdown: true) else {
            return false
        }
        records = nextRecords
        return true
    }

    /// Recall used when planning; respects the same toggles as writing.
    public func recall(category: MemoryRecord.Category?, appBundleID: String?) -> [MemoryRecord] {
        guard configuration.enabled else { return [] }
        return records.filter { record in
            guard configuration.categoryToggles[record.category] == true else { return false }
            if let category, record.category != category { return false }
            if let appBundleID, record.appBundleID != appBundleID { return false }
            return true
        }
    }

    public func promptContext(appBundleID: String?, limit: Int = 12) -> String? {
        let recalled = recall(category: nil, appBundleID: nil)
            .filter { record in
                record.appBundleID == nil || record.appBundleID == appBundleID
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, limit))
        guard !recalled.isEmpty else { return nil }
        return recalled.reversed().map { record in
            let app = record.appBundleID.map { " · \($0)" } ?? ""
            return "- [\(record.category.rawValue)\(app)] \(record.summary)"
        }.joined(separator: "\n")
    }

    /// PRD §4: one-click wipe.
    @discardableResult
    public func wipe() -> Bool {
        guard persist(configuration: configuration, records: [], includeMarkdown: false) else {
            return false
        }
        records.removeAll()
        guard let fileURL else { return true }
        let directory = fileURL.deletingLastPathComponent()
        do {
            for fileURL in [
                directory.appendingPathComponent("PROFILE.md"),
                directory.appendingPathComponent("VOLATILE.md"),
            ] where fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            persistenceIssue = .removeFailed(path: directory.path, reason: error.localizedDescription)
            return false
        }
        persistenceIssue = nil
        return true
    }

    public func snapshot() -> [MemoryRecord] {
        records
    }

    private func persist(
        configuration: MemoryConfiguration,
        records: [MemoryRecord],
        includeMarkdown: Bool
    ) -> Bool {
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

        let payload = PersistedMemory(configuration: configuration, records: records)
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            persistenceIssue = .encodeFailed(path: fileURL.path, reason: error.localizedDescription)
            return false
        }

        if includeMarkdown {
            do {
                try writeMarkdown(records: records, directory: directory, fileName: "PROFILE.md", title: "Perry profile", filter: { $0.category == .preference })
                try writeMarkdown(records: records, directory: directory, fileName: "VOLATILE.md", title: "Perry volatile context", filter: { $0.category != .preference })
            } catch let error as PersistenceError {
                persistenceIssue = error
                return false
            } catch {
                persistenceIssue = .writeFailed(path: directory.path, reason: error.localizedDescription)
                return false
            }
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

    private func writeMarkdown(
        records: [MemoryRecord],
        directory: URL,
        fileName: String,
        title: String,
        filter: (MemoryRecord) -> Bool
    ) throws {
        let body = Self.markdown(for: records.filter(filter), title: title)
        do {
            try Data(body.utf8).write(
                to: directory.appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            throw PersistenceError.writeFailed(
                path: directory.appendingPathComponent(fileName).path,
                reason: error.localizedDescription
            )
        }
    }

    private struct LoadResult {
        let configuration: MemoryConfiguration
        let records: [MemoryRecord]
        let writesBlocked: Bool
        let persistenceIssue: PersistenceError?
    }

    private static func load(
        from url: URL?,
        defaultConfiguration: MemoryConfiguration,
        fileManager: FileManager
    ) -> LoadResult {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return LoadResult(
                configuration: defaultConfiguration,
                records: [],
                writesBlocked: false,
                persistenceIssue: nil
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                defaultConfiguration: defaultConfiguration,
                reason: "read failed: \(error.localizedDescription)",
                fileManager: fileManager
            )
        }

        do {
            let loaded = try decode(data)
            return LoadResult(
                configuration: loaded.configuration,
                records: loaded.records,
                writesBlocked: false,
                persistenceIssue: nil
            )
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                defaultConfiguration: defaultConfiguration,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
        }
    }

    private static func decode(_ data: Data) throws -> (
        configuration: MemoryConfiguration,
        records: [MemoryRecord]
    ) {
        let decoder = JSONDecoder()
        let marker = try decoder.decode(MemoryVersionMarker.self, from: data)
        if marker.containsVersion {
            guard let version = marker.version else {
                throw MemoryPersistenceValidationError.missingVersion
            }
            guard version == PersistedMemory.currentVersion else {
                throw MemoryPersistenceValidationError.unsupportedVersion(version)
            }
            let persisted = try decoder.decode(PersistedMemory.self, from: data)
            return (persisted.configuration, persisted.records)
        }
        let legacy = try decoder.decode(LegacyPersistedMemory.self, from: data)
        return (legacy.configuration, legacy.records)
    }

    private static func recoverCorruptFileOrRestoreBackup(
        at url: URL,
        defaultConfiguration: MemoryConfiguration,
        reason: String,
        fileManager: FileManager
    ) -> LoadResult {
        let recovered = recoverCorruptFile(
            at: url,
            defaultConfiguration: defaultConfiguration,
            reason: reason,
            fileManager: fileManager
        )
        guard !recovered.writesBlocked else { return recovered }
        let backupURL = url.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return recovered }

        let backupData: Data
        let loaded: (configuration: MemoryConfiguration, records: [MemoryRecord])
        do {
            backupData = try Data(contentsOf: backupURL)
            loaded = try decode(backupData)
        } catch {
            return recoverCorruptFile(
                at: backupURL,
                defaultConfiguration: defaultConfiguration,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
        }
        do {
            try backupData.write(to: url, options: .atomic)
            return LoadResult(
                configuration: loaded.configuration,
                records: loaded.records,
                writesBlocked: false,
                persistenceIssue: recovered.persistenceIssue
            )
        } catch {
            return LoadResult(
                configuration: loaded.configuration,
                records: loaded.records,
                writesBlocked: true,
                persistenceIssue: .writeFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }

    private static func recoverCorruptFile(
        at url: URL,
        defaultConfiguration: MemoryConfiguration,
        reason: String,
        fileManager: FileManager
    ) -> LoadResult {
        let quarantineURL = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: quarantineURL)
            return LoadResult(
                configuration: defaultConfiguration,
                records: [],
                writesBlocked: false,
                persistenceIssue: .recoveredCorruptFile(
                    path: url.path,
                    quarantinePath: quarantineURL.path,
                    reason: reason
                )
            )
        } catch {
            return LoadResult(
                configuration: defaultConfiguration,
                records: [],
                writesBlocked: true,
                persistenceIssue: .quarantineFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }

    private static func markdown(for records: [MemoryRecord], title: String) -> String {
        let body = records.sorted { $0.createdAt < $1.createdAt }.map { record in
            let app = record.appBundleID.map { " · \($0)" } ?? ""
            let summary = record.summary
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "- [\(record.category.rawValue)\(app)] \(summary)"
        }
        return "# \(title)\n\n" + (body.isEmpty ? "" : body.joined(separator: "\n") + "\n")
    }
}

private struct PersistedMemory: Codable {
    static let currentVersion = 1

    let version: Int
    let configuration: MemoryConfiguration
    let records: [MemoryRecord]

    init(configuration: MemoryConfiguration, records: [MemoryRecord]) {
        version = Self.currentVersion
        self.configuration = configuration
        self.records = records
    }
}

private struct LegacyPersistedMemory: Codable {
    let configuration: MemoryConfiguration
    let records: [MemoryRecord]
}

private struct MemoryVersionMarker: Decodable {
    let containsVersion: Bool
    let version: Int?

    private enum CodingKeys: String, CodingKey {
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containsVersion = container.contains(.version)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
    }
}

private enum MemoryPersistenceValidationError: Error, LocalizedError {
    case missingVersion
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .missingVersion:
            return "memory persistence envelope has no version"
        case .unsupportedVersion(let version):
            return "unsupported memory persistence version \(version)"
        }
    }
}
