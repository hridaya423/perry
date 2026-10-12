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
}
