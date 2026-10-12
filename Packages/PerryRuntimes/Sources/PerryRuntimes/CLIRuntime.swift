import Foundation
import Darwin
import PerryCore

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var reachedEOF = false
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else {
            reachedEOF = true
            return
        }
        guard !exceededLimit, chunk.count <= limit - data.count else {
            exceededLimit = true
            return
        }
        data.append(chunk)
    }

    var state: (reachedEOF: Bool, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (reachedEOF, exceededLimit)
    }

    func text() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { throw ExecutionError(message: "CLI output exceeded its byte limit") }
        guard reachedEOF else { throw ExecutionError(message: "CLI output is incomplete") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExecutionError(message: "CLI output was not valid UTF-8")
        }
        return text
    }
}

public struct CLIRuntime: Sendable {
    public enum ProcessProfile: Sendable, Equatable {
        case standard
        case codex(runtimeHome: URL)
    }

    public let id = "cli.claude-code"

    public static func authenticationStatus(executable: URL) async throws -> RuntimeAuthenticationStatus {
        do {
            try Task.checkCancellation()
            let result = try await runProcess(executable: executable, arguments: ["auth", "status"], timeout: 3)
            try Task.checkCancellation()
            return authenticationStatus(stdout: result.stdout, exitCode: result.exitCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown(reason: "Claude Code could not verify its official login state")
        }
    }

    static func authenticationStatus(stdout: String, exitCode: Int32) -> RuntimeAuthenticationStatus {
        do {
            let status = try JSONDecoder().decode(ClaudeLoginStatus.self, from: Data(stdout.utf8))
            if exitCode == 0, status.loggedIn { return .authenticated }
            if exitCode == 1, !status.loggedIn { return .missing }
        } catch {
            return .unknown(reason: "Claude Code returned an unrecognized login status")
        }
        return .unknown(reason: "Claude Code returned an inconsistent login status")
    }

    private struct ClaudeLoginStatus: Decodable {
        let loggedIn: Bool
    }

    private let locateExecutable: @Sendable () throws -> URL
    private let invokeCommand: @Sendable (URL, [String]) async throws -> String
    private let timeout: TimeInterval
    private let workingDirectory: URL?

    public init(
        executableLocator: @escaping @Sendable () throws -> URL = CLIRuntime.standardLocator,
        commandRunner: (@Sendable (URL, [String]) async throws -> String)? = nil,
        timeout: TimeInterval = 120,
        workingDirectory: URL? = nil
    ) {
        self.locateExecutable = executableLocator
        self.timeout = timeout
        self.workingDirectory = workingDirectory
        if let commandRunner {
            self.invokeCommand = commandRunner
        } else {
            self.invokeCommand = { @Sendable executable, arguments in
                let result = try await Self.runProcess(executable: executable, arguments: arguments, timeout: timeout, workingDirectory: workingDirectory)
                guard result.exitCode == 0 else {
                    throw ExecutionError(message: "CLI exited \(result.exitCode): \(result.stderr)")
                }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func invoke(_ arguments: [String]) async throws -> String {
        let executable = try locateExecutable()
        return try await invokeCommand(executable, arguments)
    }

    public static let standardLocator: @Sendable () throws -> URL = {
        try locateExecutable()
    }

    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()

        var searched: [String] = []
        func candidate(_ path: String) -> URL {
            searched.append(path)
            return URL(fileURLWithPath: path)
        }

        var candidates: [URL] = []
        candidates.append(contentsOf: [
            candidate("\(home)/.claude/local/claude"),
            candidate("/opt/homebrew/bin/claude"),
            candidate("/usr/local/bin/claude"),
            candidate("\(home)/.local/bin/claude"),
        ])

        for url in candidates where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        throw CLIUnavailableError(searchedPaths: searched)
    }

    public static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        workingDirectory: URL? = nil,
        profile: ProcessProfile = .standard,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, maximumOutputBytes > 0 else {
            throw ExecutionError(message: "CLI timeout and output limit must be positive")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = processEnvironment(from: ProcessInfo.processInfo.environment, profile: profile)

        let stdoutBuffer = PipeBuffer(limit: maximumOutputBytes)
        let stderrBuffer = PipeBuffer(limit: maximumOutputBytes)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stdoutBuffer.append(chunk)
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderrBuffer.append(chunk)
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
        try Task.checkCancellation()
        try process.run()
        let processID = process.processIdentifier
        let processGroup = getpgid(processID) == processID ? processID : nil

        do {
            while true {
                try Task.checkCancellation()
                let stdout = stdoutBuffer.state
                let stderr = stderrBuffer.state
                guard !stdout.exceededLimit, !stderr.exceededLimit else {
                    throw ExecutionError(message: "CLI output exceeded its byte limit")
                }
                if clock.now >= deadline {
                    throw ExecutionError(message: process.isRunning
                        ? "CLI execution exceeded its timeout"
                        : "CLI output did not close before the timeout")
                }
                if !process.isRunning, stdout.reachedEOF, stderr.reachedEOF { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            return (process.terminationStatus, try stdoutBuffer.text(), try stderrBuffer.text())
        } catch {
            try Self.stopProcess(process, group: processGroup)
            throw error
        }
    }

    static func processEnvironment(
        from environment: [String: String],
        profile: ProcessProfile = .standard
    ) -> [String: String] {
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
        switch profile {
        case .standard:
            break
        case .codex(let runtimeHome):
            filtered["CODEX_HOME"] = runtimeHome.path
        }
        return filtered
    }

    static func stopProcess(
        _ process: Process,
        group: pid_t?,
        sendSignal: (pid_t, Int32) -> Int32 = Darwin.kill
    ) throws {
        var failedTargets: Set<pid_t> = []
        func groupIsRunning() -> Bool {
            guard let group else { return false }
            return kill(-group, 0) == 0 || errno != ESRCH
        }
        func signal(_ target: pid_t, _ value: Int32) {
            if sendSignal(target, value) == 0 || errno == ESRCH {
                failedTargets.remove(target)
            } else {
                failedTargets.insert(target)
            }
        }
        guard process.isRunning || groupIsRunning() else { return }
        if let group {
            signal(-group, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        while (process.isRunning || groupIsRunning()) && clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let group, groupIsRunning() {
            signal(-group, SIGKILL)
        }
        if process.isRunning {
            signal(process.processIdentifier, SIGKILL)
        }
        guard !failedTargets.contains(where: { kill($0, 0) == 0 || errno != ESRCH }) else {
            throw ExecutionError(message: "Perry could not stop the CLI process")
        }
        if process.isRunning {
            process.waitUntilExit()
        }
    }

}
