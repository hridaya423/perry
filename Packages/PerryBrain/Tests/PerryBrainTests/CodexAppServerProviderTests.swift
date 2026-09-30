import Foundation
@testable import PerryBrain
import XCTest

final class CodexAppServerProviderTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-brain-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func fixtureServer() throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: "fake-codex-app-server", withExtension: "py", subdirectory: "Fixtures"
        ))
    }

    private func makeProcess(scenario: String, log: URL? = nil, state: URL? = nil) throws -> CodexAppServerProcess {
        let root = tempDir()
        var extra = [
            "SCENARIO": scenario,
            "PERRY_FAKE_STDERR": "/tmp/fake-\(scenario)-stderr.log",
            "FAKE_LOG": (log ?? URL(fileURLWithPath: "/tmp/fake-\(scenario)-\(UUID().uuidString).jsonl")).path,
        ]
        if let state { extra["FAKE_STATE"] = state.path }
        return CodexAppServerProcess(
            configuration: CodexAppServerConfiguration(
                binaryURL: URL(fileURLWithPath: "/usr/bin/python3"),
                codexHome: root.appendingPathComponent("codex-home", isDirectory: true),
                workingDirectory: root.appendingPathComponent("work", isDirectory: true),
                processArguments: ["-u", try fixtureServer().path],
                extraEnvironment: extra
            ),
            sleeps: { _ in }
        )
    }

    func testConcurrentConnectionsShareOneInitialization() async throws {
        let log = tempDir().appendingPathComponent("shared.jsonl")
        let process = try makeProcess(scenario: "b", log: log)
        let connections = try await withThrowingTaskGroup(of: JSONRPCConnection.self) { group in
            for _ in 0..<12 { group.addTask { try await process.connection() } }
            var connections: [JSONRPCConnection] = []
            for try await connection in group { connections.append(connection) }
            return connections
        }
        XCTAssertTrue(connections.allSatisfy { $0 === connections.first })
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains(#""method": "initialize""#) }.count, 1)
        await process.terminate()
        let closed = await connections[0].closed
        XCTAssertTrue(closed)
        let lateEvents = await connections[0].events
        let lateCount = try await withTimeout {
            var count = 0
            for await _ in lateEvents { count += 1 }
            return count
        }
        XCTAssertEqual(lateCount, 0)
        do {
            _ = try await process.connection()
            XCTFail("A retired process must not respawn")
        } catch is CancellationError {
        }
    }

    func testCancellingOneConnectionWaiterPreservesOtherRequests() async throws {
        let log = tempDir().appendingPathComponent("cancel-waiter.jsonl")
        let process = try makeProcess(scenario: "delayed-initialize", log: log)
        let first = Task { try await process.connection() }
        let second = Task { try await process.connection() }
        try await withTimeout {
            while (try? String(contentsOf: log, encoding: .utf8).contains("initialize")) != true {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancellation must release this caller")
        } catch is CancellationError {
        }
        let connection = try await second.value
        let closed = await connection.closed
        XCTAssertFalse(closed)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains(#""method": "initialize""#) }.count, 1)
        await process.terminate()
    }

    func testUnresponsiveInitializationExpiresAndReapsItsChild() async throws {
        let log = tempDir().appendingPathComponent("deadline.jsonl")
        let process = try makeProcess(scenario: "blocked-initialize", log: log)
        do {
            _ = try await withTimeout(15) { try await process.connection() }
            XCTFail("An unresponsive handshake must expire")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32098)
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let pids = try lines.compactMap { try JSONValue(parsing: Data($0.utf8))["blocked_pid"]?.doubleValue }
        let pid = Int32(try XCTUnwrap(pids.first))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        await process.terminate()
    }

    func testShutdownJoinsBlockedInitializationAndReapsUnresponsiveChild() async throws {
        let log = tempDir().appendingPathComponent("blocked.jsonl")
        let process = try makeProcess(scenario: "blocked-initialize", log: log)
        let startup = Task { try await process.connection() }
        let child = try await withTimeout(5) { () async throws -> Int32 in
            while true {
                let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
                for line in lines {
                    if let value = try JSONValue(parsing: Data(line.utf8))["blocked_pid"]?.doubleValue {
                        return Int32(value)
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        async let first: Void = process.terminate()
        async let second: Void = process.terminate()
        _ = await (first, second)
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        do {
            _ = try await startup.value
            XCTFail("Interrupted initialization must not return a connection")
        } catch {
        }
        do {
            _ = try await process.connection()
            XCTFail("Shutdown must prevent a fresh process")
        } catch is CancellationError {
        }
    }

    func testSignedOutLoginFlow() async throws {
        let process = try makeProcess(scenario: "a")
        let account = CodexAccount(process: process)
        let status = await account.status()
        XCTAssertEqual(status, .signedOut)
        var sawCompletion = false
        let loginEvents = try await account.loginEvents()
        let loginTask = Task<CodexLoginEvent?, Never> {
            for await event in loginEvents {
                if case .completed = event { return event }
            }
            return nil
        }
        let session = try await account.signIn()
        XCTAssertEqual(session.id, "login-1")
        XCTAssertEqual(session.url.absoluteString, "https://example.invalid/auth?loginId=login-1")
        if let event = try await withTimeout { await loginTask.value },
           case .completed(let success, let loginID, _) = event {
            XCTAssertTrue(success)
            XCTAssertEqual(loginID, "login-1")
            sawCompletion = true
        }
        XCTAssertTrue(sawCompletion)
        await process.terminate()
    }

    func testCancellationTargetsTheStartedLogin() async throws {
        let log = tempDir().appendingPathComponent("login.jsonl")
        let process = try makeProcess(scenario: "b", log: log)
        let account = CodexAccount(process: process)
        let session = try await account.signIn()
        try await account.cancelSignIn(id: session.id)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let line = try XCTUnwrap(lines.first { $0.contains(#""account/login/cancel""#) })
        let request = try JSONValue(parsing: Data(line.utf8))
        XCTAssertEqual(request["params"]?["loginId"]?.stringValue, session.id)
        await process.terminate()
    }

    func testMissingOrUnknownCompletionStatusFails() async throws {
        for scenario in ["missing-status", "unknown-status"] {
            let process = try makeProcess(scenario: scenario)
            let provider = CodexAppServerProvider(process: process)
            do {
                _ = try await withTimeout { try await drain(provider.stream(sampleRequest())) }
                XCTFail("Invalid completion status must fail")
            } catch let error as ModelProviderError {
                XCTAssertEqual(error.kind, .malformed)
            }
            await process.terminate()
        }
    }

    func testTurnStreamsDeltasUsageAndDone() async throws {
        let process = try makeProcess(scenario: "b")
        let provider = CodexAppServerProvider(process: process)
        let events = try await withTimeout { try await drain(provider.stream(sampleRequest())) }
        XCTAssertEqual(text(events), "Hello from fake-codex")
        XCTAssertTrue(events.contains(.usage(inputTokens: 30, outputTokens: 9)))
        XCTAssertEqual(stopReason(events), .endTurn)
        await process.terminate()
    }

    func testHistoryIsSeparateFromTheCurrentRequestOnTheWire() async throws {
        let log = tempDir().appendingPathComponent("history.jsonl")
        let process = try makeProcess(scenario: "b", log: log)
        let provider = CodexAppServerProvider(process: process)
        let request = ModelRequest(messages: [
            .user([.text("My destination is Cedar. Reply with the name only.")]),
            .assistant(text: "Cedar", toolCalls: []),
            .user([.text("Write a travel diary about that destination.")])
        ])
        _ = try await withTimeout { try await drain(provider.stream(request)) }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let line = try XCTUnwrap(lines.first { $0.contains(#""turn/start""#) })
        let wire = try JSONValue(parsing: Data(line.utf8))
        let input = try XCTUnwrap(wire["params"]?["input"]?.arrayValue)
        XCTAssertEqual(input.count, 1)
        let text = try XCTUnwrap(input.first?["text"]?.stringValue)
        let envelope = try JSONValue(parsing: Data(text.utf8))
        let history = try XCTUnwrap(envelope["history"]?.arrayValue)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?["role"]?.stringValue, "user")
        XCTAssertEqual(history.last?["role"]?.stringValue, "assistant")
        XCTAssertEqual(envelope["currentMessage"]?["role"]?.stringValue, "user")
        XCTAssertEqual(envelope["currentMessage"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "Write a travel diary about that destination.")
        await process.terminate()
    }

    func testToolContextAndTransientImagesSurviveInputSerialization() async throws {
        let log = tempDir().appendingPathComponent("image-history.jsonl")
        let process = try makeProcess(scenario: "b", log: log)
        let provider = CodexAppServerProvider(process: process)
        let call = ToolCall(id: "screen-1", name: "screen.capture", arguments: .object([:]))
        let request = ModelRequest(messages: [
            .user([.text("Describe the current target")]),
            .assistant(text: "", toolCalls: [call]),
            .toolResult(callID: call.id, content: [.text("Target image"), .image(data: Data([1, 2, 3]), mimeType: "image/png")], isError: false)
        ])
        _ = try await withTimeout { try await drain(provider.stream(request)) }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let line = try XCTUnwrap(lines.first { $0.contains(#""turn/start""#) })
        let wire = try JSONValue(parsing: Data(line.utf8))
        let input = try XCTUnwrap(wire["params"]?["input"]?.arrayValue)
        XCTAssertEqual(input.count, 2)
        let envelope = try JSONValue(parsing: Data(try XCTUnwrap(input.first?["text"]?.stringValue).utf8))
        XCTAssertEqual(envelope["history"]?.arrayValue?.last?["toolCalls"]?.arrayValue?.first?["id"]?.stringValue, call.id)
        XCTAssertEqual(envelope["currentMessage"]?["role"]?.stringValue, "tool")
        XCTAssertEqual(envelope["currentMessage"]?["callID"]?.stringValue, call.id)
        XCTAssertEqual(envelope["currentMessage"]?["content"]?.arrayValue?.last?["attachment"]?.doubleValue, 1)
        let imagePath = try XCTUnwrap(input.last?["path"]?.stringValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
        await process.terminate()
    }

    func testRateLimits() async throws {
        let process = try makeProcess(scenario: "b")
        let account = CodexAccount(process: process)
        let limits = try await withTimeout { try await account.rateLimits() }
        XCTAssertEqual(limits?.primaryUsedPercent, 42)
        XCTAssertEqual(limits?.secondaryUsedPercent, 10)
        XCTAssertEqual(limits?.planType, "pro")
        XCTAssertEqual(limits?.primaryResetsAt, Date(timeIntervalSince1970: 1893456000))
        await process.terminate()
    }

    func testDynamicToolCall() async throws {
        let process = try makeProcess(scenario: "c")
        let provider = CodexAppServerProvider(
            process: process,
            toolHandler: { call in
                XCTAssertEqual(call.name, "get_weather")
                XCTAssertEqual(call.arguments["city"], .string("Paris"))
                return ToolCallResult(text: "sunny")
            }
        )
        let events = try await withTimeout { try await drain(provider.stream(sampleRequest(tools: [sampleTool]))) }
        XCTAssertEqual(toolCalls(events).map(\.name), ["get_weather"])
        XCTAssertEqual(text(events), "It is sunny.")
        XCTAssertEqual(stopReason(events), .endTurn)
        await process.terminate()
    }

    func testDottedToolNameIsTranslatedOnlyAtTheProviderBoundary() async throws {
        let log = tempDir().appendingPathComponent("names.jsonl")
        let process = try makeProcess(scenario: "c", log: log)
        let tool = ToolSpec(name: "get.weather", description: "Weather", inputSchema: sampleTool.inputSchema)
        let provider = CodexAppServerProvider(process: process, toolHandler: { call in
            XCTAssertEqual(call.name, "get.weather")
            return ToolCallResult(text: "sunny")
        })
        let events = try await withTimeout { try await drain(provider.stream(sampleRequest(tools: [tool]))) }
        XCTAssertEqual(toolCalls(events).map(\.name), ["get.weather"])
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let line = try XCTUnwrap(lines.first { $0.contains(#""thread/start""#) })
        let request = try JSONValue(parsing: Data(line.utf8))
        XCTAssertEqual(request["params"]?["dynamicTools"]?.arrayValue?.first?["type"]?.stringValue, "function")
        let name = try XCTUnwrap(request["params"]?["dynamicTools"]?.arrayValue?.first?["name"]?.stringValue)
        XCTAssertNotNil(name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression))
        await process.terminate()
    }

    func testAgentLoopExecutesCodexToolThroughHostExactlyOnce() async throws {
        let log = tempDir().appendingPathComponent("native-tool.jsonl")
        let process = try makeProcess(scenario: "c", log: log)
        let provider = CodexAppServerProvider(process: process)
        let executor = RecordingExecutor(spec: sampleTool)
        executor.body = { call in ToolResult(callID: call.id, content: [.text("sunny"), .image(data: Data([1, 2, 3]), mimeType: "image/png")]) }
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = try await withTimeout {
            var events: [AgentLoopEvent] = []
            for await event in loop.run(system: "Weather", messages: [.user([.text("Paris?")])], context: ToolContext(surface: .agent)) {
                events.append(event)
            }
            return events
        }
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertTrue(events.contains(.textDelta("It is sunny.")))
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(events.filter { if case .toolCallStarted = $0 { return true }; return false }.count, 1)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains(#""thread/start""#) }.count, 1)
        let replies = try lines.map { try JSONValue(parsing: Data($0.utf8)) }
        let toolReply = try XCTUnwrap(replies.first { $0["result"]?["contentItems"] != nil })
        let image = toolReply["result"]?["contentItems"]?.arrayValue?.last
        XCTAssertEqual(image?["type"], .string("inputImage"))
        XCTAssertEqual(image?["imageUrl"], .string("data:image/png;base64,AQID"))

        await process.terminate()
    }

    func testCancellingNativeApprovalNeverDispatchesTheEffect() async throws {
        let process = try makeProcess(scenario: "c")
        let started = expectation(description: "Approval opened")
        let cancelled = expectation(description: "Approval cancelled")
        let spec = ToolSpec(name: sampleTool.name, description: sampleTool.description, inputSchema: sampleTool.inputSchema, tier: .orange)
        let executor = RecordingExecutor(spec: spec)
        let loop = AgentLoop(provider: CodexAppServerProvider(process: process), host: PerryToolHost(executors: [executor]))
        let context = ToolContext(surface: .agent, approve: { _, _ in
            started.fulfill()
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelled.fulfill()
            }
            return .approvedOnce
        })
        let consumer = Task {
            for await _ in loop.run(system: "Weather", messages: [], context: context) {}
        }
        await fulfillment(of: [started], timeout: 3)
        consumer.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await consumer.value
        XCTAssertEqual(executor.callCount, 0)
        await process.terminate()
    }

    func testNativeToolExecutionHonorsActionBudget() async throws {
        let process = try makeProcess(scenario: "c")
        let executor = RecordingExecutor(spec: sampleTool)
        let loop = AgentLoop(
            provider: CodexAppServerProvider(process: process),
            host: PerryToolHost(executors: [executor]), budgets: .init(maxToolCalls: 0)
        )
        let last = try await withTimeout {
            var last: AgentLoopEvent?
            for await event in loop.run(system: "Weather", messages: [], context: ToolContext(surface: .agent)) { last = event }
            return last
        }
        XCTAssertEqual(last, .finished(.budgetToolCalls))
        XCTAssertEqual(executor.callCount, 0)
        await process.terminate()
    }

    func testProcessExitMidTurnThenRespawn() async throws {
        let root = tempDir()
        let stateFile = root.appendingPathComponent("once")
        let process = try makeProcess(scenario: "d", state: stateFile)
        let provider = CodexAppServerProvider(process: process)
        do {
            _ = try await withTimeout { try await drain(provider.stream(sampleRequest())) }
            XCTFail("expected mid-turn failure")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .unavailable)
        }
        let events = try await withTimeout { try await drain(provider.stream(sampleRequest())) }
        XCTAssertEqual(text(events), "Hello from fake-codex")
        XCTAssertEqual(stopReason(events), .endTurn)
        await process.terminate()
    }

    func testCancellationSendsTurnInterrupt() async throws {
        let log = tempDir().appendingPathComponent("fake.jsonl")
        let process = try makeProcess(scenario: "e", log: log)
        let provider = CodexAppServerProvider(process: process)
        let stream = provider.stream(sampleRequest())
        let consumer = Task {
            var events: [ModelEvent] = []
            do {
                for try await event in stream { events.append(event) }
            } catch { FileHandle.standardError.write(Data("stream error: \(error)\n".utf8)) }
            return events
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        consumer.cancel()
        _ = try await withTimeout(5) { await consumer.value }

        let deadline = Date().addingTimeInterval(5)
        var sawInterrupt = false
        while Date() < deadline, !sawInterrupt {
            if let data = try? Data(contentsOf: log),
               let lines = String(decoding: data, as: UTF8.self).split(separator: "\n") as [Substring]? {
                sawInterrupt = lines.contains { $0.contains(#""turn/interrupt""#) }
            }
            if !sawInterrupt { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(sawInterrupt, "fake server never received turn/interrupt")
        await process.terminate()
    }

    func testSentMethodsExistInCommittedSchema() throws {
        let clientRequestURL = try XCTUnwrap(Bundle.module.url(
            forResource: "ClientRequest", withExtension: "json", subdirectory: "Fixtures/codex-app-server-schema"
        ))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: clientRequestURL)) as? [String: Any])
        let variants = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        var allowed = Set<String>()
        for variant in variants {
            let props = variant["properties"] as? [String: Any]
            let method = props?["method"] as? [String: Any]
            if let values = method?["enum"] as? [String], let first = values.first {
                allowed.insert(first)
            }
        }
        let sent: Set<String> = [
            "initialize", "thread/start", "turn/start", "turn/interrupt",
            "account/read", "account/login/start", "account/logout",
            "account/rateLimits/read", "model/list",
        ]
        XCTAssertTrue(sent.isSubset(of: allowed), "missing: \(sent.subtracting(allowed))")

        let clientNotificationURL = try XCTUnwrap(Bundle.module.url(
            forResource: "ClientNotification", withExtension: "json", subdirectory: "Fixtures/codex-app-server-schema"
        ))
        let notificationSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: clientNotificationURL)) as? [String: Any])
        let notificationVariants = try XCTUnwrap(notificationSchema["oneOf"] as? [[String: Any]])
        var allowedNotifications = Set<String>()
        for variant in notificationVariants {
            let props = variant["properties"] as? [String: Any]
            let method = props?["method"] as? [String: Any]
            if let values = method?["enum"] as? [String], let first = values.first {
                allowedNotifications.insert(first)
            }
        }
        XCTAssertTrue(allowedNotifications.contains("initialized"))
    }

    func testProviderSendsExperimentalCapabilities() async throws {
        let log = tempDir().appendingPathComponent("fake.jsonl")
        let process = try makeProcess(scenario: "b", log: log)
        let provider = CodexAppServerProvider(process: process)
        _ = try await withTimeout { try await drain(provider.stream(sampleRequest())) }
        let data = try Data(contentsOf: log)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let initialize = try XCTUnwrap(lines.first { $0.contains(#""initialize""#) })
        let initializeJSON = try JSONValue(parsing: Data(initialize.utf8))
        XCTAssertEqual(initializeJSON["params"]?["capabilities"]?["experimentalApi"], .bool(true))
        let thread = try XCTUnwrap(lines.first { $0.contains(#""thread/start""#) })
        let threadJSON = try JSONValue(parsing: Data(thread.utf8))
        XCTAssertEqual(threadJSON["params"]?["ephemeral"], .bool(true))
        XCTAssertEqual(threadJSON["params"]?["approvalPolicy"], .string("never"))
        XCTAssertEqual(threadJSON["params"]?["sandbox"], .string("read-only"))
        await process.terminate()
    }
}
