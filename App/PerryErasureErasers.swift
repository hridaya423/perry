import Foundation
import PerryCore
import PerryGuide

struct PerryErasurePaths: Sendable {
    let supportDirectory: URL?
    let taskWorkspaceDirectory: URL
    let temporaryMediaDirectories: [URL]
    let cacheDirectories: [URL]
    let cuaArtifactDirectories: [URL]
    let completeErasureRoots: [URL]

    init(
        supportDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        cachesDirectory: URL? = nil
    ) {
        self.supportDirectory = supportDirectory
        taskWorkspaceDirectory = homeDirectory.appendingPathComponent("PerryDemo", isDirectory: true)
        let temporaryRoot = temporaryDirectory.appendingPathComponent("Perry", isDirectory: true)
        temporaryMediaDirectories = [
            supportDirectory?.appendingPathComponent("TempMedia", isDirectory: true),
            supportDirectory?.appendingPathComponent("TemporaryMedia", isDirectory: true),
            temporaryRoot.appendingPathComponent("TempMedia", isDirectory: true),
        ].compactMap { $0 }
        let resolvedCaches = cachesDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        cacheDirectories = [
            supportDirectory?.appendingPathComponent("Caches", isDirectory: true),
            supportDirectory?.appendingPathComponent("CodexRuntime", isDirectory: true),
            supportDirectory?.appendingPathComponent("AcpAgents", isDirectory: true),
            supportDirectory?.appendingPathComponent("Telemetry", isDirectory: true),
            resolvedCaches?.appendingPathComponent("dev.perry.Perry", isDirectory: true),
        ].compactMap { $0 }
        cuaArtifactDirectories = [
            supportDirectory?.appendingPathComponent("Cua", isDirectory: true),
            supportDirectory?.appendingPathComponent("CuaArtifacts", isDirectory: true),
            supportDirectory?.appendingPathComponent("CuaDriver", isDirectory: true),
            temporaryRoot.appendingPathComponent("Cua", isDirectory: true),
        ].compactMap { $0 }
        completeErasureRoots = [
            supportDirectory,
            taskWorkspaceDirectory,
            temporaryRoot,
            resolvedCaches?.appendingPathComponent("dev.perry.Perry", isDirectory: true),
        ].compactMap { $0 }
    }
}

struct PerryOwnedRootSweeper: @unchecked Sendable, PerryOwnedDataSweeper {
    private let roots: [URL]
    private let fileManager: FileManager

    init(roots: [URL], fileManager: FileManager = .default) {
        self.roots = Array(Set(roots.map { $0.standardizedFileURL }))
            .sorted { $0.path < $1.path }
        self.fileManager = fileManager
    }

    func inventory() async throws -> [String] {
        try validateRoots()
        return roots.filter { fileManager.fileExists(atPath: $0.path) }.map(\.path)
    }

    func erase() async throws {
        try validateRoots()
        var errors: [String] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                errors.append("\(root.path): \(error.localizedDescription)")
            }
        }
        guard errors.isEmpty else {
            throw PerryErasureAdapterError(message: errors.joined(separator: "; "))
        }
    }

    private func validateRoots() throws {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let unsafe = roots.first { root in
            let path = root.standardizedFileURL.path
            return path == "/" || path == home
        }
        if let unsafe {
            throw PerryErasureAdapterError(message: "refusing broad erasure root: \(unsafe.path)")
        }
    }
}

struct PerryFileEraser: @unchecked Sendable, PerryDataEraser {
    struct Target: Equatable, Sendable {
        let identifier: String
        let url: URL

        init(identifier: String, url: URL) {
            self.identifier = identifier
            self.url = url
        }
    }

    let category: PerryErasureCategory
    private let targets: [Target]
    private let fileManager: FileManager

    init(
        category: PerryErasureCategory,
        targets: [Target],
        fileManager: FileManager = .default
    ) {
        self.category = category
        self.targets = targets
        self.fileManager = fileManager
    }

    func inventory() async throws -> [PerryErasureItem] {
        targets
            .filter { fileManager.fileExists(atPath: $0.url.path) }
            .map { PerryErasureItem(category: category, identifier: $0.identifier) }
    }

    func erase() async throws {
        var errors: [String] = []
        for target in targets where fileManager.fileExists(atPath: target.url.path) {
            do {
                try fileManager.removeItem(at: target.url)
            } catch {
                errors.append("\(target.identifier): \(error.localizedDescription)")
            }
        }
        guard errors.isEmpty else {
            throw PerryErasureAdapterError(message: errors.joined(separator: "; "))
        }
    }
}

struct PerryDirectoryEntriesEraser: @unchecked Sendable, PerryDataEraser {
    let category: PerryErasureCategory
    private let directory: URL
    private let exactNames: Set<String>
    private let prefixes: [String]
    private let fileManager: FileManager

    init(
        category: PerryErasureCategory,
        directory: URL,
        exactNames: Set<String> = [],
        prefixes: [String] = [],
        fileManager: FileManager = .default
    ) {
        self.category = category
        self.directory = directory
        self.exactNames = exactNames
        self.prefixes = prefixes
        self.fileManager = fileManager
    }

    func inventory() async throws -> [PerryErasureItem] {
        try matchingURLs().map { url in
            PerryErasureItem(category: category, identifier: url.lastPathComponent)
        }
    }

    func erase() async throws {
        var errors: [String] = []
        for url in try matchingURLs() {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard errors.isEmpty else {
            throw PerryErasureAdapterError(message: errors.joined(separator: "; "))
        }
    }

    private func matchingURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        .filter { url in
            let name = url.lastPathComponent
            return exactNames.contains(name) || prefixes.contains { name.hasPrefix($0) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct PerryDefaultsEraser: @unchecked Sendable, PerryDataEraser {
    let category: PerryErasureCategory
    private let defaults: UserDefaults
    private let keys: Set<String>
    private let prefixes: [String]
    private let excludedPrefixes: [String]

    init(
        category: PerryErasureCategory,
        defaults: UserDefaults = .standard,
        keys: Set<String> = [],
        prefixes: [String] = [],
        excludingPrefixes: [String] = []
    ) {
        self.category = category
        self.defaults = defaults
        self.keys = keys
        self.prefixes = prefixes
        excludedPrefixes = excludingPrefixes
    }

    func inventory() async throws -> [PerryErasureItem] {
        matchingKeys().map { PerryErasureItem(category: category, identifier: $0) }
    }

    func erase() async throws {
        for key in matchingKeys() {
            defaults.removeObject(forKey: key)
        }
    }

    private func matchingKeys() -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in
            let selected = keys.contains(key) || prefixes.contains { key.hasPrefix($0) }
            let excluded = excludedPrefixes.contains { key.hasPrefix($0) }
            return selected && !excluded
        }.sorted()
    }
}

struct PerryKeychainEraser: PerryDataEraser {
    struct Target: Hashable, Sendable {
        let service: String
        let account: String

        init(service: String, account: String) {
            self.service = service
            self.account = account
        }

        var identifier: String {
            "\(service)/\(account)"
        }
    }

    let category: PerryErasureCategory
    private let services: [String]
    private let accounts: @Sendable (String) throws -> [String]
    private let delete: @Sendable (Target) throws -> Void

    init(
        category: PerryErasureCategory = .providerKeychain,
        services: [String],
        accounts: @escaping @Sendable (String) throws -> [String] = { service in
            try KeychainStore(service: service).accounts()
        },
        delete: @escaping @Sendable (Target) throws -> Void = { target in
            try KeychainStore(service: target.service).deleteChecked(account: target.account)
        }
    ) {
        self.category = category
        self.services = Array(Set(services)).sorted()
        self.accounts = accounts
        self.delete = delete
    }

    func inventory() async throws -> [PerryErasureItem] {
        var items: [PerryErasureItem] = []
        for service in services {
            items.append(contentsOf: try accounts(service).map { account in
                PerryErasureItem(
                    category: category,
                    identifier: Target(service: service, account: account).identifier
                )
            })
        }
        return items
    }

    func erase() async throws {
        var errors: [String] = []
        for service in services {
            let serviceAccounts: [String]
            do {
                serviceAccounts = try accounts(service)
            } catch {
                errors.append("\(service): \(error.localizedDescription)")
                continue
            }
            for account in serviceAccounts {
                let target = Target(service: service, account: account)
                do {
                    try delete(target)
                } catch {
                    errors.append("\(target.identifier): \(error.localizedDescription)")
                }
            }
        }
        guard errors.isEmpty else {
            throw PerryErasureAdapterError(message: errors.joined(separator: "; "))
        }
    }
}

@MainActor
enum PerryLiveErasureErasers {
    static func make(
        paths: PerryErasurePaths,
        defaults: UserDefaults = .standard,
        taskCoordinator: TaskCoordinator,
        backgroundTaskContextStore: BackgroundTaskContextStore,
        activityLog: ActivityLog,
        transcriptStore: TranscriptStore,
        memoryStore: MemoryStore,
        keychainEraser: (any PerryDataEraser)? = nil
    ) -> [any PerryDataEraser] {
        [
            taskEraser(
                paths: paths,
                taskCoordinator: taskCoordinator,
                backgroundTaskContextStore: backgroundTaskContextStore
            ),
            historyEraser(paths: paths, activityLog: activityLog, transcriptStore: transcriptStore),
            memoryEraser(paths: paths, memoryStore: memoryStore),
            approvalsEraser(paths: paths, defaults: defaults),
            preferencesEraser(paths: paths, defaults: defaults),
            keychainEraser ?? providerKeychainEraser(),
            oauthStateEraser(paths: paths, defaults: defaults),
            routinesEraser(paths: paths),
            fileEraser(category: .temporaryMedia, urls: paths.temporaryMediaDirectories),
            fileEraser(category: .caches, urls: paths.cacheDirectories),
            fileEraser(category: .cuaArtifacts, urls: paths.cuaArtifactDirectories),
        ]
    }

    private static func taskEraser(
        paths: PerryErasurePaths,
        taskCoordinator: TaskCoordinator,
        backgroundTaskContextStore: BackgroundTaskContextStore
    ) -> any PerryDataEraser {
        let fileEraser = PerryFileEraser(
            category: .tasks,
            targets: taskTargets(paths: paths)
        )
        let recoveryFiles = paths.supportDirectory.map {
            PerryDirectoryEntriesEraser(
                category: .tasks,
                directory: $0,
                prefixes: [
                    "tasks.json.backup",
                    "tasks.json.corrupt-",
                    "background-task-context.json.backup",
                    "background-task-context.quarantined-",
                ]
            )
        }
        return PerryClosureEraser(
            category: .tasks,
            inventory: {
                let taskItems = (await taskCoordinator.records()).map { record in
                    PerryErasureItem(category: .tasks, identifier: "task:\(record.id.rawValue)")
                }
                let contextItems = (await backgroundTaskContextStore.snapshot()).keys
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { id in PerryErasureItem(category: .tasks, identifier: "context:\(id.rawValue)") }
                return taskItems + contextItems + (try await fileEraser.inventory()) + (try await recoveryFiles?.inventory() ?? [])
            },
            erase: {
                for record in await taskCoordinator.records() {
                    try await taskCoordinator.cancel(id: record.id, reason: "Perry data erasure")
                }
                try await backgroundTaskContextStore.wipe()
                try await fileEraser.erase()
                try await recoveryFiles?.erase()
            }
        )
    }

    private static func historyEraser(
        paths: PerryErasurePaths,
        activityLog: ActivityLog,
        transcriptStore: TranscriptStore
    ) -> any PerryDataEraser {
        let activityFiles = paths.supportDirectory.map {
            PerryDirectoryEntriesEraser(
                category: .history,
                directory: $0,
                exactNames: ["activity-log.json"],
                prefixes: [
                    "activity-log.json.backup",
                    "activity-log.json.corrupt-",
                ]
            )
        }
        let transcriptFiles = PerryFileEraser(
            category: .history,
            targets: paths.supportDirectory.map {
                [
                    PerryFileEraser.Target(identifier: "Transcripts", url: $0.appendingPathComponent("Transcripts", isDirectory: true)),
                    PerryFileEraser.Target(identifier: "DictationBackup", url: $0.appendingPathComponent(DictationBackupStore.directoryName, isDirectory: true)),
                ]
            } ?? []
        )
        return PerryClosureEraser(
            category: .history,
            inventory: {
                let activityItems = (await activityLog.snapshot()).enumerated().map { entry in
                    PerryErasureItem(category: .history, identifier: "activity:\(entry.offset)")
                }
                let transcriptItems = (await transcriptStore.snapshot()).map { entry in
                    PerryErasureItem(category: .history, identifier: "transcript:\(entry.id.uuidString)")
                }
                let activityFileItems = try await activityFiles?.inventory() ?? []
                return activityItems + transcriptItems + activityFileItems + (try await transcriptFiles.inventory())
            },
            erase: {
                guard await activityLog.wipe() else {
                    throw PerryErasureAdapterError(message: await activityLog.lastPersistenceError?.localizedDescription ?? "activity log refused to wipe")
                }
                guard await transcriptStore.wipe() else {
                    throw PerryErasureAdapterError(message: await transcriptStore.lastPersistenceError?.localizedDescription ?? "transcript store refused to wipe")
                }
                try await activityFiles?.erase()
                try await transcriptFiles.erase()
            }
        )
    }

    private static func memoryEraser(
        paths: PerryErasurePaths,
        memoryStore: MemoryStore
    ) -> any PerryDataEraser {
        let files = PerryFileEraser(
            category: .memory,
            targets: paths.supportDirectory.map {
                [
                    PerryFileEraser.Target(identifier: "memory.json", url: $0.appendingPathComponent("memory.json")),
                    PerryFileEraser.Target(identifier: "PROFILE.md", url: $0.appendingPathComponent("PROFILE.md")),
                    PerryFileEraser.Target(identifier: "VOLATILE.md", url: $0.appendingPathComponent("VOLATILE.md")),
                    PerryFileEraser.Target(identifier: "memory/PROFILE.md", url: $0.appendingPathComponent("memory/PROFILE.md")),
                    PerryFileEraser.Target(identifier: "memory/CONTEXT.md", url: $0.appendingPathComponent("memory/CONTEXT.md")),
                ]
            } ?? []
        )
        let recoveryFiles = paths.supportDirectory.map {
            PerryDirectoryEntriesEraser(
                category: .memory,
                directory: $0,
                prefixes: [
                    "memory.json.backup",
                    "memory.json.corrupt-",
                ]
            )
        }
        return PerryClosureEraser(
            category: .memory,
            inventory: {
                let records = (await memoryStore.snapshot()).enumerated().map { entry in
                    PerryErasureItem(category: .memory, identifier: "record:\(entry.offset)")
                }
                return records + (try await files.inventory()) + (try await recoveryFiles?.inventory() ?? [])
            },
            erase: {
                guard await memoryStore.wipe() else {
                    throw PerryErasureAdapterError(message: await memoryStore.lastPersistenceError?.localizedDescription ?? "memory store refused to wipe")
                }
                try await files.erase()
                try await recoveryFiles?.erase()
            }
        )
    }

    private static func approvalsEraser(
        paths: PerryErasurePaths,
        defaults: UserDefaults
    ) -> any PerryDataEraser {
        let defaultsEraser = PerryDefaultsEraser(
            category: .approvals,
            defaults: defaults,
            prefixes: [PerryPreferences.remoteWritesKeyPrefix]
        )
        let files = PerryFileEraser(
            category: .approvals,
            targets: paths.supportDirectory.map {
                [PerryFileEraser.Target(identifier: "approvals.json", url: $0.appendingPathComponent("approvals.json"))]
            } ?? []
        )
        return combined(category: .approvals, erasers: [defaultsEraser, files])
    }

    private static func preferencesEraser(
        paths: PerryErasurePaths,
        defaults: UserDefaults
    ) -> any PerryDataEraser {
        let defaultsEraser = PerryDefaultsEraser(
            category: .preferences,
            defaults: defaults,
            prefixes: [PerryPreferences.allKeysPrefix],
            excludingPrefixes: [PerryPreferences.remoteWritesKeyPrefix, PerryPreferences.oauthStateKeyPrefix]
        )
        let files = PerryFileEraser(
            category: .preferences,
            targets: paths.supportDirectory.map {
                [
                    PerryFileEraser.Target(identifier: "voice-dictionary.json", url: $0.appendingPathComponent("voice-dictionary.json")),
                    PerryFileEraser.Target(identifier: "AppSkills", url: $0.appendingPathComponent("AppSkills", isDirectory: true)),
                ]
            } ?? []
        )
        let recoveryFiles = paths.supportDirectory.map {
            PerryDirectoryEntriesEraser(
                category: .preferences,
                directory: $0,
                prefixes: [
                    "voice-dictionary.json.backup",
                    "voice-dictionary.json.corrupt-",
                ]
            )
        }
        var erasers: [any PerryDataEraser] = [defaultsEraser, files]
        if let recoveryFiles {
            erasers.append(recoveryFiles)
        }
        return combined(category: .preferences, erasers: erasers)
    }

    private static func routinesEraser(paths: PerryErasurePaths) -> any PerryDataEraser {
        let directory = paths.supportDirectory?.appendingPathComponent("Routines", isDirectory: true)
        return PerryClosureEraser(
            category: .routines,
            inventory: {
                guard let directory,
                      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                    return []
                }
                return names.sorted().map { PerryErasureItem(category: .routines, identifier: "routine:\($0)") }
            },
            erase: {
                guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
                try FileManager.default.removeItem(at: directory)
            }
        )
    }

    static var providerKeychainServices: [String] {
        ["dev.perry.integrations", "dev.perry.keys", CustomConnectors.keychainService]
    }

    private static func providerKeychainEraser() -> any PerryDataEraser {
        PerryKeychainEraser(services: providerKeychainServices)
    }

    private static func oauthStateEraser(
        paths: PerryErasurePaths,
        defaults: UserDefaults
    ) -> any PerryDataEraser {
        let defaultsEraser = PerryDefaultsEraser(
            category: .oauthState,
            defaults: defaults,
            prefixes: [PerryPreferences.oauthStateKeyPrefix]
        )
        let files = PerryFileEraser(
            category: .oauthState,
            targets: paths.supportDirectory.map {
                [PerryFileEraser.Target(identifier: "oauth-state.json", url: $0.appendingPathComponent("oauth-state.json"))]
            } ?? []
        )
        return combined(category: .oauthState, erasers: [defaultsEraser, files])
    }

    private static func combined(
        category: PerryErasureCategory,
        erasers: [any PerryDataEraser]
    ) -> any PerryDataEraser {
        PerryClosureEraser(
            category: category,
            inventory: {
                var items: [PerryErasureItem] = []
                for eraser in erasers {
                    items.append(contentsOf: try await eraser.inventory())
                }
                return items
            },
            erase: {
                var errors: [String] = []
                for eraser in erasers {
                    do {
                        try await eraser.erase()
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                }
                guard errors.isEmpty else {
                    throw PerryErasureAdapterError(message: errors.joined(separator: "; "))
                }
            }
        )
    }

    private static func fileEraser(
        category: PerryErasureCategory,
        urls: [URL]
    ) -> PerryFileEraser {
        PerryFileEraser(
            category: category,
            targets: urls.enumerated().map { index, url in
                PerryFileEraser.Target(identifier: "path-\(index):\(url.lastPathComponent)", url: url)
            }
        )
    }

    private static func taskTargets(paths: PerryErasurePaths) -> [PerryFileEraser.Target] {
        var targets: [PerryFileEraser.Target] = []
        if let supportDirectory = paths.supportDirectory {
            targets.append(contentsOf: [
                PerryFileEraser.Target(identifier: "tasks.json", url: supportDirectory.appendingPathComponent("tasks.json")),
                PerryFileEraser.Target(identifier: "background-task-context.json", url: supportDirectory.appendingPathComponent("background-task-context.json")),
            ])
        }
        targets.append(PerryFileEraser.Target(identifier: "PerryDemo", url: paths.taskWorkspaceDirectory))
        return targets
    }
}
