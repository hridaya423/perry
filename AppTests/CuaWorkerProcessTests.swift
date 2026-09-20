import Darwin
import Foundation
import XCTest
@testable import Perry

final class CuaWorkerProcessTests: XCTestCase {
    private func makeFixture(sharedTarget: Bool = false) throws -> (CuaWorkerService, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-workers-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("driver")
        let script = #"""
        #!/bin/sh
        set -eu
        root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        printf '%s\n' "$$" > "$root/pid-$$"
        bundle="fixture.$$"
        if [ -f "$root/shared-target" ]; then bundle="fixture.shared"; fi
        trap '' TERM
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$root/requests-$$"
            id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
            [ -n "$id" ] || continue
            case "$line" in
                *list_windows*) printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"windows":[{"bundle_id":"%s","pid":%s,"window_id":1,"title":"Fixture","bounds":{"x":0,"y":0,"width":800,"height":600}}]}}}\n' "$id" "$bundle" "$$" ;;
                *get_window_state*) printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"snapshot_id":"s1","elements":[{"element_token":"save","role":"AXButton","label":"Save","frame":{"x":20,"y":20,"width":80,"height":24}}]},"content":[{"type":"image","data":"AQI=","mimeType":"image/png"}]}}\n' "$id" ;;
                *) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
            esac
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        if sharedTarget { try Data().write(to: directory.appendingPathComponent("shared-target")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let service = CuaWorkerService(configuration: CuaDriverConfiguration(
            executableURL: executable,
            capabilityManifestURL: directory.appendingPathComponent("capabilities.yaml"),
            hostBundleID: "dev.perry.PerryTests"
        ))
        addTeardownBlock {
            try await service.shutdown()
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("pid-") {
                let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                let pid = try XCTUnwrap(pid_t(value))
                guard pid > 1, pid != getpid() else { throw CuaDriverError.terminationUnconfirmed }
                guard kill(pid, 0) == -1, errno == ESRCH else {
                    throw CuaDriverError.terminationUnconfirmed
                }
            }
            try FileManager.default.removeItem(at: directory)
        }
        return (service, directory)
    }

    func testGuideReaderCannotCaptureAfterItsWorkerScopeEnds() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let targetStore = CuaGuideTargetStore()
        let reader = try await service.withWorker(scope: .guide, resources: []) { worker in
            let reader = CuaGuideTreeReader(worker: worker, targetStore: targetStore)
            let snapshot = try await reader.observe().snapshot
            XCTAssertEqual(snapshot.appBundleID, "fixture.shared")
            XCTAssertEqual(snapshot.windowTitle, "Fixture")
            XCTAssertEqual(snapshot.elements.count, 1)
            XCTAssertEqual(snapshot.elements.first?.stableID, "save")
            XCTAssertEqual(snapshot.elements.first?.label, "Save")
            return reader
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let requestFile = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("requests-") })
        let requests = try Data(contentsOf: requestFile)
        do {
            _ = try await reader.observe()
            XCTFail("A guide reader outlived its worker scope")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .retired)
        }
        XCTAssertEqual(try Data(contentsOf: requestFile), requests)
        let remainingFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(remainingFiles.filter { $0.lastPathComponent.hasPrefix("pid-") }.count, 1)
    }

    func testThreeWorkerProcessesHaveIndependentRetirement() async throws {
        let (service, directory) = try makeFixture()
        let captures = WorkerCaptures()
        let ready = expectation(description: "three workers captured")
        ready.expectedFulfillmentCount = 3
        let stopped = expectation(description: "three scopes completed")
        stopped.expectedFulfillmentCount = 3
        let tasks = (0..<3).map { index in
            Task {
                defer { stopped.fulfill() }
                try await service.withWorker(scope: .background, resources: []) { worker in
                    let capture = try await worker.capture(target: nil)
                    await captures.insert(index, worker: worker, pid: capture.target.processID)
                    ready.fulfill()
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }
        addTeardownBlock {
            for task in tasks { task.cancel() }
        }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            return XCTFail("Worker setup did not finish")
        }
        let all = await captures.values
        XCTAssertEqual(Set(all.values.map(\.pid)).count, 3)
        do {
            try await service.withWorker(scope: .background, resources: []) { _ in
                XCTFail("Fourth worker operation was invoked")
            }
            XCTFail("Fourth worker was admitted")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .capacityReached)
        }
        let first = try XCTUnwrap(all[0])
        let retired = expectation(description: "first worker retired")
        let retirement = Task {
            defer { retired.fulfill() }
            try await first.worker.retire()
        }
        guard await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed else {
            retirement.cancel()
            return XCTFail("Retirement exceeded its deadline")
        }
        try await retirement.value
        XCTAssertEqual(kill(first.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        for index in [1, 2] {
            let active = try XCTUnwrap(all[index])
            let capture = try await active.worker.capture(target: nil)
            XCTAssertEqual(capture.target.processID, active.pid)
            XCTAssertEqual(kill(active.pid, 0), 0)
        }
        for task in tasks { task.cancel() }
        guard await XCTWaiter.fulfillment(of: [stopped], timeout: 2) == .completed else {
            return XCTFail("Worker scopes did not acknowledge cancellation")
        }
        for record in all.values {
            XCTAssertEqual(kill(record.pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
        try FileManager.default.removeItem(at: directory)
    }

    func testResourceConflictBlocksPixelsAndTextBeforeDispatch() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let entered = expectation(description: "first worker captured")
        let stopped = expectation(description: "first worker stopped")
        let captures = WorkerCaptures()
        let first = Task {
            defer { stopped.fulfill() }
            try await service.withWorker(scope: .background, resources: []) { worker in
                let capture = try await worker.capture(target: nil)
                await captures.insert(0, worker: worker, pid: capture.target.processID)
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
        }
        addTeardownBlock { first.cancel() }
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else {
            return XCTFail("First worker did not capture")
        }
        for insert in [false, true] {
            do {
                try await service.withWorker(scope: .dictation, resources: []) { worker in
                    if insert {
                        _ = try await worker.insertText("must not be sent", target: CuaTargetHint(bundleID: "fixture.shared"))
                    } else {
                        _ = try await worker.capture(target: CuaTargetHint(bundleID: "fixture.shared"))
                    }
                }
                XCTFail("Conflicting application was accepted")
            } catch let error as CuaWorkerError {
                XCTAssertEqual(error, .resourceBusy)
            }
        }
        let active = await captures.values
        let firstPID = try XCTUnwrap(active[0]?.pid)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let rejectedLogs = files.filter {
            $0.lastPathComponent.hasPrefix("requests-") && $0.lastPathComponent != "requests-\(firstPID)"
        }
        XCTAssertEqual(rejectedLogs.count, 2)
        for file in rejectedLogs {
            let requests = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(requests.contains("list_windows"))
            XCTAssertFalse(requests.contains("get_window_state"))
            XCTAssertFalse(requests.contains("type_text"))
        }
        first.cancel()
        let stoppedResult = await XCTWaiter.fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(stoppedResult, .completed)
    }
}

private actor WorkerCaptures {
    struct Capture: Sendable {
        let worker: CuaWorkerHandle
        let pid: pid_t
    }
    var values: [Int: Capture] = [:]

    func insert(_ index: Int, worker: CuaWorkerHandle, pid: pid_t) {
        values[index] = Capture(worker: worker, pid: pid)
    }
}
