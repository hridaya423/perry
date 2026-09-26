import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public var binaryURL: URL
    public var codexHome: URL
    public var workingDirectory: URL
    public var extraArguments: [String]
    public var processArguments: [String]?
    public var extraEnvironment: [String: String]
    public var clientName: String

    public init(
        binaryURL: URL,
        codexHome: URL,
        workingDirectory: URL,
        extraArguments: [String] = CodexAppServerConfiguration.defaultConfinementArguments,
        processArguments: [String]? = nil,
        extraEnvironment: [String: String] = [:],
        clientName: String = "perry"
    ) {
        self.binaryURL = binaryURL
        self.codexHome = codexHome
        self.workingDirectory = workingDirectory
        self.extraArguments = extraArguments
        self.processArguments = processArguments
        self.extraEnvironment = extraEnvironment
        self.clientName = clientName
    }

    public static let defaultConfinementArguments: [String] = [
        "--disable", "shell_tool",
        "--disable", "unified_exec",
        "--disable", "image_generation",
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
        "-c", "tools.view_image=false",
    ]
}

public actor CodexAppServerProcess {
    public enum Failure: Error, Equatable {
        case initializeTimeout
        case initializeFailed(String)
    }

    private let configuration: CodexAppServerConfiguration
    private let environment: [String: String]
    private var process: Process?
    private var connection: JSONRPCConnection?
    private var restarts: [Date] = []
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
        if let connection, let process, process.isRunning, await !connection.closed {
            return connection
        }
        return try await spawn()
    }

    private func spawn() async throws -> JSONRPCConnection {
        try await enforceRestartBudget()
        terminateCurrent()

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
        }
        process.standardError = process.standardError ?? FileHandle.nullDevice
        try process.run()

        let connection = JSONRPCConnection(
            readHandle: stdoutPipe.fileHandleForReading,
            writeHandle: stdinPipe.fileHandleForWriting
        )
        await connection.start()
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
            process.terminate()
            throw error
        }
        self.process = process
        self.connection = connection
        return connection
    }

    public func terminate() {
        terminateCurrent()
    }

    private func terminateCurrent() {
        if let process {
            if process.isRunning { process.terminate() }
            self.process = nil
        }
        if let connection {
            Task { await connection.close() }
            self.connection = nil
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
