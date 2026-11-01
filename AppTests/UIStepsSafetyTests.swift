import Foundation
import XCTest
import PerryBrain
import PerryRuntimes
@testable import Perry

final class UIStepsSafetyTests: XCTestCase {
    private func makeFixture() throws -> (ScreenWorkerService, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-steps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("agent-desktop")
        let script = #"""
        #!/bin/sh
        set -eu
        root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        printf '%s\n' "$$" > "$root/pid-$$"
        command="$1"
        session=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "--session" ]; then session="$argument"; fi
            previous="$argument"
        done
        apppid=$(( $(printf '%s' "$session" | cksum | cut -d' ' -f1) % 50000 + 10000 ))
        log="$root/requests-$apppid"
        if [ "$command" = "permissions" ]; then log="$root/health.log"; fi
        IFS=$(printf '\t')
        printf '%s\n' "$*" >> "$log"
        unset IFS
        ok() { printf '{"version":"2.5","ok":true,"command":"%s","data":%s}\n' "$command" "$1"; }
        case "$command" in
            list-windows) ok "[{\"id\":\"w-1\",\"title\":\"Fixture\",\"app_name\":\"Fixture\",\"pid\":$apppid,\"is_focused\":true,\"bounds\":{\"x\":0,\"y\":0,\"width\":800,\"height\":600}}]" ;;
            snapshot) ok '{"snapshot_id":"s1","complete":true,"tree":{"role":"window","name":"Fixture","children":[{"ref_id":"@s1:e1","role":"button","name":"Save","available_actions":["Click"],"bounds":{"x":20,"y":20,"width":80,"height":24}}]}}' ;;
            screenshot) ok '{"format":"png","width":800,"height":600,"scale_factor":1,"data":"AQI="}' ;;
            press) sleep 1; ok '{}' ;;
            *) ok '{}' ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("shared-target"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let shared = directory.appendingPathComponent("shared-target").path
        let service = ScreenWorkerService(configuration: AgentDesktopConfiguration(
            executableURL: executable,
            hostBundleID: "dev.perry.PerryTests",
            stateDirectoryURL: directory.appendingPathComponent("state", isDirectory: true),
            bundleIdentifier: { pid in FileManager.default.fileExists(atPath: shared) ? "fixture.shared" : "fixture.\(pid)" }
        ))
        addTeardownBlock {
            try await service.shutdown()
            try TestTempDirectory.remove(directory)
        }
        return (service, directory)
    }

    private func pressCount(in directory: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.lastPathComponent.hasPrefix("requests-") }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
            .split(separator: "\n")
            .filter { $0.hasPrefix("press\t") }
            .count
    }

    private func steps(_ count: Int) -> JSONValue {
        .object(["steps": .array((0..<count).map { _ in .object(["action": .string("key"), "key": .string("Return")]) })])
    }

    func testStoppingMidBatchRunsNoFurtherSteps() async throws {
        let (service, directory) = try makeFixture()
        let observations = AgentObservationStore()
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: lease, observations: observations).executors
            + UITools(workers: service, lease: lease, observations: observations).executors
        )
        let context = ToolContext(surface: .agent, runID: UUID())
        do {
            try await service.withWorker(scope: .foreground, resources: []) { worker in
                lease.set(worker, for: context.runID)
                defer { lease.set(nil, for: context.runID) }
                _ = await host.handle(ToolCall(id: "observe", name: "screen.observe", arguments: .object(["bundleID": .string("fixture.shared")])), context: context)
                let batch = Task { await host.handle(ToolCall(id: "steps", name: "ui.steps", arguments: self.steps(3)), context: context) }
                var attempts = 0
                while try self.pressCount(in: directory) == 0, attempts < 300 {
                    attempts += 1
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(try self.pressCount(in: directory), 1)
                batch.cancel()
                let result = await batch.value
                XCTAssertTrue(result.isError, "\(result)")
            }
        } catch is CancellationError {
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try pressCount(in: directory), 1)
    }

    func testPointerStepsStopWhenTheTargetAppIsNotInFront() async throws {
        let (service, directory) = try makeFixture()
        let observations = AgentObservationStore()
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: lease, observations: observations).executors
            + UITools(workers: service, lease: lease, observations: observations, onActuation: { _, _ in }).executors
        )
        let context = ToolContext(surface: .agent, runID: UUID())
        try await service.withWorker(scope: .foreground, resources: []) { worker in
            lease.set(worker, for: context.runID)
            defer { lease.set(nil, for: context.runID) }
            _ = await host.handle(ToolCall(id: "observe", name: "screen.observe", arguments: .object(["bundleID": .string("fixture.shared")])), context: context)
            let result = await host.handle(ToolCall(id: "steps", name: "ui.steps", arguments: self.steps(2)), context: context)
            XCTAssertTrue(result.isError)
            XCTAssertTrue("\(result)".contains("The app I was using is no longer in front, so I stopped."), "\(result)")
        }
        XCTAssertEqual(try pressCount(in: directory), 0)
    }
}
