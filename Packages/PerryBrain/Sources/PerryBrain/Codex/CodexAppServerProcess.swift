import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public var binaryURL: URL
    public var codexHome: URL
    public var workingDirectory: URL
    public var extraArguments: [String]
    public var processArguments: [String]?
    public var extraEnvironment: [String: String]
    public var clientName: String
    public var stderrLogURL: URL?

    public init(
        binaryURL: URL,
        codexHome: URL,
        workingDirectory: URL,
        extraArguments: [String] = CodexAppServerConfiguration.defaultConfinementArguments,
        processArguments: [String]? = nil,
        extraEnvironment: [String: String] = [:],
        clientName: String = "perry",
        stderrLogURL: URL? = nil
    ) {
        self.binaryURL = binaryURL
        self.codexHome = codexHome
        self.workingDirectory = workingDirectory
        self.extraArguments = extraArguments
        self.processArguments = processArguments
        self.extraEnvironment = extraEnvironment
        self.clientName = clientName
        self.stderrLogURL = stderrLogURL
    }

    public static let defaultConfinementArguments: [String] = [
        "--disable", "shell_tool",
        "--disable", "unified_exec",
        "--disable", "image_generation",
        "--disable", "view_image",
        "--disable", "code_mode_host",
        "--disable", "code_mode_only",
        "--disable", "browser_use",
        "--disable", "browser_use_external",
        "--disable", "computer_use",
        "--disable", "in_app_browser",
        "--disable", "shell_snapshot",
        "--disable", "apps",
        "--disable", "plugins",
        "--disable", "plugin_hooks",
        "--disable", "hooks",
        "--disable", "multi_agent",
        "--disable", "skill_mcp_dependency_install",
        "--disable", "workspace_dependencies",
        "--disable", "tool_suggest",
        "-c", "tools.web_search=false",
        "-c", "features.code_mode={enabled=false,direct_only_tool_namespaces=[\"functions\"]}",
        "-c", "skills.include_instructions=false",
        "-c", "skills.bundled.enabled=false",
    ]
}

public actor CodexAppServerProcess {
    private let configuration: CodexAppServerConfiguration
    private let environment: [String: String]
    private var process: Process?
    private var connection: JSONRPCConnection?
    private var restarts: [Date] = []
    private var startupTask: Task<Void, Never>?
    private var connectionWaiters: [UUID: CheckedContinuation<JSONRPCConnection, Error>] = [:]
    private var terminationTask: Task<Void, Never>?
    private let clock: @Sendable () -> Date
    private let sleeps: @Sendable (UInt64) async throws -> Void

    public init(
        configuration: CodexAppServerConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeps: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.configuration = configuration
        self.environment = environment
        self.clock = clock
        self.sleeps = sleeps
    }

    public func workingDirectoryPath() -> String {
        configuration.workingDirectory.path
    }

    public func connection() async throws -> JSONRPCConnection {
        guard terminationTask == nil else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectionWaiters[id] = continuation
                guard startupTask == nil else { return }
                startupTask = Task {
                    let result: Result<JSONRPCConnection, Error>
                    do { result = .success(try await self.readyConnection()) }
                    catch { result = .failure(error) }
                    self.startupTask = nil
                    let waiters = self.connectionWaiters.values
                    self.connectionWaiters.removeAll()
                    for waiter in waiters { waiter.resume(with: result) }
                }
            }
        } onCancel: {
            Task { await self.cancelConnectionWaiter(id) }
        }
    }

    private func cancelConnectionWaiter(_ id: UUID) {
        connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func readyConnection() async throws -> JSONRPCConnection {
        if let connection, let process, process.isRunning, await !connection.closed {
            try Task.checkCancellation()
            return connection
        }
        return try await spawn()
    }

    private func spawn() async throws -> JSONRPCConnection {
        try await enforceRestartBudget()
        await terminateCurrent()
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: configuration.codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = configuration.binaryURL
        process.arguments = configuration.processArguments ?? (["app-server"] + configuration.extraArguments)
        var spawnedEnvironment = Self.filteredEnvironment(from: environment, codexHome: configuration.codexHome)
        for (key, value) in configuration.extraEnvironment where key != "CODEX_HOME" {
            spawnedEnvironment[key] = value
        }
        process.environment = spawnedEnvironment
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        if let stderrPath = configuration.extraEnvironment["PERRY_FAKE_STDERR"] {
            FileManager.default.createFile(atPath: stderrPath, contents: nil)
            process.standardError = try? FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        } else if let stderrLogURL = configuration.stderrLogURL {
            process.standardError = Self.cappedLogHandle(for: stderrLogURL)
        }
        process.standardError = process.standardError ?? FileHandle.nullDevice
        try process.run()

        let connection = JSONRPCConnection(
            readHandle: stdoutPipe.fileHandleForReading,
            writeHandle: stdinPipe.fileHandleForWriting
        )
        self.process = process
        self.connection = connection
        await connection.start()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            await connection.close()
        }
        defer { deadline.cancel() }
        do {
            _ = try await connection.request("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"),
                ]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ]))
            try await connection.notify("initialized")
        } catch {
            await terminateCurrent()
            throw error
        }
        try Task.checkCancellation()
        return connection
    }

    public func terminate() async {
        if let terminationTask { return await terminationTask.value }
        startupTask?.cancel()
        let task = Task {
            await self.terminateCurrent()
            await self.startupTask?.value
        }
        terminationTask = task
        await task.value
    }

    private func terminateCurrent() async {
        let process = self.process
        let connection = self.connection
        self.process = nil
        self.connection = nil
        if let connection { await connection.close() }
        if let process {
            await Task.detached {
                if process.isRunning { process.terminate() }
                let deadline = ContinuousClock.now + .seconds(1)
                var forced = false
                while process.isRunning {
                    if !forced, ContinuousClock.now >= deadline {
                        kill(process.processIdentifier, SIGKILL)
                        forced = true
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }.value
        }
    }

    private static func cappedLogHandle(for url: URL) -> FileHandle? {
        let limit = 512 * 1024, keep = 256 * 1024
        do {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > limit,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                try data.suffix(keep).write(to: url)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }

    private func enforceRestartBudget() async throws {
        let now = clock()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 }
        if restarts.count >= 3 {
            throw ModelProviderError(kind: .unavailable, provider: .codex, message: "codex app-server crashed too often")
        }
        if !restarts.isEmpty {
            let backoffs: [UInt64] = [500_000_000, 2_000_000_000, 8_000_000_000]
            try await sleeps(backoffs[min(restarts.count - 1, backoffs.count - 1)])
        }
        restarts.append(now)
    }

    public static func filteredEnvironment(from environment: [String: String], codexHome: URL) -> [String: String] {
        let allowed = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
        ]
        var filtered = allowed.reduce(into: [String: String]()) { filtered, key in
            filtered[key] = environment[key]
        }
        filtered["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        filtered["SHELL"] = "/bin/zsh"
        filtered["DISABLE_AUTOUPDATER"] = "1"
        filtered["CODEX_HOME"] = codexHome.path
        return filtered
    }
}
