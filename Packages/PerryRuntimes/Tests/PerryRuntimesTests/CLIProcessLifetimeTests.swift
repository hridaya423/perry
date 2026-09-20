import XCTest
import Darwin
@testable import PerryRuntimes

final class CLIProcessLifetimeTests: XCTestCase {
    func testNaturalCompletionObservedAfterDeadlineCannotReturnSuccess() async {
        do {
            _ = try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["0.003"], timeout: 0.001
            )
            XCTFail("Completion observed after the deadline must not be accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("timeout"))
        }
    }

    func testTimeoutCannotBecomeSuccessWhenTerminationHandlerExitsZero() async {
        do {
            let result = try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap 'exit 0' TERM; while :; do /bin/sleep 1; done"],
                timeout: 0.2
            )
            XCTFail("A timed-out command returned exit code \(result.exitCode)")
        } catch {
            XCTAssertTrue(String(describing: error).contains("timeout"))
        }
    }

    func testPreCanceledProcessDoesNotAttemptLaunch() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/must-not-launch/missing-runtime"),
                arguments: [], timeout: 1
            )
        }
        do {
            _ = try await task.value
            XCTFail("A canceled process request must not launch")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation before launch, got \(error)")
        }
    }

    func testInheritedOutputDescriptorCannotOutliveTheDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/bin/sleep 2 & printf parent-finished; exit 0"],
                timeout: 0.1
            )
            XCTFail("Unclosed output cannot be accepted as a complete result")
        } catch {
            XCTAssertTrue(String(describing: error).contains("output"))
        }
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(800))
    }

    func testBothStreamsPreserveTrailingBytes() async throws {
        let result = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero; printf stdout-tail; /usr/bin/head -c 262144 /dev/zero >&2; printf stderr-tail >&2"],
            timeout: 3
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 262144 + "stdout-tail".utf8.count)
        XCTAssertEqual(result.stderr.utf8.count, 262144 + "stderr-tail".utf8.count)
        XCTAssertTrue(result.stdout.hasSuffix("stdout-tail"))
        XCTAssertTrue(result.stderr.hasSuffix("stderr-tail"))
    }

    func testOutputOverflowOnEitherStreamFailsInsteadOfReturningPartialOutput() async {
        for redirect in ["", " >&2"] {
            do {
                _ = try await CLIRuntime.runProcess(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "/usr/bin/head -c 16384 /dev/zero\(redirect)"],
                    timeout: 1, maximumOutputBytes: 4096
                )
                XCTFail("Oversized output must fail")
            } catch {
                XCTAssertTrue(String(describing: error).contains("output exceeded its byte limit"))
            }
        }
    }

    func testOutputExactlyAtTheLimitIsCompleteOnBothStreams() async throws {
        let result = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 4096 /dev/zero; /usr/bin/head -c 4096 /dev/zero >&2"],
            timeout: 1, maximumOutputBytes: 4096
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 4096)
        XCTAssertEqual(result.stderr.utf8.count, 4096)
    }

    func testInvalidUTF8FailsInsteadOfBecomingEmptyOutput() async {
        do {
            _ = try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '\\377'"], timeout: 1
            )
            XCTFail("Invalid UTF-8 must not be silently replaced by an empty result")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not valid UTF-8"))
        }
    }

    func testCancellationTerminatesAndReapsTheLaunchedWorkerWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let task = Task {
            try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' $$ > \"$1.tmp\"; /bin/mv \"$1.tmp\" \"$1\"; exec /bin/sleep 30", "fixture", marker.path],
                timeout: 5
            )
        }
        addTeardownBlock {
            task.cancel()
            do { _ = try await task.value }
            catch is CancellationError {}
            catch { XCTFail("Worker cleanup failed: \(error)") }
        }
        let clock = ContinuousClock()
        let launchDeadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: marker.path), clock.now < launchDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        let canceled = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled worker must not return output")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertLessThan(canceled.duration(to: clock.now), .milliseconds(500))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testFoundationLaunchCreatesADedicatedProcessGroup() async throws {
        let result = try await CLIRuntime.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' $$; /bin/ps -o pgid= -p $$"],
            timeout: 1
        )
        let identifiers = result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(identifiers.first, identifiers.last)
        XCTAssertNotEqual(identifiers.last, getpgrp())
    }

    func testCancellationAlsoStopsTheWorkerDescendant() async throws {
        try await assertDescendantStops(ignoringTermination: false)
    }

    func testCancellationEscalatesWhenTheWorkerDescendantIgnoresTermination() async throws {
        try await assertDescendantStops(ignoringTermination: true)
    }

    private func assertDescendantStops(ignoringTermination: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pids")
        let trap = ignoringTermination ? #"trap "" TERM; "# : ""
        let script = #"/bin/sh -c '\#(trap)printf "%s %s" "$PPID" "$$" > "$1.tmp"; /bin/mv "$1.tmp" "$1"; exec /bin/sleep 30' fixture "$1" & wait"#
        let task = Task {
            try await CLIRuntime.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "fixture", marker.path],
                timeout: 5
            )
        }
        addTeardownBlock {
            task.cancel()
            do { _ = try await task.value }
            catch is CancellationError {}
            catch { XCTFail("Worker cleanup failed: \(error)") }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let identifiers = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: " ").compactMap { Int32($0) }
        XCTAssertEqual(identifiers.count, 2)
        let parent = try XCTUnwrap(identifiers.first)
        let child = try XCTUnwrap(identifiers.last)
        XCTAssertEqual(getpgid(child), parent)
        defer {
            if getpgid(child) == parent {
                let status = kill(child, SIGKILL)
                XCTAssertTrue(status == 0 || errno == ESRCH)
            }
        }
        let canceled = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
        }
        let reapDeadline = canceled.advanced(by: .milliseconds(500))
        while kill(child, 0) == 0, clock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThan(canceled.duration(to: clock.now), .milliseconds(500))
    }

    func testTerminationSignalFailureStillAttemptsForcedCleanup() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        XCTAssertEqual(getpgid(pid), pid)
        defer {
            if process.isRunning {
                XCTAssertEqual(kill(pid, SIGKILL), 0)
                process.waitUntilExit()
            }
        }
        var signals: [Int32] = []
        try CLIRuntime.stopProcess(process, group: pid) { target, signal in
            signals.append(signal)
            if signal == SIGTERM {
                errno = EPERM
                return -1
            }
            return kill(target, signal)
        }
        XCTAssertTrue(signals.contains(SIGTERM))
        XCTAssertTrue(signals.contains(SIGKILL))
        XCTAssertFalse(process.isRunning)
    }
}
