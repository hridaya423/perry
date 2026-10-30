import Foundation
import PerryCore

public struct CodexRuntime: Sendable {
    public let id = "cli.codex"

    public static let pinnedVersion = "0.158.0"
    public static let pinnedBinarySHA256 = "788a818fbb9596869c7a487554507cb8bdca17584b8671112b23f9e225ba35c8"

    public static func authenticationStatus(executable: URL, runtimeHome: URL?) async throws -> RuntimeAuthenticationStatus {
        try Task.checkCancellation()
        guard let runtimeHome else {
            return .unknown(reason: "Perry could not prepare its Codex runtime directory")
        }
        do {
            let result = try await CLIRuntime.runProcess(
                executable: executable,
                arguments: ["login", "status"],
                timeout: 3,
                profile: .codex(runtimeHome: runtimeHome)
            )
            try Task.checkCancellation()
            return authenticationStatus(stderr: result.stderr, exitCode: result.exitCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown(reason: "Codex could not verify its official login state")
        }
    }

    static func authenticationStatus(stderr: String, exitCode: Int32) -> RuntimeAuthenticationStatus {
        let lines = stderr.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let signedIn = lines.filter {
            $0 == "Logged in using ChatGPT" || $0 == "Logged in using access token"
                || ($0.hasPrefix("Logged in using an API key - ") && $0.count > "Logged in using an API key - ".count)
        }
        let signedOut = lines.filter { $0 == "Not logged in" }
        if exitCode == 0, signedIn.count == 1, signedOut.isEmpty {
            return .authenticated
        }
        if exitCode == 1, signedOut.count == 1, signedIn.isEmpty {
            return .missing
        }
        return .unknown(reason: "Codex returned an unrecognized login status")
    }

    private let locateExecutable: @Sendable () throws -> URL
    private let invokeCommand: @Sendable (URL, [String]) async throws -> String
    private let timeout: TimeInterval
    private let workingDirectory: URL?

    public init(
        executableLocator: @escaping @Sendable () throws -> URL = { try CodexRuntime.bundledLocator() },
        commandRunner: (@Sendable (URL, [String]) async throws -> String)? = nil,
        timeout: TimeInterval = 300,
        workingDirectory: URL? = nil,
        runtimeHome: URL? = nil
    ) {
        self.locateExecutable = executableLocator
        self.timeout = timeout
        self.workingDirectory = workingDirectory
        if let commandRunner {
            self.invokeCommand = commandRunner
        } else {
            self.invokeCommand = { @Sendable executable, arguments in
                let profile = runtimeHome.map(CLIRuntime.ProcessProfile.codex) ?? .standard
                let result = try await CLIRuntime.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    workingDirectory: workingDirectory,
                    profile: profile
                )
                guard result.exitCode == 0 else {
                    throw ExecutionError(message: "codex exited \(result.exitCode): \(result.stderr)")
                }
                return result.stdout
            }
        }
    }

    public func runCodingTask(prompt: String) async throws -> String {
        guard workingDirectory != nil else {
            throw ExecutionError(message: "delegated execution requires an explicit workspace boundary")
        }
        let output = try await invoke(
            arguments: ["exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "--ephemeral", "--ignore-user-config", prompt]
        )
        return Self.finalMessage(from: output) ?? output
    }

    func invoke(arguments: [String]) async throws -> String {
        let executable = try locateExecutable()
        return try await invokeCommand(executable, arguments)
    }

    static func finalMessage(from jsonlOutput: String) -> String? {
        jsonlOutput
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(CodexJSONLEvent.self, from: data) else { return nil }
                return event.agentMessage
            }
            .last
    }
}

struct CodexJSONLEvent: Decodable {
    private(set) var agentMessage: String?

    private enum TopKeys: String, CodingKey { case msg }
    private enum MsgKeys: String, CodingKey { case type, payload }
    private enum PayloadKeys: String, CodingKey { case itemType = "type", text, content }
    private enum ContentKeys: String, CodingKey { case text }

    init(from decoder: Decoder) throws {
        agentMessage = nil

        let top = try decoder.container(keyedBy: TopKeys.self)
        guard let msg = try? top.nestedContainer(keyedBy: MsgKeys.self, forKey: .msg),
              try msg.decodeIfPresent(String.self, forKey: .type) == "item.completed",
              let payload = try? msg.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload),
              try payload.decodeIfPresent(String.self, forKey: .itemType) == "agent_message" else { return }

        if let text = try payload.decodeIfPresent(String.self, forKey: .text), !text.isEmpty {
            agentMessage = text
            return
        }
        if let contents = try? payload.decodeIfPresent([ContentBlock].self, forKey: .content) {
            agentMessage = contents.compactMap(\.text).joined()
        }
    }

    struct ContentBlock: Decodable {
        let text: String?
    }
}

extension CodexRuntime {
    public static func bundledLocator(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let bundledPath = "\(bundle.bundlePath)/Contents/Resources/CodexRuntime/bin/codex"
        let searched = [bundledPath]
        if let bundled = bundle.url(forResource: "codex", withExtension: nil, subdirectory: "CodexRuntime/bin") {
            if fileManager.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        throw CLIUnavailableError(searchedPaths: searched)
    }
}
