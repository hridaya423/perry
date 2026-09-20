import XCTest
import CryptoKit
@testable import PerryRuntimes
import PerryCore

final class LiveRuntimePlanningSmokeTests: XCTestCase {
    func testBundledCodexCredentialInspection() async throws {
        try requireLiveSmokes()
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try XCTUnwrap(environment["PERRY_BUNDLED_CODEX_PATH"]))
        let runtimeHome = URL(fileURLWithPath: try XCTUnwrap(environment["PERRY_CODEX_RUNTIME_HOME"]), isDirectory: true)
        let digest = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == CodexRuntime.pinnedBinarySHA256 else {
            XCTFail("Codex executable does not match the pinned release")
            return
        }
        let status = try await CodexRuntime.authenticationStatus(executable: executable, runtimeHome: runtimeHome)
        XCTAssertTrue(status == .authenticated || status == .missing, "Login inspection failed: \(status.explanation)")
    }

    func testBundledCodexPlanning() async throws {
        try requireLiveSmokes()
        let environment = ProcessInfo.processInfo.environment
        let executablePath = try XCTUnwrap(environment["PERRY_BUNDLED_CODEX_PATH"])
        let runtimeHomePath = try XCTUnwrap(environment["PERRY_CODEX_RUNTIME_HOME"])
        let executable = URL(fileURLWithPath: executablePath)
        let runtimeHome = URL(fileURLWithPath: runtimeHomePath, isDirectory: true)
        let authentication = try await CLIRuntime.runProcess(
            executable: executable,
            arguments: ["login", "status"],
            timeout: 10,
            profile: .codex(runtimeHome: runtimeHome)
        )
        guard authentication.exitCode == 0 else {
            throw XCTSkip("Perry's bundled Codex runtime is not signed in")
        }

        let plan = try await CodexRuntime(
            executableLocator: { executable },
            runtimeHome: runtimeHome
        ).plan(try planningRequest())

        XCTAssertFalse(plan.actions.isEmpty)
    }

    func testClaudePlanning() async throws {
        try requireLiveSmokes()
        let executable = try CLIRuntime.locateExecutable()
        let authentication = try await CLIRuntime.runProcess(
            executable: executable,
            arguments: ["auth", "status"],
            timeout: 10
        )
        guard authentication.exitCode == 0,
              authentication.stdout.contains(#""loggedIn": true"#) else {
            throw XCTSkip("Claude Code is not signed in")
        }

        let plan = try await CLIRuntime().plan(try planningRequest())

        XCTAssertFalse(plan.actions.isEmpty)
    }

    func testClaudeCredentialInspection() async throws {
        try requireLiveSmokes()
        let executable = try CLIRuntime.locateExecutable().resolvingSymlinksInPath().standardizedFileURL
        let identity = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--verify", "--strict", "-R",
                "=identifier \"com.anthropic.claude-code\" and anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"",
                executable.path,
            ],
            timeout: 3
        )
        guard identity.exitCode == 0 else {
            XCTFail("Claude Code executable does not match Anthropic's signing identity")
            return
        }
        let status = try await CLIRuntime.authenticationStatus(executable: executable)
        XCTAssertTrue(status == .authenticated || status == .missing, "Login inspection failed: \(status.explanation)")
    }

    func testOpenCodePlanning() async throws {
        try requireLiveSmokes()
        _ = try OpenCodeRuntime.locateExecutable()

        let plan = try await OpenCodeRuntime().plan(try planningRequest())

        XCTAssertFalse(plan.actions.isEmpty)
    }

    func testOpenCodeCredentialInspection() async throws {
        try requireLiveSmokes()
        let executable = try OpenCodeRuntime.locateExecutable()
        let digest = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == OpenCodeRuntime.pinnedBinarySHA256 else {
            XCTFail("OpenCode executable does not match the pinned release")
            return
        }
        let status = try await OpenCodeRuntime.authenticationStatus(executable: executable)
        XCTAssertTrue(status == .configured || status == .missing, "Credential inspection failed: \(status.explanation)")
    }

    private func planningRequest() throws -> PlanningRequest {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-live-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return try PlanningRequest(
            goal: #"Create exactly one workspace file action: create the file "smoke.txt" with contents "ok"."#,
            taskID: TaskID("live-smoke"),
            workspace: workspace,
            context: .screen(ScreenContext(frontAppBundleID: "com.example.Smoke"))
        )
    }

    private func requireLiveSmokes() throws {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip("Set PERRY_LIVE_RUNTIME_SMOKE=1 to run authenticated planning smokes")
        }
    }
}

final class LiveDirectProviderPlanningSmokeTests: XCTestCase {
    func testOpenAIPlanning() async throws {
        try await run(provider: .openAI, keyVariable: "PERRY_TEST_OPENAI_API_KEY", modelVariable: "PERRY_TEST_OPENAI_MODEL")
    }

    func testAnthropicPlanning() async throws {
        try await run(provider: .anthropic, keyVariable: "PERRY_TEST_ANTHROPIC_API_KEY", modelVariable: "PERRY_TEST_ANTHROPIC_MODEL")
    }

    func testGeminiPlanning() async throws {
        try await run(provider: .gemini, keyVariable: "PERRY_TEST_GEMINI_API_KEY", modelVariable: "PERRY_TEST_GEMINI_MODEL")
    }

    func testOpenRouterPlanning() async throws {
        try await run(provider: .openRouter, keyVariable: "PERRY_TEST_OPENROUTER_API_KEY", modelVariable: "PERRY_TEST_OPENROUTER_MODEL")
    }

    private func run(provider: DirectAIProvider, keyVariable: String, modelVariable: String) async throws {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_DIRECT_PROVIDER_SMOKE"] == "1" else {
            throw XCTSkip("Set PERRY_LIVE_DIRECT_PROVIDER_SMOKE=1 to run direct-provider planning smokes")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment[keyVariable], !apiKey.isEmpty,
              let model = environment[modelVariable], !model.isEmpty else {
            throw XCTSkip("Set \(keyVariable) and \(modelVariable) to test \(provider.displayName)")
        }
        let runtime = DirectProviderRuntime(
            configuration: DirectProviderConfiguration(provider: provider, model: model),
            apiKeyProvider: { apiKey }
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-live-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let request = try PlanningRequest(
            goal: #"Create exactly one workspace file action: create the file "smoke.txt" with contents "ok"."#,
            taskID: TaskID("live-smoke"),
            workspace: workspace,
            context: .screen(ScreenContext(frontAppBundleID: "com.example.Smoke"))
        )

        let plan = try await runtime.plan(request)

        XCTAssertFalse(plan.actions.isEmpty)
    }
}
