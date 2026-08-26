import Foundation

/// PRD §4 Memory: on by default, per-category toggles, stored locally as an
/// inspectable JSON file, one-click wipe, never synced. Off = goldfish mode.
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

    public init(enabled: Bool = true, categoryToggles: [MemoryRecord.Category: Bool] = [:]) {
        self.enabled = enabled
        self.categoryToggles = MemoryRecord.Category.allCases.reduce(into: [:]) { result, category in
            result[category] = categoryToggles[category] ?? true
        }
    }

    public static let goldfish = MemoryConfiguration(enabled: false)
}

public actor MemoryStore {
    private let fileURL: URL?
    private var configuration: MemoryConfiguration
    private var records: [MemoryRecord]

    public init(
        storageDirectory: URL?,
        configuration: MemoryConfiguration = MemoryConfiguration(),
        fileManager: FileManager = .default
    ) {
        if let storageDirectory {
            self.fileURL = storageDirectory.appendingPathComponent("memory.json")
        } else {
            self.fileURL = nil
        }
        self.configuration = configuration
        if let fileURL, fileManager.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(PersistedMemory.self, from: data) {
            self.records = loaded.records
            self.configuration = loaded.configuration
        } else {
            self.records = []
        }
    }

    public func currentConfiguration() -> MemoryConfiguration {
        configuration
    }

    public func setConfiguration(_ newConfiguration: MemoryConfiguration) {
        configuration = newConfiguration
        persist()
    }

    @discardableResult
    public func remember(_ record: MemoryRecord) -> Bool {
        guard configuration.enabled,
              configuration.categoryToggles[record.category] == true else {
            return false
        }
        records.append(record)
        persist()
        return true
    }

    /// Recall used when planning; respects the same toggles as writing.
    public func recall(category: MemoryRecord.Category?, appBundleID: String?) -> [MemoryRecord] {
        guard configuration.enabled else { return [] }
        return records.filter { record in
            if let category, record.category != category { return false }
            if let appBundleID, record.appBundleID != appBundleID { return false }
            return true
        }
    }

    /// PRD §4: one-click wipe.
    public func wipe() {
        records.removeAll()
        persist()
    }

    public func snapshot() -> [MemoryRecord] {
        records
    }

    private func persist() {
        guard let fileURL else { return }
        let payload = PersistedMemory(configuration: configuration, records: records)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private struct PersistedMemory: Codable {
    let configuration: MemoryConfiguration
    let records: [MemoryRecord]
}
