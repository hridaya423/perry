import XCTest
@testable import PerryRuntimes
import PerryCore

final class CLIRuntimeTests: XCTestCase {
    func testParseNumberedStepsExtractsEachLine() {
        let output = """
        1. Open Finder
        2. Select the three files
        3. Press return to rename

        Some trailing prose that is not a step.
        """
        let steps = CLIRuntime.parseNumberedSteps(output, goal: "tidy desktop")
        XCTAssertEqual(steps.map(\.summary), ["Open Finder", "Select the three files", "Press return to rename"])
        XCTAssertEqual(steps.allSatisfy { $0.kind == .delegate }, true)
        XCTAssertEqual(steps.first?.payload["goal"], "Open Finder")
    }

    func testParseFallsBackToSingleDelegateStep() {
        let steps = CLIRuntime.parseNumberedSteps("I would just do the whole thing.", goal: "do it all")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.kind, .delegate)
        XCTAssertEqual(steps.first?.summary, "do it all")
    }

    func testLocatorHonorsOverrideEnvironment() throws {
        let url = try CLIRuntime.locateExecutable(
            environment: ["PERRY_CLAUDE_CODE_PATH": "/bin/echo"],
            fileManager: .default
        )
        XCTAssertEqual(url.path, "/bin/echo")
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

    func testRunProcessTerminatesOnTimeout() async throws {
        let started = Date()
        let result = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.4
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testEndToEndPlanThroughFakeCLI() async throws {
        let runtime = CLIRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            commandRunner: { @Sendable _, _ in
                "1. Click File menu\n2. Choose Rename"
            },
            timeout: 5
        )
        let plan = try await runtime.plan(goal: "rename files", context: ScreenContext(
            frontAppBundleID: "com.apple.finder",
            frontWindowTitle: "Desktop"
        ))
        XCTAssertEqual(plan.runtimeID, "cli.claude-code")
        XCTAssertEqual(plan.steps.map(\.summary), ["Click File menu", "Choose Rename"])
        XCTAssertTrue(plan.steps[1].summary.contains("Rename"))
    }

    func testExecuteRejectsNonDelegateSteps() async {
        let runtime = CLIRuntime(
            executableLocator: { URL(fileURLWithPath: "/bin/echo") },
            timeout: 5
        )
        let step = Step(kind: .clickControl, summary: "click something")
        do {
            _ = try await runtime.execute(step, consent: nil)
            XCTFail("expected ExecutionError")
        } catch {
            XCTAssertTrue("\(error)".contains("delegates whole tasks"))
        }
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
