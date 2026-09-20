import XCTest
@testable import PerryRuntimes
import PerryCore

final class OpenCodeRuntimeTests: XCTestCase {
    func testCancelledCredentialInspectionDoesNotBecomeUnknownStatus() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenCodeRuntime.authenticationStatus(executable: URL(fileURLWithPath: "/must-not-run/opencode"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate instead of publishing an authentication state")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testAuthenticationStatusUsesCredentialListingFromStderr() async throws {
        let fixture = try AuthenticationProcessFixture(stderr: "└ 1 credentials")
        addTeardownBlock { try fixture.cleanup() }

        let status = try await OpenCodeRuntime.authenticationStatus(executable: fixture.executable)

        XCTAssertTrue(fixture.wasLaunched)
        XCTAssertEqual(status, .configured)
    }

    func testAuthenticationStatusDoesNotExposeProcessFailureOutput() async throws {
        let fixture = try AuthenticationProcessFixture(
            stdout: AuthenticationProcessFixture.seededSecret,
            stderr: AuthenticationProcessFixture.seededSecret,
            exitCode: 37
        )
        addTeardownBlock { try fixture.cleanup() }

        let status = try await OpenCodeRuntime.authenticationStatus(executable: fixture.executable)

        XCTAssertTrue(fixture.wasLaunched)
        guard case .unknown(let reason) = status else {
            return XCTFail("A failed authentication process must remain unknown")
        }
        XCTAssertEqual(reason, "OpenCode could not inspect its configured provider credentials")
        XCTAssertFalse(reason.contains(AuthenticationProcessFixture.seededSecret))
    }

    func testLaunchFailureDoesNotExposeExecutablePath() async throws {
        let fixture = try AuthenticationProcessFixture()
        addTeardownBlock { try fixture.cleanup() }
        let missing = fixture.executable.appendingPathComponent(AuthenticationProcessFixture.seededSecret)

        let status = try await OpenCodeRuntime.authenticationStatus(executable: missing)

        XCTAssertFalse(fixture.wasLaunched)
        XCTAssertEqual(status, .unknown(reason: "OpenCode could not inspect its configured provider credentials"))
    }

    func testCancelledAuthenticationStatusAfterLaunchPropagatesCancellation() async throws {
        let fixture = try AuthenticationProcessFixture(waitsForCancellation: true)
        addTeardownBlock { try fixture.cleanup() }
        let executable = fixture.executable
        let task = Task {
            try await OpenCodeRuntime.authenticationStatus(executable: executable)
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

    func testCredentialListingDoesNotClaimProviderAuthentication() {
        for count in [1, 2, 10, 20, 100] {
            let output = "┌ Credentials ~/.local/share/opencode/auth.json\n│ Example api\n└ \(count) credentials\n"
            XCTAssertEqual(OpenCodeRuntime.authenticationStatus(output: output, exitCode: 0), .configured)
        }
    }

    func testEmptyAndColoredCredentialListings() {
        XCTAssertEqual(OpenCodeRuntime.authenticationStatus(output: "└ 0 credentials\n", exitCode: 0), .missing)
        XCTAssertEqual(
            OpenCodeRuntime.authenticationStatus(output: "\u{001B}[90m└\u{001B}[0m  10 credentials\n", exitCode: 0),
            .configured
        )
    }

    func testMalformedCredentialListingsFailClosed() {
        for output in ["", "Credentials", "no credentials found", "-1 credentials", "1 credentials extra", "1 credentials\n0 credentials", "999999999999999999999999999 credentials"] {
            let status = OpenCodeRuntime.authenticationStatus(output: output, exitCode: 0)
            XCTAssertFalse(status.isUsable, output)
            guard case .unknown = status else {
                XCTFail("Malformed output must remain unknown")
                continue
            }
        }
        XCTAssertFalse(OpenCodeRuntime.authenticationStatus(output: "└ 1 credentials", exitCode: 1).isUsable)
    }

    func testPlanUsesPureReadOnlyProfileAndParsesTypedActions() async throws {
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.example.App", processID: 42, windowID: 7, connectionGeneration: 1
        )
        let runtime = OpenCodeRuntime(
            executableLocator: { URL(fileURLWithPath: "/verified/opencode") },
            commandRunner: { executable, arguments in
                XCTAssertEqual(executable.path, "/verified/opencode")
                XCTAssertEqual(arguments.prefix(4), ["run", "--pure", "--agent", "perry"])
                XCTAssertTrue(arguments.last?.contains("Respond with one JSON object") == true)
                return """
                {"actions":[{"summary":"click save","operation":{"computer":{"command":{"click":{"target":{"accessibilityID":"save-button"}}}}}}]}
                """
            }
        )

        let request = try PlanningRequest(
            goal: "Save",
            taskID: TaskID("opencode-test"),
            workspace: FileManager.default.temporaryDirectory,
            context: .screen(ScreenContext(screenshotJPEGData: Data([1]), targetWindow: window))
        )
        let plan = try await runtime.plan(request)

        XCTAssertEqual(plan.actions.count, 1)
        guard case .computer(let boundWindow, let command) = plan.actions[0].operation,
              case .click(let selector) = command,
              case .accessibilityID(let target) = selector else {
            return XCTFail("expected a bound computer click action")
        }
        XCTAssertEqual(target, "save-button")
        XCTAssertEqual(boundWindow, window)
    }

    func testPlanRejectsNonActionOutput() async throws {
        let runtime = OpenCodeRuntime(
            executableLocator: { URL(fileURLWithPath: "/verified/opencode") },
            commandRunner: { _, _ in "1. decide what to do later" }
        )

        do {
            _ = try await runtime.plan(PlanningRequest(
                goal: "Do it",
                taskID: TaskID("opencode-test"),
                workspace: FileManager.default.temporaryDirectory,
                context: .screen(ScreenContext())
            ))
            XCTFail("Expected non-JSON output to fail")
        } catch {
            // strict typed parser rejects numbered prose
        }
    }

    func testPlanningProfileOverridesProjectAndDeniesEveryTool() throws {
        let environment = CLIRuntime.processEnvironment(from: [:], profile: .openCodePlanning)
        let configText = try XCTUnwrap(environment["OPENCODE_CONFIG_CONTENT"])
        let configData = try XCTUnwrap(configText.data(using: .utf8))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let agents = try XCTUnwrap(config["agent"] as? [String: Any])
        let perry = try XCTUnwrap(agents["perry"] as? [String: Any])
        let permissions = try XCTUnwrap(perry["permission"] as? [String: String])
        let expectedTools: Set<String> = [
            "read", "edit", "glob", "grep", "list", "bash", "task", "external_directory",
            "todowrite", "question", "webfetch", "websearch", "lsp", "doom_loop", "skill",
        ]

        XCTAssertEqual(environment["OPENCODE_DISABLE_PROJECT_CONFIG"], "true")
        XCTAssertEqual(Set(permissions.keys), expectedTools)
        XCTAssertTrue(permissions.values.allSatisfy { $0 == "deny" })
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    }
}
