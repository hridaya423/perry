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
        let url = try await account.signIn()
        XCTAssertEqual(url?.absoluteString, "https://example.invalid/auth?loginId=login-1")
        if let event = try await withTimeout { await loginTask.value },
           case .completed(let success, let loginID, _) = event {
            XCTAssertTrue(success)
            XCTAssertEqual(loginID, "login-1")
            sawCompletion = true
        }
        XCTAssertTrue(sawCompletion)
        await process.terminate()
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
