import Foundation
import NaturalLanguage
import PerryCore

public struct MemoryRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case aboutYou
        case appWorkflow
        case preference
        case pastSession
    }

    public let id: UUID
    public let category: Category
    public let appBundleID: String?
    public let summary: String
    public let createdAt: Date
    public let subject: String?
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(),
        category: Category,
        appBundleID: String? = nil,
        summary: String,
        createdAt: Date = Date(),
        subject: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.appBundleID = appBundleID
        self.summary = summary
        self.createdAt = createdAt
        self.subject = subject
        self.expiresAt = expiresAt
    }

    public func isLive(at date: Date) -> Bool {
        expiresAt.map { $0 > date } ?? true
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
        let fallback = (configuration: configuration, records: [MemoryRecord]())
        let loaded = self.fileURL.map {
            PersistedFileLoader.load(from: $0, fileManager: fileManager, fallback: fallback, decode: Self.decode)
        }
        self.configuration = loaded?.value.configuration ?? configuration
        self.records = loaded?.value.records ?? []
        self.writesBlocked = loaded?.writesBlocked ?? false
        self.persistenceIssue = loaded?.persistenceIssue
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
        if let subject = record.subject {
            nextRecords.removeAll { $0.category == record.category && $0.subject == subject }
        }
        nextRecords.append(record)
        guard persist(configuration: configuration, records: nextRecords, includeMarkdown: true) else {
            return false
        }
        records = nextRecords
        return true
    }

    @discardableResult
    public func forget(_ id: UUID) -> Bool {
        let nextRecords = records.filter { $0.id != id }
        guard persist(configuration: configuration, records: nextRecords, includeMarkdown: true) else {
            return false
        }
        records = nextRecords
        return true
    }

    public func recall(category: MemoryRecord.Category?, appBundleID: String?) -> [MemoryRecord] {
        guard configuration.enabled else { return [] }
        let now = Date()
        return records.filter { record in
            guard configuration.categoryToggles[record.category] == true, record.isLive(at: now) else { return false }
            if let category, record.category != category { return false }
            if let appBundleID, record.appBundleID != appBundleID { return false }
            return true
        }
    }

    public func promptContext(appBundleID: String?, query: String? = nil, limit: Int = 12) -> String? {
        let recalled = recall(category: nil, appBundleID: nil).filter { record in
            record.appBundleID == nil || record.appBundleID == appBundleID
        }
        let standing = recalled.filter { $0.category == .aboutYou && $0.expiresAt == nil }
        let rest = Self.ranked(recalled.filter { !($0.category == .aboutYou && $0.expiresAt == nil) }, query: query)
        let chosen = Array(standing.suffix(limit)) + rest.prefix(max(0, min(8, limit - standing.count)))
        guard !chosen.isEmpty else { return nil }
        let ordered = query?.isEmpty == false ? chosen : chosen.sorted { $0.createdAt < $1.createdAt }
        return ordered.map { record in
            let app = record.appBundleID.map { " · \($0)" } ?? ""
            return "- [\(record.category.rawValue)\(app)] \(record.summary)"
        }.joined(separator: "\n")
    }

    static func ranked(_ records: [MemoryRecord], query: String?) -> [MemoryRecord] {
        let recent = records.sorted { $0.createdAt > $1.createdAt }
        guard let query, !query.isEmpty, let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return recent }
        return recent.enumerated().sorted { left, right in
            let leftDistance = embedding.distance(between: query, and: left.element.summary)
            let rightDistance = embedding.distance(between: query, and: right.element.summary)
            return leftDistance == rightDistance ? left.offset < right.offset : leftDistance < rightDistance
        }.map(\.element)
    }

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
