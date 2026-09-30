import Foundation
import PerryCore

public struct OpenCodeRuntime: TaskPlanner {
    public let id = "cli.opencode"
    public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, remoteIntegrations: true, latencyClass: .medium)

    public static let pinnedVersion = "1.18.32"
    public static let pinnedBinarySHA256 = "a3c45d4e1d6620b436851f1ef6b25c71befcf06a382e279a1eb1c2196424395e"

    private let locateExecutable: @Sendable () throws -> URL
    private let invokeCommand: @Sendable (URL, [String]) async throws -> String

    public init(
        executableLocator: @escaping @Sendable () throws -> URL = OpenCodeRuntime.standardLocator,
        commandRunner: (@Sendable (URL, [String]) async throws -> String)? = nil,
        timeout: TimeInterval = 120,
        workingDirectory: URL? = nil
    ) {
        locateExecutable = executableLocator
        if let commandRunner {
            invokeCommand = commandRunner
        } else {
            invokeCommand = { executable, arguments in
                let result = try await CLIRuntime.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    workingDirectory: workingDirectory,
                    profile: .openCodePlanning
                )
                guard result.exitCode == 0 else {
                    throw ExecutionError(message: "OpenCode exited \(result.exitCode): \(result.stderr)")
                }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    public func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        guard case .screen(let context) = request.context else {
            throw PlanningError.contextRequired
        }
        let output = try await invokeCommand(try locateExecutable(), [
            "run",
            "--pure",
            "--agent", "perry",
            TypedPlanningPrompt.make(goal: request.goal, context: context),
        ])
        return try TypedPlanParser.plan(
            output,
            request: request,
            bindings: .init(request: request, context: context)
        )
    }

    public static let standardLocator: @Sendable () throws -> URL = {
        try locateExecutable()
    }

    public static func authenticationStatus(executable: URL) async throws -> RuntimeAuthenticationStatus {
        do {
            try Task.checkCancellation()
            let result = try await CLIRuntime.runProcess(
                executable: executable,
                arguments: ["auth", "list", "--pure"],
                timeout: 3
            )
            try Task.checkCancellation()
            return authenticationStatus(output: result.stdout + "\n" + result.stderr, exitCode: result.exitCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown(reason: "OpenCode could not inspect its configured provider credentials")
        }
    }

    static func authenticationStatus(output: String, exitCode: Int32) -> RuntimeAuthenticationStatus {
        guard exitCode == 0 else {
            return .unknown(reason: "OpenCode could not inspect its configured provider credentials")
        }
        let plainText = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression
        )
        let counts = plainText.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "└ "))
                .split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == "credentials",
                  !fields[0].isEmpty, fields[0].allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            return Int(fields[0])
        }
        guard counts.count == 1, let count = counts.first else {
            return .unknown(reason: "OpenCode returned an unrecognized credential listing")
        }
        return count > 0 ? .configured : .missing
    }

    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let paths = [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.local/bin/opencode",
        ]
        for path in paths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CLIUnavailableError(searchedPaths: paths)
    }
}
