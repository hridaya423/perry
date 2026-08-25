import Foundation
import PerryCore

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public struct CLIRuntime: AgentRuntime {
    public let id = "cli.claude-code"
    public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, latencyClass: .medium)

    private let locateExecutable: @Sendable () throws -> URL
    private let invokeCommand: @Sendable (URL, [String]) async throws -> String
    private let timeout: TimeInterval

    public init(
        executableLocator: @escaping @Sendable () throws -> URL = CLIRuntime.standardLocator,
        commandRunner: ((URL, [String]) async throws -> String)? = nil,
        timeout: TimeInterval = 120
    ) {
        self.locateExecutable = executableLocator
        self.timeout = timeout
        if let commandRunner {
            self.invokeCommand = commandRunner
        } else {
            self.invokeCommand = { @Sendable executable, arguments in
                let result = try await Self.runProcess(executable: executable, arguments: arguments, timeout: timeout)
                guard result.exitCode == 0 else {
                    throw ExecutionError(message: "CLI exited \(result.exitCode): \(result.stderr)")
                }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    public func plan(goal: String, context: ScreenContext) async throws -> Plan {
        let screenNote: String
        if let title = context.frontWindowTitle, let bundleID = context.frontAppBundleID {
            screenNote = "The frontmost window is \"\(title)\" (\(bundleID)). "
        } else {
            screenNote = ""
        }
        let prompt = """
        \(screenNote)Break this goal into concrete macOS steps, one per line, \
        numbered like "1. <step>": \(goal)
        Respond with the numbered list only.
        """
        let output = try await invoke(["-p", prompt])
        return Plan(goal: goal, runtimeID: id, steps: Self.parseNumberedSteps(output, goal: goal))
    }

    public func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult {
        guard step.kind == .delegate else {
            throw ExecutionError(message: "runtime \(id) delegates whole tasks, not individual \(step.kind.rawValue) steps")
        }
        let goal = step.payload["goal"] ?? step.summary
        let output = try await invoke(["-p", goal])
        return StepResult(stepID: step.id, success: true, message: output)
    }

    func invoke(_ arguments: [String]) async throws -> String {
        let executable = try locateExecutable()
        return try await invokeCommand(executable, arguments)
    }

    static func parseNumberedSteps(_ text: String, goal: String) -> [Step] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let numbered = lines.compactMap { line -> String? in
            guard let matchRange = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else {
                return nil
            }
            return String(line[matchRange.upperBound...])
        }
        guard !numbered.isEmpty else {
            return [Step(kind: .delegate, summary: goal, payload: ["goal": goal])]
        }
        return numbered.map { line in
            Step(kind: .delegate, summary: line, payload: ["goal": line])
        }
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
        if let override = environment["PERRY_CLAUDE_CODE_PATH"], !override.isEmpty {
            candidates.append(candidate(override))
        }
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

    static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(chunk)
        }

        try process.run()

        let finished = process.waitUntilExit(withTimeout: timeout)
        if !finished {
            process.terminate()
        }
        process.waitUntilExit()

        return (process.terminationStatus, stdoutBuffer.string, stderrBuffer.string)
    }
}

extension Process {
    func waitUntilExit(withTimeout seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isRunning
    }
}
