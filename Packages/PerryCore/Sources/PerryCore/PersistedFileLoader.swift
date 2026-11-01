import Foundation

public struct PersistedFileLoad<Value> {
    public let value: Value
    public let writesBlocked: Bool
    public let persistenceIssue: PersistenceError?
}

public enum PersistedFileLoader {
    public static func load<Value>(
        from url: URL,
        fileManager: FileManager,
        fallback: Value,
        decode: (Data) throws -> Value
    ) -> PersistedFileLoad<Value> {
        guard fileManager.fileExists(atPath: url.path) else {
            return PersistedFileLoad(value: fallback, writesBlocked: false, persistenceIssue: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                reason: "read failed: \(error.localizedDescription)",
                fileManager: fileManager,
                fallback: fallback,
                decode: decode
            )
        }

        do {
            return PersistedFileLoad(value: try decode(data), writesBlocked: false, persistenceIssue: nil)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: url,
                reason: error.localizedDescription,
                fileManager: fileManager,
                fallback: fallback,
                decode: decode
            )
        }
    }

    static func quarantine(_ url: URL, fileManager: FileManager) throws -> URL {
        let quarantineURL = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: quarantineURL)
            return quarantineURL
        } catch {
            throw PersistenceError.quarantineFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func recoverCorruptFileOrRestoreBackup<Value>(
        at url: URL,
        reason: String,
        fileManager: FileManager,
        fallback: Value,
        decode: (Data) throws -> Value
    ) -> PersistedFileLoad<Value> {
        let recovered = recoverCorruptFile(at: url, reason: reason, fallback: fallback, fileManager: fileManager)
        guard !recovered.writesBlocked else { return recovered }
        let backupURL = url.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return recovered }

        let backupData: Data
        let restored: Value
        do {
            backupData = try Data(contentsOf: backupURL)
            restored = try decode(backupData)
        } catch {
            return recoverCorruptFile(
                at: backupURL,
                reason: error.localizedDescription,
                fallback: fallback,
                fileManager: fileManager
            )
        }
        do {
            try backupData.write(to: url, options: .atomic)
            return PersistedFileLoad(value: restored, writesBlocked: false, persistenceIssue: recovered.persistenceIssue)
        } catch {
            return PersistedFileLoad(
                value: restored,
                writesBlocked: true,
                persistenceIssue: .writeFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }

    public static func recoverCorruptFile<Value>(
        at url: URL,
        reason: String,
        fallback: Value,
        fileManager: FileManager
    ) -> PersistedFileLoad<Value> {
        do {
            let quarantineURL = try quarantine(url, fileManager: fileManager)
            return PersistedFileLoad(
                value: fallback,
                writesBlocked: false,
                persistenceIssue: .recoveredCorruptFile(
                    path: url.path,
                    quarantinePath: quarantineURL.path,
                    reason: reason
                )
            )
        } catch let issue as PersistenceError {
            return PersistedFileLoad(value: fallback, writesBlocked: true, persistenceIssue: issue)
        } catch {
            return PersistedFileLoad(
                value: fallback,
                writesBlocked: true,
                persistenceIssue: .quarantineFailed(path: url.path, reason: error.localizedDescription)
            )
        }
    }
}
