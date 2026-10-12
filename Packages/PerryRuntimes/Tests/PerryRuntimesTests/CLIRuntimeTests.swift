import XCTest
@testable import PerryRuntimes
import PerryCore

final class CLIRuntimeTests: XCTestCase {
    func testLoginStatusRequiresTypedJSONAndMatchingExitStatus() {
        XCTAssertEqual(CLIRuntime.authenticationStatus(stdout: #"{"loggedIn":true}"#, exitCode: 0), .authenticated)
        XCTAssertEqual(CLIRuntime.authenticationStatus(stdout: #"{"loggedIn":false}"#, exitCode: 1), .missing)
        for output in [#"{"loggedIn":1}"#, #"{"loggedIn":"true"}"#, "{}", "not json", #"{"loggedIn":null}"#] {
            guard case .unknown = CLIRuntime.authenticationStatus(stdout: output, exitCode: 0) else {
                XCTFail("Malformed login status must stay unknown")
                continue
            }
        }
        XCTAssertFalse(CLIRuntime.authenticationStatus(stdout: #"{"loggedIn":true}"#, exitCode: 1).isUsable)
        guard case .unknown = CLIRuntime.authenticationStatus(stdout: #"{"loggedIn":false}"#, exitCode: 0) else {
            return XCTFail("A contradictory exit status must stay unknown")
        }
    }

    func testCancelledLoginInspectionDoesNotLaunchOrPublishStatus() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CLIRuntime.authenticationStatus(executable: URL(fileURLWithPath: "/must-not-run/claude"))
        }
        do {
            _ = try await task.value
            XCTFail("Canceled inspection must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testAuthenticationStatusIgnoresValidJSONOnStderr() async throws {
        let fixture = try AuthenticationProcessFixture(stderr: #"{"loggedIn":true}"#)
        addTeardownBlock { try fixture.cleanup() }

        let status = try await CLIRuntime.authenticationStatus(executable: fixture.executable)

        XCTAssertTrue(fixture.wasLaunched)
        XCTAssertEqual(status, .unknown(reason: "Claude Code returned an unrecognized login status"))
    }

    func testAuthenticationStatusDoesNotExposeProcessFailureOutput() async throws {
        let fixture = try AuthenticationProcessFixture(
            stdout: AuthenticationProcessFixture.seededSecret,
            stderr: AuthenticationProcessFixture.seededSecret,
            exitCode: 37
        )
        addTeardownBlock { try fixture.cleanup() }

        let status = try await CLIRuntime.authenticationStatus(executable: fixture.executable)

        XCTAssertTrue(fixture.wasLaunched)
        guard case .unknown(let reason) = status else {
            return XCTFail("A failed authentication process must remain unknown")
        }
        XCTAssertEqual(reason, "Claude Code returned an unrecognized login status")
        XCTAssertFalse(reason.contains(AuthenticationProcessFixture.seededSecret))
    }

    func testLaunchFailureDoesNotExposeExecutablePath() async throws {
        let fixture = try AuthenticationProcessFixture()
        addTeardownBlock { try fixture.cleanup() }
        let missing = fixture.executable.appendingPathComponent(AuthenticationProcessFixture.seededSecret)

        let status = try await CLIRuntime.authenticationStatus(executable: missing)

        XCTAssertFalse(fixture.wasLaunched)
        XCTAssertEqual(status, .unknown(reason: "Claude Code could not verify its official login state"))
    }

    func testCancelledAuthenticationStatusAfterLaunchPropagatesCancellation() async throws {
        let fixture = try AuthenticationProcessFixture(waitsForCancellation: true)
        addTeardownBlock { try fixture.cleanup() }
        let executable = fixture.executable
        let task = Task {
            try await CLIRuntime.authenticationStatus(executable: executable)
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

    func testLocatorThrowsWithSearchedPathsWhenMissing() {
        XCTAssertThrowsError(
            try CLIRuntime.locateExecutable(
                environment: ["HOME": "/nonexistent-home-\(UUID().uuidString)"],
                fileManager: .default
            )
        ) { error in
            guard let unavailable = error as? CLIUnavailableError else {
                return XCTFail("expected CLIUnavailableError, got \(error)")
            }
            XCTAssertTrue(unavailable.description.contains("/opt/homebrew/bin/claude"))
        }
    }

    func testRunProcessCapturesStdout() async throws {
        let result = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["perry-was-here"],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "perry-was-here")
    }

    func testCodexProfileUsesDedicatedRuntimeHome() {
        let runtimeHome = URL(fileURLWithPath: "/tmp/perry-codex-home")
        let environment = CLIRuntime.processEnvironment(
            from: ["HOME": "/Users/test", "CODEX_HOME": "/Users/test/.codex"],
            profile: .codex(runtimeHome: runtimeHome)
        )

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["CODEX_HOME"], runtimeHome.path)
    }

    func testProcessEnvironmentDropsUnrelatedSecrets() {
        let environment = CLIRuntime.processEnvironment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "LANG": "en_US.UTF-8",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "OPENAI_API_KEY": "secret",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["SHELL"], "/bin/zsh")
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
    }

    func testRunProcessTerminatesOnTimeout() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.4
            )
            XCTFail("A timed-out process must throw")
        } catch let error as ExecutionError {
            XCTAssertEqual(error.message, "CLI execution exceeded its timeout")
        } catch {
            XCTFail("Expected an execution timeout, got \(error)")
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testNonZeroExitThrowsWithStderr() async {
        let runtime = CLIRuntime(
            executableLocator: { URL(fileURLWithPath: "/usr/bin/false") },
            timeout: 5
        )
        do {
            _ = try await runtime.invoke(["anything"])
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("exited"))
        }
    }
}
