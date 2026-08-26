import XCTest
@testable import PerryRuntimes
import PerryCore

final class CodexRuntimeTests: XCTestCase {
    func testPlanArgumentsAreReadOnlyAndEphemeral() {
        let arguments = CodexRuntime.planArguments(
            goal: "rename files",
            context: ScreenContext(frontAppBundleID: "com.apple.finder", frontWindowTitle: "Desktop")
        )
        XCTAssertEqual(arguments.prefix(2), ["exec", "--json"])
        XCTAssertTrue(arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        guard let sandboxIndex = arguments.firstIndex(of: "-s") else {
            return XCTFail("expected -s flag")
        }
        XCTAssertEqual(arguments[sandboxIndex + 1], "read-only")
        XCTAssertTrue(arguments.last?.contains("rename files") == true)
    }

    func testFinalMessageExtractsAgentMessageFromJSONL() {
        let output = """
        {"msg":{"type":"thread.started","thread_id":"t1"}}
        {"msg":{"type":"turn.started"}}
        {"msg":{"type":"item.completed","payload":{"type":"reasoning","text":"thinking"}}}
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","text":"1. Open Finder\\n2. Select files"}}}
        """
        XCTAssertEqual(CodexRuntime.finalMessage(from: output), "1. Open Finder\n2. Select files")
    }

    func testFinalMessageReturnsLastWhenMultiple() {
        let output = """
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","text":"first"}}}
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","text":"second"}}}
        """
        XCTAssertEqual(CodexRuntime.finalMessage(from: output), "second")
    }

    func testFinalMessageIgnoresGarbageLines() {
        let output = """
        not json at all
        {"unrelated":true}
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","text":"answer"}}}
        """
        XCTAssertEqual(CodexRuntime.finalMessage(from: output), "answer")
    }

    func testFinalMessageNilWhenNoAgentMessage() {
        XCTAssertNil(CodexRuntime.finalMessage(from: "{\"msg\":{\"type\":\"turn.started\"}}"))
        XCTAssertNil(CodexRuntime.finalMessage(from: ""))
    }

    func testFinalMessageJoinsContentBlocks() {
        let output = """
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","content":[{"text":"1. One"},{"text":"\\n2. Two"}]}}}
        """
        XCTAssertEqual(CodexRuntime.finalMessage(from: output), "1. One\n2. Two")
    }

    func testPlanParsesNumberedStepsThroughFakeCodex() async throws {
        let runtime = CodexRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            commandRunner: { @Sendable _, arguments in
                XCTAssertTrue(arguments.contains("--json"))
                let prompt = arguments.last ?? ""
                return [
                    "{\"msg\":{\"type\":\"item.completed\",\"payload\":{\"type\":\"agent_message\",\"text\":\"1. Click File menu\\n2. Choose Rename\"}}}",
                ].joined(separator: "\n")
            },
            timeout: 5
        )
        let plan = try await runtime.plan(goal: "rename files", context: .empty)
        XCTAssertEqual(plan.runtimeID, "cli.codex")
        XCTAssertEqual(plan.steps.map(\.summary), ["Click File menu", "Choose Rename"])
    }

    func testExecuteRunsWorkspaceWriteSandbox() async throws {
        var observedArguments: [String] = []
        let runtime = CodexRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            commandRunner: { @Sendable _, arguments in
                observedArguments = arguments
                return "{\"msg\":{\"type\":\"item.completed\",\"payload\":{\"type\":\"agent_message\",\"text\":\"done\"}}}"
            },
            timeout: 5
        )
        let step = Step(kind: .delegate, summary: "tidy up", payload: ["goal": "tidy up"])
        let result = try await runtime.execute(step, consent: nil)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "done")
        guard let sandboxIndex = observedArguments.firstIndex(of: "-s") else {
            return XCTFail("expected -s flag")
        }
        XCTAssertEqual(observedArguments[sandboxIndex + 1], "workspace-write")
    }

    func testExecuteRejectsNonDelegateSteps() async {
        let runtime = CodexRuntime(executableLocator: { URL(fileURLWithPath: "/bin/echo") }, timeout: 5)
        do {
            _ = try await runtime.execute(Step(kind: .clickControl, summary: "click"), consent: nil)
            XCTFail("expected ExecutionError")
        } catch {
            XCTAssertTrue("\(error)".contains("delegates whole tasks"))
        }
    }

    func testLocatorPrefersOverrideThenBundleThenPath() throws {
        let override = try CodexRuntime.bundledLocator(
            bundle: .main,
            environment: ["PERRY_CODEX_PATH": "/usr/local/bin/codex"]
        )
        XCTAssertEqual(override.path, "/usr/local/bin/codex")

        let bundle = Bundle(for: BundleToken.self)
        do {
            _ = try CodexRuntime.bundledLocator(bundle: bundle, environment: [:])
            XCTFail("expected CLIUnavailableError for a bundle without the runtime")
        } catch let error as CLIUnavailableError {
            XCTAssertTrue(error.searchedPaths.contains { $0.contains("CodexRuntime/bin/codex") })
        }
    }
}

private final class BundleToken {}
