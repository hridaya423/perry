import Foundation
import PerryCore

struct LoadedTasks {
    let records: [TaskID: TaskRecord]
    let writesBlocked: Bool
    let persistenceIssue: PersistenceError?
}

extension LoadedTasks {
    init(_ load: PersistedFileLoad<[TaskID: TaskRecord]>) {
        self.init(records: load.value, writesBlocked: load.writesBlocked, persistenceIssue: load.persistenceIssue)
    }
}

enum TaskStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case tooManyTasks(limit: Int, actual: Int)
    case duplicateID(TaskID)
    case terminalTask(TaskID)
    case invalidState(TaskID, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported task persistence version \(version)"
        case .tooManyTasks(let limit, let actual):
            return "task persistence contains \(actual) tasks, maximum is \(limit)"
        case .duplicateID(let id):
            return "task persistence contains duplicate task ID \(id)"
        case .terminalTask(let id):
            return "task persistence contains terminal task \(id)"
        case .invalidState(let id, let reason):
            return "task \(id) has invalid persisted state: \(reason)"
        }
    }
}

enum TaskStoreFile {
    static func write(
        _ records: [TaskID: TaskRecord],
        to fileURL: URL,
        maximumTasks: Int,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.createDirectoryFailed(
                path: directory.path,
                reason: error.localizedDescription
            )
        }

        let payload = PersistedTaskStore(tasks: records.values.sorted { $0.id.rawValue < $1.id.rawValue })
        let data: Data
        do {
            _ = try payload.validatedRecords(maximumTasks: maximumTasks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(payload)
        } catch {
            throw PersistenceError.encodeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.appendingPathExtension("backup")
                if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        let backup = try Data(contentsOf: backupURL)
                        let store = try JSONDecoder().decode(PersistedTaskStore.self, from: backup)
                        _ = try store.validatedRecords(maximumTasks: nil)
                    } catch {
                        throw PersistenceError.readFailed(path: backupURL.path, reason: error.localizedDescription)
                    }
                }
                try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PersistenceError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    static func load(
        from fileURL: URL?,
        maximumTasks: Int,
        fileManager: FileManager
    ) -> LoadedTasks {
        guard let fileURL else {
            return LoadedTasks(records: [:], writesBlocked: false, persistenceIssue: nil)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            guard fileManager.fileExists(atPath: fileURL.appendingPathExtension("backup").path) else {
                return LoadedTasks(records: [:], writesBlocked: false, persistenceIssue: nil)
            }
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL, reason: "primary task file is missing",
                maximumTasks: maximumTasks, fileManager: fileManager
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL,
                reason: "read failed: \(error.localizedDescription)",
                maximumTasks: maximumTasks,
                fileManager: fileManager
            )
        }

        do {
            let payload = try JSONDecoder().decode(PersistedTaskStore.self, from: data)
            return LoadedTasks(
                records: try payload.validatedRecords(maximumTasks: maximumTasks),
                writesBlocked: false,
                persistenceIssue: nil
            )
        } catch TaskStoreError.unsupportedVersion(let version) {
            return LoadedTasks(records: [:], writesBlocked: true, persistenceIssue: .readFailed(
                path: fileURL.path, reason: "Task format version \(version) is unsupported. Open this data with a compatible Perry version."
            ))
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL,
                reason: error.localizedDescription,
                maximumTasks: maximumTasks,
                fileManager: fileManager
            )
        }
    }

    private static func recoverCorruptFileOrRestoreBackup(
        at fileURL: URL,
        reason: String,
        maximumTasks: Int,
        fileManager: FileManager
    ) -> LoadedTasks {
        let recovered = fileManager.fileExists(atPath: fileURL.path)
            ? recoverCorruptFile(at: fileURL, reason: reason, fileManager: fileManager)
            : LoadedTasks(records: [:], writesBlocked: false, persistenceIssue: .readFailed(path: fileURL.path, reason: reason))
        guard !recovered.writesBlocked else { return recovered }
        let backupURL = fileURL.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return recovered }

        let backupData: Data
        let records: [TaskID: TaskRecord]
        do {
            backupData = try Data(contentsOf: backupURL)
            let payload = try JSONDecoder().decode(PersistedTaskStore.self, from: backupData)
            records = try payload.validatedRecords(maximumTasks: maximumTasks).mapValues {
                $0.updating(
                    state: .paused,
                    intent: $0.cancellationRequested ? .cancel : .pause,
                    recoveryDisposition: .restoredBackup
                )
            }
        } catch TaskStoreError.unsupportedVersion(let version) {
            return LoadedTasks(records: [:], writesBlocked: true, persistenceIssue: .readFailed(
                path: backupURL.path, reason: "Task backup format version \(version) is unsupported. Open this data with a compatible Perry version."
            ))
        } catch {
            let backupRecovery = recoverCorruptFile(
                at: backupURL,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
            return LoadedTasks(
                records: [:],
                writesBlocked: backupRecovery.writesBlocked,
                persistenceIssue: backupRecovery.persistenceIssue
            )
        }
        do {
            let restored = PersistedTaskStore(tasks: records.values.sorted { $0.id.rawValue < $1.id.rawValue })
            let restoredData = try JSONEncoder().encode(restored)
            try restoredData.write(to: fileURL, options: .atomic)
            return LoadedTasks(
                records: records,
                writesBlocked: false,
                persistenceIssue: recovered.persistenceIssue
            )
        } catch {
            return LoadedTasks(
                records: records,
                writesBlocked: true,
                persistenceIssue: .writeFailed(path: fileURL.path, reason: error.localizedDescription)
            )
        }
    }

    private static func recoverCorruptFile(
        at fileURL: URL,
        reason: String,
        fileManager: FileManager
    ) -> LoadedTasks {
        LoadedTasks(PersistedFileLoader.recoverCorruptFile(
            at: fileURL,
            reason: reason,
            fallback: [:],
            fileManager: fileManager
        ))
    }
}

struct PersistedTaskStore: Codable {
    static let currentVersion = 5

    let version: Int
    let tasks: [TaskRecord]

    private enum CodingKeys: String, CodingKey {
        case version
        case tasks
    }

    private enum PlanKindKey: String, CodingKey {
        case planKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else {
            throw TaskStoreError.unsupportedVersion(version)
        }
        var storedTasks = try container.nestedUnkeyedContainer(forKey: .tasks)
        var decodedTasks: [TaskRecord] = []
        while !storedTasks.isAtEnd {
            let element = try storedTasks.superDecoder()
            let planKind = try element.container(keyedBy: PlanKindKey.self).decodeIfPresent(String.self, forKey: .planKind)
            if version < 3 || planKind == "legacy" { continue }
            decodedTasks.append(try TaskRecord(from: element, storeVersion: version))
        }
        tasks = decodedTasks
    }

    init(tasks: [TaskRecord]) {
        version = Self.currentVersion
        self.tasks = tasks
    }

    func validatedRecords(maximumTasks: Int?) throws -> [TaskID: TaskRecord] {
        guard (1...Self.currentVersion).contains(version) else {
            throw TaskStoreError.unsupportedVersion(version)
        }
        if let maximumTasks, tasks.count > maximumTasks {
            throw TaskStoreError.tooManyTasks(
                limit: maximumTasks,
                actual: tasks.count
            )
        }

        var records: [TaskID: TaskRecord] = [:]
        var approvalIDs: Set<UUID> = []
        for record in tasks {
            guard records[record.id] == nil else {
                throw TaskStoreError.duplicateID(record.id)
            }
            if let journal = record.workspaceJournal {
                let grantIDs = journal.completed.map { $0.attempt.grant.id }
                    + (journal.current.map { [$0.attempt.grant.id] } ?? [])
                for grantID in grantIDs where !approvalIDs.insert(grantID).inserted {
                    throw TaskStoreError.invalidState(record.id, "approval identity is reused across tasks")
                }
            }
            try validate(record)
            records[record.id] = record
        }
        return records
    }

    private func validate(_ record: TaskRecord) throws {
        switch record.state {
        case .ready:
            guard case .executable = record.plan,
                  record.workspaceJournal != nil, !record.checkpoint.hasUncertainSideEffect,
                  record.intent == .none || record.intent == .cancel,
                  record.checkpoint.inFlightStepID == nil,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskStoreError.invalidState(record.id, "ready tasks require an approved action or verified receipt")
            }
        case .queued:
            guard record.intent == .none || record.intent == .cancel,
                  record.checkpoint.nextStepIndex == 0,
                  record.checkpoint.inFlightStepID == nil,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskStoreError.invalidState(
                    record.id,
                    "queued tasks must have no pause intent or active checkpoint"
                )
            }
        case .running:
            guard record.intent == .none || record.intent == .cancel,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskStoreError.invalidState(
                    record.id,
                    "running tasks cannot await approval"
                )
            }
            if case .executable = record.plan {
                let validDispatched = record.workspaceJournal?.current.map { current in
                    if case .dispatched = current { return true }
                    return false
                } == true
                let validPrefix = record.workspaceJournal?.current == nil
                    && record.workspaceJournal?.completed.isEmpty == false
                guard validDispatched || validPrefix else {
                    throw TaskStoreError.invalidState(
                        record.id,
                        "running executable tasks require a dispatched action or reportable prefix"
                    )
                }
            }
        case .paused:
            guard record.intent == .pause || record.intent == .cancel else {
                throw TaskStoreError.invalidState(
                    record.id,
                    "paused tasks must be paused or cancelled"
                )
            }
        case .completed, .blocked:
            guard let journal = record.workspaceJournal else {
                throw TaskStoreError.invalidState(record.id, "terminal record without journal")
            }
            guard journal.current == nil else {
                throw TaskStoreError.invalidState(record.id, "terminal record with in-flight action")
            }
            guard !journal.completed.isEmpty else {
                throw TaskStoreError.invalidState(record.id, "terminal record without receipts")
            }
            guard record.intent == .none else {
                throw TaskStoreError.invalidState(record.id, "terminal record with live intent \(record.intent)")
            }
            guard !record.checkpoint.hasUncertainSideEffect else {
                throw TaskStoreError.invalidState(record.id, "terminal record with uncertain side effect")
            }
        case .failed:
            throw TaskStoreError.terminalTask(record.id)
        }
    }
}
