import Foundation
import PerryCore

/// Agent runtime backed by a pinned, app-bundled OpenAI codex CLI.
///
/// Planning runs `codex exec --json` in the read-only sandbox and parses the
/// JSONL event stream for the agent's final message. Execution re-runs the
/// goal under `workspace-write` (PRD §7 sandbox default); tier enforcement
/// stays in DoSupervisor's confirmer, which sits in front of this runtime.
public struct CodexRuntime: AgentRuntime {
    public let id = "cli.codex"
    public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, latencyClass: .medium)

    static let pinnedVersion = "0.132.0"

    private let locateExecutable: @Sendable () throws -> URL
    private let invokeCommand: @Sendable (URL, [String]) async throws -> String
    private let timeout: TimeInterval

    public init(
        executableLocator: @escaping @Sendable () throws -> URL = { try CodexRuntime.bundledLocator() },
        commandRunner: ((URL, [String]) async throws -> String)? = nil,
        timeout: TimeInterval = 300
    ) {
        self.locateExecutable = executableLocator
        self.timeout = timeout
        if let commandRunner {
            self.invokeCommand = commandRunner
        } else {
            self.invokeCommand = { @Sendable executable, arguments in
                let result = try await CLIRuntime.runProcess(executable: executable, arguments: arguments, timeout: timeout)
                guard result.exitCode == 0 else {
                    throw ExecutionError(message: "codex exited \(result.exitCode): \(result.stderr)")
                }
                return result.stdout
            }
        }
    }

    public func plan(goal: String, context: ScreenContext) async throws -> Plan {
        let output = try await invoke(arguments: Self.planArguments(goal: goal, context: context))
        return Plan(goal: goal, runtimeID: id, steps: CLIRuntime.parseNumberedSteps(Self.finalMessage(from: output) ?? output, goal: goal))
    }

    public func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult {
        guard step.kind == .delegate else {
            throw ExecutionError(message: "runtime \(id) delegates whole tasks, not individual \(step.kind.rawValue) steps")
        }
        let goal = step.payload["goal"] ?? step.summary
        let output = try await invoke(
            arguments: ["exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "--ephemeral", goal]
        )
        return StepResult(stepID: step.id, success: true, message: Self.finalMessage(from: output) ?? output)
    }

    func invoke(arguments: [String]) async throws -> String {
        let executable = try locateExecutable()
        return try await invokeCommand(executable, arguments)
    }

    /// Plan calls must never write. Read-only sandbox, user config ignored so
    /// a local ~/.codex/config.toml can't flip permissions behind our back.
    static func planArguments(goal: String, context: ScreenContext) -> [String] {
        var screenNote = ""
        if let title = context.frontWindowTitle, let bundleID = context.frontAppBundleID {
            screenNote = "The frontmost window is \"\(title)\" (\(bundleID)). "
        }
        let prompt = """
        \(screenNote)Break this goal into concrete macOS steps, one per line, \
        numbered like "1. <step>": \(goal)
        Respond with the numbered list only.
        """
        return [
            "exec", "--json", "--skip-git-repo-check",
            "-s", "read-only", "--ephemeral", "--ignore-user-config",
            prompt,
        ]
    }

    /// The JSONL stream mixes event kinds; the final assistant answer arrives
    /// as an item.completed event whose item type is agent_message.
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

/// One line of `codex exec --json` output. Lines that aren't item.completed /
/// agent_message events decode to an empty event and are ignored by callers.
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
    /// App-bundle runtime first (Resources/CodexRuntime/bin/codex), then a
    /// user-installed codex on PATH as fallback.
    public static func bundledLocator(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        var searched: [String] = []
        if let override = environment["PERRY_CODEX_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundle.url(forResource: "codex", withExtension: nil, subdirectory: "CodexRuntime/bin") {
            return bundled
        } else {
            searched.append("\(bundle.bundlePath)/Contents/Resources/CodexRuntime/bin/codex")
        }
        if let pathDirectories = environment["PATH"], !pathDirectories.isEmpty {
            for directory in pathDirectories.split(separator: ":") {
                let candidate = "\(directory)/codex"
                searched.append(candidate)
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        throw CLIUnavailableError(searchedPaths: searched)
    }
}

