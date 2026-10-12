import XCTest
@testable import PerryRuntimes
import PerryCore

final class CodexRuntimeTests: XCTestCase {
    func testLoginStatusRecognizesPinnedStderrMessages() {
        for status in ["Logged in using ChatGPT", "Logged in using access token", "Logged in using an API key - ***"] {
            XCTAssertEqual(CodexRuntime.authenticationStatus(stderr: status + "\n", exitCode: 0), .authenticated)
        }
        XCTAssertEqual(CodexRuntime.authenticationStatus(stderr: "Not logged in\n", exitCode: 1), .missing)
    }

    func testLoginStatusRejectsMalformedAndContradictoryResults() {
        for status in ["", "Not logged in", "not really logged in", "Logged in using an API key - ", "Logged in using ChatGPT\nNot logged in", "Logged in using ChatGPT\nLogged in using ChatGPT"] {
            guard case .unknown = CodexRuntime.authenticationStatus(stderr: status, exitCode: 0) else {
                XCTFail("Unexpected login result must not claim authentication")
                continue
            }
        }
        XCTAssertFalse(CodexRuntime.authenticationStatus(stderr: "Logged in using ChatGPT", exitCode: 1).isUsable)
    }

    func testCancelledLoginInspectionDoesNotLaunchOrPublishStatus() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexRuntime.authenticationStatus(
                executable: URL(fileURLWithPath: "/must-not-run/codex"), runtimeHome: nil
            )
        }
        do {
            _ = try await task.value
            XCTFail("Canceled inspection must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testAuthenticationStatusIgnoresValidLoginTextOnStdout() async throws {
        let fixture = try AuthenticationProcessFixture(stdout: "Logged in using ChatGPT")
        addTeardownBlock { try fixture.cleanup() }

        let status = try await CodexRuntime.authenticationStatus(
            executable: fixture.executable,
            runtimeHome: fixture.codexHome
        )

        XCTAssertTrue(fixture.wasLaunched)
        XCTAssertEqual(status, .unknown(reason: "Codex returned an unrecognized login status"))
    }

    func testAuthenticationStatusDoesNotExposeProcessFailureOutput() async throws {
        let fixture = try AuthenticationProcessFixture(
            stdout: AuthenticationProcessFixture.seededSecret,
            stderr: AuthenticationProcessFixture.seededSecret,
            exitCode: 37
        )
        addTeardownBlock { try fixture.cleanup() }

        let status = try await CodexRuntime.authenticationStatus(
            executable: fixture.executable,
            runtimeHome: fixture.codexHome
        )

        XCTAssertTrue(fixture.wasLaunched)
        guard case .unknown(let reason) = status else {
            return XCTFail("A failed authentication process must remain unknown")
        }
        XCTAssertEqual(reason, "Codex returned an unrecognized login status")
        XCTAssertFalse(reason.contains(AuthenticationProcessFixture.seededSecret))
    }

    func testLaunchFailureDoesNotExposeExecutablePath() async throws {
        let fixture = try AuthenticationProcessFixture()
        addTeardownBlock { try fixture.cleanup() }
        let missing = fixture.executable.appendingPathComponent(AuthenticationProcessFixture.seededSecret)

        let status = try await CodexRuntime.authenticationStatus(executable: missing, runtimeHome: fixture.codexHome)

        XCTAssertFalse(fixture.wasLaunched)
        XCTAssertEqual(status, .unknown(reason: "Codex could not verify its official login state"))
    }

    func testCancelledAuthenticationStatusAfterLaunchPropagatesCancellation() async throws {
        let fixture = try AuthenticationProcessFixture(waitsForCancellation: true)
        addTeardownBlock { try fixture.cleanup() }
        let executable = fixture.executable
        let codexHome = fixture.codexHome
        let task = Task {
            try await CodexRuntime.authenticationStatus(
                executable: executable,
                runtimeHome: codexHome
            )
        }

        let launched = await fixture.waitUntilLaunched()
        task.cancel()
        XCTAssertTrue(launched, "Authentication fixture did not launch")

        do {
            _ = try await task.value
            XCTFail("Cancellation after launch must propagate")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testRunCodingTaskRequiresWorkspaceBoundary() async {
        let runtime = CodexRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            commandRunner: { @Sendable _, _ in
                XCTFail("coding task must not invoke Codex without a workspace")
                return ""
            }
        )

        do {
            _ = try await runtime.runCodingTask(prompt: "do everything")
            XCTFail("expected workspace requirement")
        } catch let error as ExecutionError {
            XCTAssertEqual(error.message, "delegated execution requires an explicit workspace boundary")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFinalMessageExtractsAgentMessageFromJSONL() {
        let output = """
        {"msg":{"type":"thread.started","thread_id":"t1"}}
        {"msg":{"type":"turn.started"}}
        {"msg":{"type":"item.completed","payload":{"type":"reasoning","text":"thinking"}}}
        {"msg":{"type":"item.completed","payload":{"type":"agent_message","text":"{\\"actions\\":[]}"}}}
        """
        XCTAssertEqual(CodexRuntime.finalMessage(from: output), #"{"actions":[]}"#)
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

    func testRunCodingTaskRunsWorkspaceWriteSandbox() async throws {
        let observedArguments = LockedValue<[String]>([])
        let runtime = CodexRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            commandRunner: { @Sendable _, arguments in
                observedArguments.value = arguments
                return "{\"msg\":{\"type\":\"item.completed\",\"payload\":{\"type\":\"agent_message\",\"text\":\"done\"}}}"
            },
            timeout: 5,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let result = try await runtime.runCodingTask(prompt: "tidy up")
        XCTAssertEqual(result, "done")
        guard let sandboxIndex = observedArguments.value.firstIndex(of: "-s") else {
            return XCTFail("expected -s flag")
        }
        XCTAssertEqual(observedArguments.value[sandboxIndex + 1], "workspace-write")
        XCTAssertTrue(observedArguments.value.contains("--ignore-user-config"))
    }

    func testLocatorRejectsUnverifiedOverrideAndPATH() {
        let bundle = Bundle(for: BundleToken.self)
        XCTAssertThrowsError(
            try CodexRuntime.bundledLocator(
                bundle: bundle,
                environment: ["PERRY_CODEX_PATH": "/bin/echo", "PATH": "/bin"]
            )
        ) { error in
            guard let unavailable = error as? CLIUnavailableError else {
                return XCTFail("expected CLIUnavailableError, got \(error)")
            }
            XCTAssertTrue(unavailable.searchedPaths.contains { $0.contains("CodexRuntime/bin/codex") })
            XCTAssertFalse(unavailable.searchedPaths.contains("/bin/codex"))
        }
    }

    private func makeWorkspace() -> URL {
        FileManager.default.temporaryDirectory
    }
}

private final class BundleToken {}
