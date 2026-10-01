import Darwin
import Foundation
import XCTest
import PerryBrain
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
            try TestTempDirectory.remove(directory)
        }
        return (service, directory)
    }

    func testUnrelatedToolRunCannotBorrowForegroundWorker() async throws {
        let (service, _) = try makeFixture()
        let lease = ForegroundWorkerLease()
        try await service.withWorker(scope: .foreground, resources: []) { foreground in
            let runID = UUID()
            lease.set(foreground, for: runID)
            defer { lease.set(nil, for: runID) }
            let original = try await foreground.capture(target: nil)
            let owned = try await withCuaWorker(service, lease: lease, runID: runID, resources: []) { worker in
                try await worker.capture(target: nil)
            }
            XCTAssertEqual(owned.target.processID, original.target.processID)
            let unrelated = try await withCuaWorker(service, lease: lease, runID: UUID(), resources: []) { worker in
                try await worker.capture(target: nil)
            }
            XCTAssertNotEqual(unrelated.target.processID, original.target.processID)
        }
    }

    func testAnotherRunCannotBypassApplicationLockThroughForegroundLease() async throws {
        let (service, _) = try makeFixture(sharedTarget: true)
        let lease = ForegroundWorkerLease()
        try await service.withWorker(scope: .foreground, resources: [.application("fixture.shared")]) { foreground in
            let runID = UUID()
            lease.set(foreground, for: runID)
            defer { lease.set(nil, for: runID) }
            do {
                _ = try await withCuaWorker(
                    service, lease: lease, runID: UUID(), resources: [.application("fixture.shared")]
                ) { worker in
                    try await worker.capture(target: nil)
                }
                XCTFail("An unrelated run bypassed the application's resource lock")
            } catch let error as CuaWorkerError {
                XCTAssertEqual(error, .resourceBusy)
            }
        }
    }

    func testScreenObservationReturnsPixelsAndIndexFromTheSameCapture() async throws {
        let (service, _) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let host = PerryToolHost(executors: ScreenTools(workers: service, lease: nil, observations: observations).executors)
        let context = ToolContext(surface: .agent, threadID: "screen-test")
        let result = await host.handle(
            ToolCall(id: "capture", name: "screen.observe", arguments: .object(["bundleID": .string("fixture.shared")])),
            context: context
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.callID, "capture")
        XCTAssertTrue(result.content.contains(.image(data: Data([1, 2]), mimeType: "image/png")))
        guard case .text(let text)? = result.content.first else { return XCTFail("Missing observation index") }
        let summary = try JSONValue(parsing: Data(text.utf8))
        XCTAssertEqual(summary["app"], .string("fixture.shared"))
        XCTAssertEqual(summary["elements"]?.arrayValue?.first?["label"], .string("Save"))
        XCTAssertEqual(observations.snapshot(runID: context.runID)?.screenshotData, Data([1, 2]))
        XCTAssertNil(observations.snapshot(runID: UUID()))
    }

    func testNewRunCannotResolvePreviousRunsElementsInTheSameConversation() async throws {
        let (service, _) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: nil, observations: observations).executors
            + UITools(workers: service, lease: nil, observations: observations).executors
        )
        let observed = await host.handle(
            ToolCall(id: "observe", name: "screen.observe", arguments: .object(["bundleID": .string("fixture.shared")])),
            context: ToolContext(surface: .agent, threadID: "same-conversation")
        )
        guard case .text(let text)? = observed.content.first else { return XCTFail("Missing observation") }
        let summary = try JSONValue(parsing: Data(text.utf8))
        let elementID = try XCTUnwrap(summary["elements"]?.arrayValue?.first?["id"]?.stringValue)
        let result = await host.handle(
            ToolCall(id: "click", name: "ui.click", arguments: .object(["elementID": .string(elementID)])),
            context: ToolContext(surface: .agent, threadID: "same-conversation")
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains { part in
            if case .text(let message) = part { return message.contains("stale or unknown") }
            return false
        })
    }

    func testMCPConnectionsKeepIndependentObservationScopes() async throws {
        let (service, _) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: nil, observations: observations).executors
            + UITools(workers: service, lease: nil, observations: observations).executors
        )
        let first = AppMCPBridge(host: host)
        let second = AppMCPBridge(host: host)
        let capture = try await first.call(name: "screen.observe", arguments: .object(["bundleID": .string("fixture.shared")]))
        XCTAssertFalse(capture.isError)
        let snapshot = try XCTUnwrap(observations.snapshot(runID: first.runID))
        let element = try XCTUnwrap(snapshot.index.entries.first)
        XCTAssertNil(observations.snapshot(runID: second.runID))
        let result = try await second.call(name: "ui.click", arguments: .object(["elementID": .string(element.compactID)]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains { part in
            if case .text(let message) = part { return message.contains("stale or unknown") }
            return false
        })
    }

    @MainActor
    func testAgentRunKeepsObservationWorkerThroughActionAndRetiresIt() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: lease, observations: observations).executors
            + UITools(workers: service, lease: lease, observations: observations).executors
        )
        let coordinator = AgentCoordinator(
            provider: { _ in ObserveThenClickProvider(explicitTarget: false) }, host: host,
            threads: ThreadStore(directory: directory.appendingPathComponent("threads")),
            consent: ToolConsentStore(directory: nil), observations: observations,
            workers: service, workerLease: lease
        )
        var results: [ToolResult] = []
        for await event in coordinator.run(threadID: UUID(), goal: "Click the fixture Save button", target: CuaTargetHint(bundleID: "fixture.shared", windowID: 1)) {
            if case .toolCallFinished(let result) = event { results.append(result) }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.isError }, "\(results)")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let logs = files.filter { $0.lastPathComponent.hasPrefix("requests-") }
        XCTAssertEqual(logs.count, 1)
        let requests = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(requests.contains("\"name\":\"click\""))
        for file in files where file.lastPathComponent.hasPrefix("pid-") {
            let pid = try XCTUnwrap(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    @MainActor
    func testStopRetiresRunWorkerAndPreservesDeliveredTextWithoutClicking() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: lease, observations: observations).executors
            + UITools(workers: service, lease: lease, observations: observations).executors
        )
        let threads = ThreadStore(directory: directory.appendingPathComponent("threads"))
        let coordinator = AgentCoordinator(
            provider: { _ in ObserveThenClickProvider(pauseBeforeClick: true) }, host: host,
            threads: threads, consent: ToolConsentStore(directory: nil), observations: observations,
            workers: service, workerLease: lease
        )
        let threadID = UUID()
        let runID = UUID()
        let delivered = expectation(description: "Observation text delivered")
        let stream = coordinator.run(threadID: threadID, goal: "Observe, then wait", runID: runID)
        let completion = Task { @MainActor in
            var terminal: AgentFinish?
            for await event in stream {
                if case .textDelta = event { delivered.fulfill() }
                if case .finished(let finish) = event { terminal = finish }
            }
            return terminal
        }
        await fulfillment(of: [delivered], timeout: 5)
        coordinator.stop(threadID: threadID)
        let finish = await completion.value
        XCTAssertEqual(finish, .interrupted)
        let saved = await threads.thread(id: threadID)
        XCTAssertEqual(saved?.turns.last?.answer, "Observed.")
        XCTAssertEqual(saved?.turns.last?.outcome, .interrupted)
        XCTAssertNil(lease.worker(for: runID))
        XCTAssertNil(observations.snapshot(runID: runID))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let requests = try files.filter { $0.lastPathComponent.hasPrefix("requests-") }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(requests.contains("\"name\":\"click\""))
        for file in files where file.lastPathComponent.hasPrefix("pid-") {
            let pid = try XCTUnwrap(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testMCPSocketObservesClicksAndRetiresWorkerOnStop() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/perry-mcp-\(UUID())")
        let observations = AgentObservationStore()
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors:
            ScreenTools(workers: service, lease: lease, observations: observations).executors
            + UITools(workers: service, lease: lease, observations: observations).executors
        )
        let server = PerryMCPSocket(host: host, directory: socketDirectory, workers: service, workerLease: lease, observations: observations)
        try server.start()
        addTeardownBlock {
            await server.stop()
            try TestTempDirectory.remove(socketDirectory)
        }
        let client = try MCPFixtureClient(directory: socketDirectory)
        defer { client.close() }
        let observed = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screen.observe","arguments":{"bundleID":"fixture.shared"}}}"#)
        XCTAssertEqual(observed["result"]?["isError"], .bool(false))
        let content = try XCTUnwrap(observed["result"]?["content"]?.arrayValue)
        XCTAssertEqual(content.last?["data"], .string("AQI="))
        let summary = try JSONValue(parsing: Data(try XCTUnwrap(content.first?["text"]?.stringValue).utf8))
        let elementID = try XCTUnwrap(summary["elements"]?.arrayValue?.first?["id"]?.stringValue)
        let clicked = try client.request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ui.click\",\"arguments\":{\"elementID\":\"\(elementID)\"}}}")
        XCTAssertEqual(clicked["result"]?["isError"], .bool(false))
        await server.stop()
        XCTAssertTrue(client.isClosedByServer())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let pids = files.filter { $0.lastPathComponent.hasPrefix("pid-") }
        XCTAssertEqual(pids.count, 1)
        for file in pids {
            let pid = try XCTUnwrap(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testMCPDisconnectAndServerStopCancelPendingWorkAndDropQueuedEffects() async throws {
        for disconnect in [true, false] {
            let (service, directory) = try makeFixture(sharedTarget: true)
            let socketDirectory = URL(fileURLWithPath: "/tmp/perry-mcp-\(UUID())")
            let entered = expectation(description: "Tool started")
            let cancelled = expectation(description: "Tool cancelled")
            let waiting = MCPWaitingExecutor(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
            let observations = AgentObservationStore()
            let lease = ForegroundWorkerLease()
            let host = PerryToolHost(executors:
                ScreenTools(workers: service, lease: lease, observations: observations).executors + [waiting]
            )
            let server = PerryMCPSocket(host: host, directory: socketDirectory, workers: service, workerLease: lease, observations: observations)
            try server.start()
            addTeardownBlock {
                await server.stop()
                try TestTempDirectory.remove(socketDirectory)
            }
            let client = try MCPFixtureClient(directory: socketDirectory)
            defer { client.close() }
            _ = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screen.observe","arguments":{"bundleID":"fixture.shared"}}}"#)
            try client.sendLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fixture.wait"}}"#)
            await fulfillment(of: [entered], timeout: 5)
            try client.sendLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fixture.wait","arguments":{"effect":true}}}"#)
            if disconnect { client.close() }
            else {
                server.closeAdmission()
                XCTAssertThrowsError(try server.start())
                try await service.shutdown()
            }
            await fulfillment(of: [cancelled], timeout: 5)
            await server.stop()
            XCTAssertEqual(waiting.effects, 0)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("pid-") {
                let pid = try XCTUnwrap(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                XCTAssertEqual(kill(pid, 0), -1)
                XCTAssertEqual(errno, ESRCH)
            }
        }
    }

    func testMCPSocketPreservesLargeImageResponsesAndRejectsInvalidAuthenticationAfterRestart() async throws {
        let (service, _) = try makeFixture()
        let socketDirectory = URL(fileURLWithPath: "/tmp/perry-mcp-\(UUID())")
        let payload = Data(repeating: 0xAB, count: 524_288)
        let server = PerryMCPSocket(
            host: PerryToolHost(executors: [MCPImageExecutor(payload: payload)]), directory: socketDirectory,
            workers: service, workerLease: ForegroundWorkerLease()
        )
        try server.start()
        addTeardownBlock {
            await server.stop()
            try TestTempDirectory.remove(socketDirectory)
        }
        let client = try MCPFixtureClient(directory: socketDirectory)
        defer { client.close() }
        let response = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fixture.image"}}"#)
        let encoded = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["data"]?.stringValue)
        XCTAssertEqual(Data(base64Encoded: encoded), payload)
        await server.stop()
        try server.start()
        let unauthorized = try MCPFixtureClient(directory: socketDirectory, token: "invalid-token")
        defer { unauthorized.close() }
        XCTAssertTrue(unauthorized.isClosedByServer())
        await server.stop()
    }

    func testObservationWithoutCapturedOrExplicitTargetDoesNotChooseAnotherWindow() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let host = PerryToolHost(executors: ScreenTools(workers: service, lease: nil, observations: AgentObservationStore()).executors)
        let result = await host.handle(
            ToolCall(id: "unscoped", name: "screen.observe", arguments: .object([:])),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("requests-") })
    }

    func testFailedRetargetDiscardsPriorElementIndexAndDoesNotReturnToOldWindow() async throws {
        let (service, _) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let context = ToolContext(surface: .agent)
        observations.setTarget(CuaTargetHint(bundleID: "fixture.shared", windowID: 1, windowTitle: "Fixture"), runID: context.runID)
        let lease = ForegroundWorkerLease()
        let host = PerryToolHost(executors: ScreenTools(workers: service, lease: lease, observations: observations).executors)
        try await lease.withRun(context.runID, workers: service) {
            let initial = await host.handle(ToolCall(id: "first", name: "screen.observe", arguments: .object([:])), context: context)
            XCTAssertFalse(initial.isError)
            XCTAssertNotNil(observations.resolveElement("e1", runID: context.runID))
            let missing = await host.handle(ToolCall(id: "missing", name: "screen.observe", arguments: .object(["windowTitle": .string("Closed document")])), context: context)
            XCTAssertTrue(missing.isError)
            XCTAssertNil(observations.resolveElement("e1", runID: context.runID))
            let retry = await host.handle(ToolCall(id: "retry", name: "screen.observe", arguments: .object([:])), context: context)
            XCTAssertTrue(retry.isError)
            let recovered = await host.handle(ToolCall(id: "recover", name: "screen.observe", arguments: .object(["windowTitle": .string("Fixture")])), context: context)
            XCTAssertFalse(recovered.isError)
            XCTAssertNotNil(observations.resolveElement("e1", runID: context.runID))
        }
    }

    func testCapturedWindowIDCannotFallBackToAnotherWindowInTheSameApp() async throws {
        let (service, directory) = try makeFixture(sharedTarget: true)
        let observations = AgentObservationStore()
        let context = ToolContext(surface: .agent)
        observations.setTarget(CuaTargetHint(bundleID: "fixture.shared", windowID: 999), runID: context.runID)
        let host = PerryToolHost(executors: ScreenTools(workers: service, lease: nil, observations: observations).executors)
        let result = await host.handle(ToolCall(id: "closed", name: "screen.observe", arguments: .object([:])), context: context)
        XCTAssertTrue(result.isError)
        let blankOverride = await host.handle(ToolCall(id: "blank", name: "screen.observe", arguments: .object(["windowTitle": .string(" ")])), context: context)
        XCTAssertTrue(blankOverride.isError)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let requests = try files.filter { $0.lastPathComponent.hasPrefix("requests-") }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(requests.contains("\"name\":\"get_window_state\""))
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
        try TestTempDirectory.remove(directory)
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

private struct ObserveThenClickProvider: ToolExecutingModelProvider {
    var pauseBeforeClick = false
    var explicitTarget = true
    let id = ProviderID.codex
    let displayName = "Observe then click fixture"
    let capabilities: ModelCapabilities = [.vision, .tools, .streaming]

    func warm() async {}

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }

    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = try await executeTool(ToolCall(
                        id: "observe", name: "screen.observe", arguments: explicitTarget ? .object(["bundleID": .string("fixture.shared")]) : .object([:])
                    ))
                    guard case .text(let text)? = observation.content.first else { throw CancellationError() }
                    if pauseBeforeClick {
                        continuation.yield(.textDelta("Observed."))
                        try await Task.sleep(for: .seconds(60))
                    }
                    let summary = try JSONValue(parsing: Data(text.utf8))
                    let elementID = summary["elements"]?.arrayValue?.first?["id"]?.stringValue ?? "missing"
                    _ = try await executeTool(ToolCall(id: "click", name: "ui.click", arguments: .object(["elementID": .string(elementID)])))
                    continuation.yield(.done(.endTurn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class MCPFixtureClient {
    private var fd: Int32

    init(directory: URL, token: String? = nil) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(directory.appendingPathComponent("perry-mcp.sock").path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { dest in
            bytes.withUnsafeBufferPointer { memcpy(dest, $0.baseAddress, $0.count) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        let credential = try token ?? SocketAuth.ensureToken(in: directory)
        try sendLine("{\"token\":\"\(credential)\"}")
    }

    func sendLine(_ line: String) throws {
        let bytes = Array((line + "\n").utf8)
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == bytes.count else { throw POSIXError(.EIO) }
    }

    func request(_ line: String) throws -> JSONValue {
        try sendLine(line)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[..<count])
            if let newline = reply.firstIndex(of: 10) {
                return try JSONValue(parsing: Data(reply.prefix(upTo: newline)))
            }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func isClosedByServer() -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) == 0
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

private final class MCPWaitingExecutor: ToolExecutor, @unchecked Sendable {
    let entered: @Sendable () -> Void
    let cancelled: @Sendable () -> Void
    private let lock = NSLock()
    private var effectCount = 0
    var effects: Int { lock.withLock { effectCount } }
    let spec = ToolSpec(name: "fixture.wait", description: "Wait", inputSchema: .object([
        "type": .string("object"), "properties": .object(["effect": .object(["type": .string("boolean")])])
    ]), surfaces: [.agent])

    init(entered: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.entered = entered
        self.cancelled = cancelled
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        if call.arguments["effect"] == .bool(true) {
            lock.withLock { effectCount += 1 }
            return .text(call.id, "effect")
        }
        entered()
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled()
            throw error
        }
        return .text(call.id, "finished")
    }
}

private struct MCPImageExecutor: ToolExecutor {
    let payload: Data
    let spec = ToolSpec(name: "fixture.image", description: "Image", inputSchema: .object(["type": .string("object")]), surfaces: [.agent])

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, content: [.image(data: payload, mimeType: "image/png")])
    }
}
