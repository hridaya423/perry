import Foundation

public struct TranscriptEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case completed
        case stopped
        case failed
    }

    public let id: UUID
    public let sessionID: UUID
    public let request: String
    public let appBundleID: String?
    public let summary: String
    public let outcome: Outcome
    public let startedAt: Date
    public let finishedAt: Date
    public let steps: [String]
    public let verified: Bool?
    /// Display name of the runtime/provider route that produced the result,
    /// e.g. "Perry local planner" or "the learned routine".
    public let providerRoute: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        request: String,
        appBundleID: String?,
        summary: String,
        outcome: Outcome,
        startedAt: Date,
        finishedAt: Date,
        steps: [String],
        verified: Bool?,
        providerRoute: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.request = request
        self.appBundleID = appBundleID
        self.summary = summary
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
        self.verified = verified
        self.providerRoute = providerRoute
    }

    public var duration: TimeInterval {
        max(0, finishedAt.timeIntervalSince(startedAt))
    }
}

public enum TranscriptExportFormat: Equatable, Sendable {
    case markdown
    case csv
}

public actor TranscriptStore {
    private let directory: URL?
    private let fileManager: FileManager
    private var entries: [TranscriptEntry]
    private var writesBlocked: Bool
    private var persistenceIssue: PersistenceError?

    public init(directory: URL?, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory?.appendingPathComponent("Transcripts", isDirectory: true)
        let loaded = Self.loadEntries(
            from: self.directory?.appendingPathComponent("index.json"),
            fileManager: fileManager
        )
        self.entries = loaded.entries
        self.writesBlocked = loaded.writesBlocked
        self.persistenceIssue = loaded.persistenceIssue
    }

    public var lastPersistenceError: PersistenceError? {
        persistenceIssue
    }

    @discardableResult
    public func append(_ entry: TranscriptEntry) -> Bool {
        var nextEntries = entries
        nextEntries.removeAll { $0.id == entry.id }
        nextEntries.append(entry)
        nextEntries.sort { $0.finishedAt > $1.finishedAt }
        guard persist(nextEntries, including: entry) else { return false }
        entries = nextEntries
        return true
    }

    public func snapshot() -> [TranscriptEntry] {
        entries
    }

    public func search(_ query: String) -> [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.request, entry.appBundleID ?? "", entry.summary, entry.steps.joined(separator: " ")]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    public func export(_ ids: Set<UUID>, format: TranscriptExportFormat) throws -> Data {
        let selected = entries.filter { ids.contains($0.id) }.sorted { $0.finishedAt < $1.finishedAt }
        switch format {
        case .markdown:
            return Data(selected.map(Self.markdown).joined(separator: "\n").utf8)
        case .csv:
            let header = "session_id,request,app,outcome,started_at,finished_at,duration_seconds,verified,provider_route,summary"
            let rows = selected.map { entry in
                [
                    entry.sessionID.uuidString,
                    entry.request,
                    entry.appBundleID ?? "",
                    entry.outcome.rawValue,
                    Self.iso8601(entry.startedAt),
                    Self.iso8601(entry.finishedAt),
                    String(format: "%.2f", entry.duration),
                    entry.verified.map(String.init) ?? "",
                    entry.providerRoute ?? "",
                    entry.summary,
                ].map(Self.csvField).joined(separator: ",")
            }
            return Data(([header] + rows).joined(separator: "\n").appending("\n").utf8)
        }
    }

    @discardableResult
    public func wipe() -> Bool {
        guard let directory else {
            entries.removeAll()
            persistenceIssue = nil
            return true
        }
        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                persistenceIssue = .removeFailed(path: directory.path, reason: error.localizedDescription)
                return false
            }
        }
        entries.removeAll()
        writesBlocked = false
        persistenceIssue = nil
        return true
    }

    /// Deletes the selected entries: each touched day file is regenerated
    /// from its surviving entries (or removed when none remain), then the
    /// index is rewritten last. If a day-file write fails the index still
    /// lists the entries, so the delete reports failure honestly and a
    /// retry can finish the cleanup instead of leaving invisible residue.
    /// Returns false when persistence fails — the in-memory list is only
    /// mutated after all writes land.
    @discardableResult
    public func delete(_ ids: Set<UUID>) -> Bool {
        let doomed = entries.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return true }
        let remaining = entries.filter { !ids.contains($0.id) }

        if let directory {
            let touchedNames = Set(doomed.map { Self.fileName(for: $0.finishedAt) })
            for name in touchedNames {
                let url = directory.appendingPathComponent(name)
                let survivors = remaining
                    .filter { Self.fileName(for: $0.finishedAt) == name }
                    .sorted { $0.finishedAt < $1.finishedAt }
                do {
                    if survivors.isEmpty {
                        if fileManager.fileExists(atPath: url.path) {
                            try fileManager.removeItem(at: url)
                        }
                    } else {
                        let content = survivors
                            .map { Self.markdown($0, marker: "<!-- perry-session:\($0.id.uuidString) -->") }
                            .joined(separator: "\n\n")
                        try Data(content.utf8).write(to: url, options: .atomic)
                    }
                } catch {
                    persistenceIssue = .writeFailed(path: url.path, reason: error.localizedDescription)
                    return false
                }
            }
        }

        guard persistIndex(remaining) else { return false }
        entries = remaining
        return true
    }

    private func persist(_ entries: [TranscriptEntry], including entry: TranscriptEntry) -> Bool {
        guard let directory else {
            persistenceIssue = nil
            return true
        }
        let indexURL = directory.appendingPathComponent("index.json")
        if writesBlocked {
            if fileManager.fileExists(atPath: indexURL.path) {
                return false
            }
            writesBlocked = false
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            persistenceIssue = .createDirectoryFailed(path: directory.path, reason: error.localizedDescription)
            return false
        }

        let recoveryIssue: PersistenceError?
        do {
            recoveryIssue = try persistMarkdown(for: entry, in: directory)
        } catch let error as PersistenceError {
            persistenceIssue = error
            return false
        } catch {
            persistenceIssue = .writeFailed(
                path: directory.appendingPathComponent(Self.fileName(for: entry.finishedAt)).path,
                reason: error.localizedDescription
            )
            return false
        }

        guard persistIndex(entries) else { return false }
        persistenceIssue = recoveryIssue
        return true
    }

    /// Atomically rewrites index.json (with backup rotation). Shared by
    /// append and delete so the index never points at removed day files.
    private func persistIndex(_ entries: [TranscriptEntry]) -> Bool {
        guard let directory else {
            persistenceIssue = nil
            return true
        }
        let indexURL = directory.appendingPathComponent("index.json")
        if writesBlocked {
            if fileManager.fileExists(atPath: indexURL.path) {
                return false
            }
            writesBlocked = false
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(PersistedTranscriptStore(entries: entries))
        } catch {
            persistenceIssue = .encodeFailed(path: indexURL.path, reason: error.localizedDescription)
            return false
        }
        do {
            if fileManager.fileExists(atPath: indexURL.path) {
                let backupURL = indexURL.appendingPathExtension("backup")
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: indexURL, to: backupURL)
            }
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            persistenceIssue = .writeFailed(path: indexURL.path, reason: error.localizedDescription)
            return false
        }
    }

    private func persistMarkdown(for entry: TranscriptEntry, in directory: URL) throws -> PersistenceError? {
        let url = directory.appendingPathComponent(Self.fileName(for: entry.finishedAt))
        var recoveryIssue: PersistenceError?
        let existing: String
        if fileManager.fileExists(atPath: url.path) {
            do {
                existing = try String(contentsOf: url, encoding: .utf8)
            } catch {
                let quarantineURL = try quarantine(url)
                recoveryIssue = .recoveredCorruptFile(
                    path: url.path,
                    quarantinePath: quarantineURL.path,
                    reason: error.localizedDescription
                )
                existing = ""
            }
        } else {
            existing = ""
        }
        let marker = "<!-- perry-session:\(entry.id.uuidString) -->"
        guard !existing.contains(marker) else { return recoveryIssue }
        let separator = existing.isEmpty ? "" : "\n\n"
        do {
            try Data((existing + separator + Self.markdown(entry, marker: marker)).utf8)
                .write(to: url, options: .atomic)
        } catch {
            throw PersistenceError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
        return recoveryIssue
    }

    private func quarantine(_ url: URL) throws -> URL {
        let quarantineURL = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: quarantineURL)
            return quarantineURL
        } catch {
            throw PersistenceError.quarantineFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private struct LoadResult {
        let entries: [TranscriptEntry]
        let writesBlocked: Bool
        let persistenceIssue: PersistenceError?
    }

    private static func loadEntries(from url: URL?, fileManager: FileManager) -> LoadResult {
        guard let url, fileManager.fileExists(atPath: url.path) else {
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
            let payload = try JSONDecoder().decode(PersistedTranscriptStore.self, from: data)
            return LoadResult(
                entries: try payload.validatedEntries(),
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
        let entries: [TranscriptEntry]
        do {
            backupData = try Data(contentsOf: backupURL)
            let payload = try JSONDecoder().decode(PersistedTranscriptStore.self, from: backupData)
            entries = try payload.validatedEntries()
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

    private static func markdown(_ entry: TranscriptEntry) -> String {
        markdown(entry, marker: "")
    }

    private static func markdown(_ entry: TranscriptEntry, marker: String) -> String {
        let app = entry.appBundleID ?? "unknown app"
        let route = entry.providerRoute ?? "unknown route"
        let verification = entry.verified.map { $0 ? "verified" : "not verified" } ?? "not requested"
        let steps = entry.steps.isEmpty ? "- No executable steps" : entry.steps.map { "- \($0)" }.joined(separator: "\n")
        return """
        \(marker)
        ## \(entry.request)

        - Session: `\(entry.sessionID.uuidString)`
        - App: `\(app)`
        - Provider: \(route)
        - Outcome: \(entry.outcome.rawValue)
        - Started: \(iso8601(entry.startedAt))
        - Finished: \(iso8601(entry.finishedAt))
        - Duration: \(String(format: "%.2f", entry.duration)) seconds
        - Verification: \(verification)

        \(entry.summary)

        ### Steps

        \(steps)
        """
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date)).md"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct PersistedTranscriptStore: Codable {
    static let currentVersion = 1

    let version: Int
    let entries: [TranscriptEntry]

    init(entries: [TranscriptEntry]) {
        version = Self.currentVersion
        self.entries = entries
    }

    func validatedEntries() throws -> [TranscriptEntry] {
        guard version == Self.currentVersion else {
            throw TranscriptPersistenceValidationError.unsupportedVersion(version)
        }
        return entries
    }
}

private enum TranscriptPersistenceValidationError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported transcript persistence version \(version)"
        }
    }
}
