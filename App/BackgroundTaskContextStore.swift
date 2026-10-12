import Foundation
import PerryGuide
import PerryRuntimes

struct BackgroundTaskMetadata: Codable, Equatable, Sendable {
    let targetAppBundleID: String?
    let targetWindowTitle: String?
    let targetProcessID: Int32?
    let targetWindowID: Int64?
    let workspacePath: String?
    let runtimeRoutingSummary: String?
    let createdAt: Date

    init(
        targetAppBundleID: String? = nil,
        targetWindowTitle: String? = nil,
        targetProcessID: Int32? = nil,
        targetWindowID: Int64? = nil,
        workspacePath: String? = nil,
        runtimeRoutingSummary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.targetAppBundleID = targetAppBundleID
        self.targetWindowTitle = targetWindowTitle
        self.targetProcessID = targetProcessID
        self.targetWindowID = targetWindowID
        self.workspacePath = workspacePath
        self.runtimeRoutingSummary = runtimeRoutingSummary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case targetAppBundleID
        case targetWindowTitle
        case targetProcessID
        case targetWindowID
        case workspacePath
        case runtimeRoutingSummary
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetAppBundleID = try container.decodeIfPresent(String.self, forKey: .targetAppBundleID)
        targetWindowTitle = try container.decodeIfPresent(String.self, forKey: .targetWindowTitle)
        targetProcessID = try container.decodeIfPresent(Int32.self, forKey: .targetProcessID)
        targetWindowID = try container.decodeIfPresent(Int64.self, forKey: .targetWindowID)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        runtimeRoutingSummary = try container.decodeIfPresent(String.self, forKey: .runtimeRoutingSummary)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

}

private struct BackgroundTaskContextEnvelope: Codable {
    let schemaVersion: Int
    let values: [TaskID: BackgroundTaskMetadata]
}

private enum BackgroundTaskContextStoreError: Error {
    case unavailable(String)
}

enum BackgroundTaskContextRecovery: Equatable, Sendable {
    case none
    case restoredBackup
    case quarantinedUnrecoverableFile
}

actor BackgroundTaskContextStore {
    private static let schemaVersion = 1
    private let fileURL: URL?
    private var values: [TaskID: BackgroundTaskMetadata]
    private var loadError: Error?
    private let recovery: BackgroundTaskContextRecovery

    init(storageDirectory: URL?) {
        fileURL = storageDirectory?.appendingPathComponent("background-task-context.json")
        let loaded = Self.load(from: fileURL)
        values = loaded.values
        loadError = loaded.error
        recovery = loaded.recovery
    }

    func save(_ metadata: BackgroundTaskMetadata, for id: TaskID) throws {
        var nextValues = values
        nextValues[id] = metadata
        try persist(nextValues)
        values = nextValues
    }

    func metadata(for id: TaskID) -> BackgroundTaskMetadata? {
        values[id]
    }

    func snapshot() -> [TaskID: BackgroundTaskMetadata] {
        values
    }

    func recoveryDisposition() -> BackgroundTaskContextRecovery {
        recovery
    }

    func remove(for id: TaskID) throws {
        guard values[id] != nil else { return }
        var nextValues = values
        nextValues.removeValue(forKey: id)
        try persist(nextValues)
        values = nextValues
    }

    @discardableResult
    func wipe() throws -> Bool {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        values.removeAll()
        loadError = nil
        return true
    }

    private func persist(_ values: [TaskID: BackgroundTaskMetadata]) throws {
        if let loadError { throw loadError }
        guard let fileURL else { return }
        try Self.persist(values, to: fileURL)
    }

    private static func persist(_ values: [TaskID: BackgroundTaskMetadata], to fileURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BackgroundTaskContextEnvelope(schemaVersion: schemaVersion, values: values))
        if fileManager.fileExists(atPath: fileURL.path) {
            let backupURL = fileURL.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: backupURL.path) { try fileManager.removeItem(at: backupURL) }
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from fileURL: URL?) -> (
        values: [TaskID: BackgroundTaskMetadata],
        error: Error?,
        recovery: BackgroundTaskContextRecovery
    ) {
        guard let fileURL else { return ([:], nil, .none) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([:], nil, .none) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return ([:], BackgroundTaskContextStoreError.unavailable(error.localizedDescription), .none)
        }
        let decoder = JSONDecoder()
        do {
            let envelope = try decodeEnvelope(data, using: decoder)
            return (envelope.values, nil, .none)
        } catch {
            do {
                let legacy = try decoder.decode([TaskID: BackgroundTaskMetadata].self, from: data)
                do {
                    try persist(legacy, to: fileURL)
                    return (legacy, nil, .none)
                } catch {
                    return ([:], BackgroundTaskContextStoreError.unavailable(error.localizedDescription), .none)
                }
            } catch {
                return recoverBackup(for: fileURL, using: decoder)
            }
        }
    }

    private static func recoverBackup(
        for fileURL: URL,
        using decoder: JSONDecoder
    ) -> (
        values: [TaskID: BackgroundTaskMetadata],
        error: Error?,
        recovery: BackgroundTaskContextRecovery
    ) {
        let backupURL = fileURL.appendingPathExtension("backup")
        do {
            try quarantine(fileURL)
        } catch {
            return ([:], BackgroundTaskContextStoreError.unavailable(error.localizedDescription), .none)
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return ([:], nil, .quarantinedUnrecoverableFile)
        }
        do {
            let backupData = try Data(contentsOf: backupURL)
            let envelope: BackgroundTaskContextEnvelope
            do {
                envelope = try decodeEnvelope(backupData, using: decoder)
            } catch {
                try quarantine(backupURL)
                return ([:], nil, .quarantinedUnrecoverableFile)
            }
            try backupData.write(to: fileURL, options: .atomic)
            return (envelope.values, nil, .restoredBackup)
        } catch {
            return ([:], BackgroundTaskContextStoreError.unavailable(error.localizedDescription), .none)
        }
    }

    private static func decodeEnvelope(
        _ data: Data,
        using decoder: JSONDecoder
    ) throws -> BackgroundTaskContextEnvelope {
        let envelope = try decoder.decode(BackgroundTaskContextEnvelope.self, from: data)
        guard envelope.schemaVersion == schemaVersion else {
            throw BackgroundTaskContextStoreError.unavailable("unsupported background task context schema \(envelope.schemaVersion)")
        }
        return envelope
    }

    private static func quarantine(_ fileURL: URL) throws {
        let quarantineURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("quarantined-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    }
}
