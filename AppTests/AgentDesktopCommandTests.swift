import Darwin
import Foundation
import XCTest
import PerryBrain
@testable import Perry

final class AgentDesktopCommandTests: XCTestCase {
    private let script = #"""
    #!/bin/sh
    root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    : > "$root/launched"
    case "$1" in
    big) head -c 3000000 /dev/zero | base64 | tr -d '\n' > "$root/big.b64"; printf '{"ok":true,"data":{"data":"'; cat "$root/big.b64"; printf '"}}\n' ;;
    orphan) (sleep 3 &) ; printf '{"ok":true,"data":{"v":1}}\n' ;;
    hang) printf '%s\n' "$$" > "$root/pid"; exec sleep 30 ;;
    die) kill -9 $$ ;;
    argv) printf '{"ok":true,"data":{"argv":"%s"}}\n' "$*" ;;
    esac
    """#

    private var directory: URL!
    private var command: AgentDesktopCommand!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-agent-desktop-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("agent-desktop")
        try script.trimmingCharacters(in: .whitespacesAndNewlines).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        command = AgentDesktopCommand(executableURL: executable, environment: [:])
    }

    override func tearDownWithError() throws {
        if let pid = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
           let value = pid_t(pid.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 {
            kill(value, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func hungPID() async throws -> pid_t {
        let file = directory.appendingPathComponent("pid")
        for _ in 0..<200 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil as pid_t?, "the fake command never started")
    }

    private func exits(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testEnvelopeErrorsMapToDriverErrors() throws {
        let cases: [(String, ScreenDriverError)] = [
            ("PERM_DENIED", .unavailable),
            ("STALE_REF", .staleTarget),
            ("SNAPSHOT_NOT_FOUND", .staleTarget),
            ("ELEMENT_NOT_FOUND", .staleTarget),
            ("WINDOW_NOT_FOUND", .targetNotFound),
            ("AMBIGUOUS_TARGET", .noTargetWindow),
            ("POLICY_DENIED", .unsupportedAction),
            ("APP_UNRESPONSIVE", .actionUnanswered),
            ("TIMEOUT", .requestTimedOut),
            ("ACTION_FAILED", .toolRejected("press failed")),
        ]
        for (code, expected) in cases {
            let envelope = #"{"version":"2.5","ok":false,"command":"click","error":{"code":"\#(code)","message":"press failed"}}"#
            XCTAssertThrowsError(try AgentDesktopCommand.decode(Data(envelope.utf8)), code) { error in
                XCTAssertEqual((error as? AgentDesktopFailure)?.error, expected, code)
            }
        }
        let deliveries: [(String, String?, Bool)] = [
            ("POLICY_DENIED", nil, false),
            ("STALE_REF", nil, false),
            ("ACTION_FAILED", nil, true),
            ("APP_UNRESPONSIVE", nil, true),
            ("STALE_REF", "delivered_unverified", true),
            ("ACTION_FAILED", "not_delivered", false),
            ("TIMEOUT", "not_delivered", false),
        ]
        for (code, delivery, mayHaveLanded) in deliveries {
            let disposition = delivery.map { #","disposition":{"delivery":"\#($0)"}"# } ?? ""
            let envelope = #"{"version":"2.5","ok":false,"command":"click","error":{"code":"\#(code)","message":"m"\#(disposition)}}"#
            XCTAssertThrowsError(try AgentDesktopCommand.decode(Data(envelope.utf8))) { error in
                XCTAssertEqual((error as? AgentDesktopFailure)?.mayHaveLanded, mayHaveLanded, "\(code) \(delivery ?? "none")")
            }
        }
        XCTAssertThrowsError(try AgentDesktopCommand.decode(Data())) { error in
            XCTAssertEqual(error as? AgentDesktopFailure, AgentDesktopFailure(error: .processExited, mayHaveLanded: true))
        }
        let notDeliveredTimeout = #"{"version":"2.5","ok":false,"command":"click","error":{"code":"TIMEOUT","message":"m","disposition":{"delivery":"not_delivered"}}}"#
        XCTAssertThrowsError(try AgentDesktopCommand.decode(Data(notDeliveredTimeout.utf8))) { error in
            XCTAssertEqual(
                (error as? AgentDesktopFailure)?.error,
                .appBusy,
                "a budget timeout before delivery must not restart screen control or be retried another way"
            )
        }
        let data = try AgentDesktopCommand.decode(Data(#"{"version":"2.5","ok":true,"command":"get","data":{"value":"x"}}"#.utf8))
        XCTAssertEqual(data["value"]?.stringValue, "x")
    }

    func testOutputLargerThanThePipeBufferIsReadWhole() async throws {
        let data = try await command.run(["big"], session: "s", timeout: .seconds(10))
        XCTAssertEqual(data["data"]?.stringValue?.count, 4_000_000)
    }

    func testAChildHoldingThePipeOpenDoesNotHoldTheCall() async throws {
        let start = ContinuousClock.now
        let data = try await command.run(["orphan"], session: "s", timeout: .seconds(5))
        XCTAssertEqual(data["v"]?.doubleValue, 1)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testATimedOutCommandIsKilledAndMayHaveLanded() async throws {
        do {
            _ = try await command.run(["hang"], session: "s", timeout: .seconds(1))
            XCTFail("a hung command must time out")
        } catch let failure as AgentDesktopFailure {
            XCTAssertEqual(failure, AgentDesktopFailure(error: .requestTimedOut, mayHaveLanded: true))
        }
        let pid = try await hungPID()
        let exited = await exits(pid)
        XCTAssertTrue(exited, "the timed-out command is still running")
    }

    func testCancellingTheCallerStopsTheCommand() async throws {
        let call = Task { try await command.run(["hang"], session: "s", timeout: .seconds(20)) }
        let pid = try await hungPID()
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("a cancelled command must not return")
        } catch is CancellationError {
        }
        let exited = await exits(pid)
        XCTAssertTrue(exited, "the cancelled command is still running")
    }

    func testAProcessThatDiesWithoutAnswerMayHaveLanded() async throws {
        do {
            _ = try await command.run(["die"], session: "s", timeout: .seconds(2))
            XCTFail("a dead process has no answer")
        } catch let failure as AgentDesktopFailure {
            XCTAssertEqual(failure, AgentDesktopFailure(error: .processExited, mayHaveLanded: true))
        }
    }

    func testTextGoesAfterTheSessionAndADoubleDash() async throws {
        let data = try await command.run(["argv", "@s1:e1"], payload: "--headed", session: "worker", timeout: .seconds(2))
        XCTAssertEqual(data["argv"]?.stringValue, "argv @s1:e1 --session worker -- --headed")
    }

    func testTextTooLongForTheCommandLineIsRefusedBeforeLaunch() async throws {
        let text = String(repeating: "a", count: AgentDesktopCommand.payloadLimit + 1)
        do {
            _ = try await command.run(["argv"], payload: text, session: "s", timeout: .seconds(2))
            XCTFail("oversized text must be refused")
        } catch let failure as AgentDesktopFailure {
            XCTAssertEqual(failure, AgentDesktopCommand.payloadTooLong)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("launched").path))
    }

    func testAMissingExecutableIsUnavailableAndNothingHappened() async throws {
        let missing = AgentDesktopCommand(executableURL: directory.appendingPathComponent("absent"), environment: [:])
        do {
            _ = try await missing.run(["argv"], session: "s", timeout: .seconds(2))
            XCTFail("a missing executable cannot run")
        } catch let failure as AgentDesktopFailure {
            XCTAssertEqual(failure, AgentDesktopFailure(error: .unavailable, mayHaveLanded: false))
        }
    }
}
