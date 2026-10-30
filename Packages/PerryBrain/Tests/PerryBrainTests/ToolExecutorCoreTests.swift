import XCTest
import PerryCore
@testable import PerryBrain

final class ToolExecutorCoreTests: XCTestCase {
    private var root: URL!
    private var backend: LocalWorkspaceFiles!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backend = try LocalWorkspaceFiles(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
        ToolCall(id: "c1", name: name, arguments: .object(args))
    }

    private func fileHost() -> PerryToolHost {
        PerryToolHost(executors: FileToolExecutors.make(backend: backend))
    }

    private func parse(_ result: ToolResult) throws -> JSONValue {
        guard case .text(let text)? = result.content.first else {
            XCTFail("expected text result")
            return .null
        }
        return try JSONValue(parsing: Data(text.utf8))
    }

    func testWriteListReadRoundTrip() async throws {
        try await backend.write(path: "notes.txt", contents: "hello")
        let entries = try await backend.list(path: ".")
        XCTAssertEqual(entries.map(\.path), ["notes.txt"])

        let result = try await backend.read(path: "notes.txt", maxBytes: 1024)
        XCTAssertEqual(result.text, "hello")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.byteCount, 5)
    }

    func testWriteRefusesExisting() async throws {
        try await backend.write(path: "a.txt", contents: "1")
        await XCTAssertThrowsErrorAsync(try await backend.write(path: "a.txt", contents: "2"))
    }

    func testOverwriteReturnsPreviousForUndo() async throws {
        try await backend.write(path: "a.txt", contents: "old")
        let previous = try await backend.overwrite(path: "a.txt", contents: "new")
        XCTAssertEqual(previous, "old")
        let result = try await backend.read(path: "a.txt", maxBytes: 1024)
        XCTAssertEqual(result.text, "new")
    }

    func testMoveAndMkdir() async throws {
        try await backend.write(path: "shot.png.txt", contents: "x")
        try await backend.makeDirectory(path: "Shots")
        try await backend.move(source: "shot.png.txt", destination: "Shots/shot.png.txt")
        let entries = try await backend.list(path: "Shots")
        XCTAssertEqual(entries.map(\.path), ["Shots/shot.png.txt"])
    }

    func testTrashRemovesFile() async throws {
        try await backend.write(path: "junk.txt", contents: "x")
        _ = try await backend.trash(path: "junk.txt")
        let entries = try await backend.list(path: ".")
        XCTAssertTrue(entries.isEmpty)
    }

    func testTrashIsRestorableViaMove() async throws {
        try await backend.write(path: "keep.txt", contents: "x")
        let trashedTo = try await backend.trash(path: "keep.txt")
        XCTAssertTrue(trashedTo.hasPrefix(".trash/"))
        try await backend.move(source: trashedTo, destination: "keep.txt")
        let restored = try await backend.read(path: "keep.txt", maxBytes: 10)
        XCTAssertEqual(restored.text, "x")
    }

    func testEscapesRejected() async throws {
        await XCTAssertThrowsErrorAsync(try await backend.read(path: "../outside.txt", maxBytes: 10))
        await XCTAssertThrowsErrorAsync(try await backend.read(path: "/etc/hosts", maxBytes: 10))
        await XCTAssertThrowsErrorAsync(try await backend.write(path: "../evil.txt", contents: "x"))
        await XCTAssertThrowsErrorAsync(try await backend.move(source: "a", destination: "../b"))
    }

    func testSymlinkEscapeRejected() async throws {
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        await XCTAssertThrowsErrorAsync(try await backend.read(path: "link.txt", maxBytes: 10))
    }

    func testReadTruncates() async throws {
        try await backend.write(path: "big.txt", contents: String(repeating: "x", count: 100))
        let result = try await backend.read(path: "big.txt", maxBytes: 10)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.count, 10)
        XCTAssertEqual(result.byteCount, 100)
    }

    func testFilesWriteThroughHostEmitsUndo() async throws {
        let host = fileHost()
        let result = await host.handle(
            call("files.write", ["path": .string("n.txt"), "contents": .string("hi")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(result.isError)
        let json = try parse(result)
        XCTAssertEqual(json["undo"]?["tool"]?.stringValue, "files.trash")
        XCTAssertEqual(json["undo"]?["arguments"]?["path"]?.stringValue, "n.txt")
    }

    func testFilesToolsDeniedOnGuideSurface() async throws {
        let host = fileHost()
        for name in ["files.list", "files.read", "files.write", "files.trash"] {
            let result = await host.handle(
                call(name, ["path": .string("x")]),
                context: ToolContext(surface: .guide)
            )
            XCTAssertTrue(result.isError, "\(name) should be denied on guide")
        }
    }

    func testFilesTrashRunsWithoutAskingAndCanBeUndone() async throws {
        try await backend.write(path: "victim.txt", contents: "x")
        let result = await fileHost().handle(
            call("files.trash", ["path": .string("victim.txt")]),
            context: ToolContext(surface: .talk)
        )
        XCTAssertFalse(result.isError)
        let after = try await backend.list(path: ".")
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(try parse(result)["undo"]?["tool"]?.stringValue, "files.move")
    }

    func testFilesOverwriteRunsWithoutAskingAndKeepsTheOldContentsForUndo() async throws {
        try await backend.write(path: "a.txt", contents: "old")
        let result = await fileHost().handle(
            call("files.overwrite", ["path": .string("a.txt"), "contents": .string("new")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(result.isError)
        let now = try await backend.read(path: "a.txt", maxBytes: 10)
        XCTAssertEqual(now.text, "new")
        XCTAssertEqual(try parse(result)["undo"]?["arguments"]?["contents"]?.stringValue, "old")
    }

    func testFilesUnknownKeyRejected() async throws {
        let host = fileHost()
        let result = await host.handle(
            call("files.read", ["path": .string("a"), "surprise": .bool(true)]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
    }

    func testMemoryReadWrite() async throws {
        let files = MemoryFiles(directory: root)
        let host = PerryToolHost(executors: MemoryToolExecutors.make(files: files))

        _ = await host.handle(
            call("memory.write", [
                "section": .string("profile"), "text": .string("likes terse answers"),
            ]),
            context: ToolContext(surface: .agent)
        )
        let result = await host.handle(
            call("memory.read", ["section": .string("profile")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(result.isError)
        guard case .text(let text)? = result.content.first else { return XCTFail() }
        XCTAssertEqual(text, "likes terse answers")

        _ = await host.handle(
            call("memory.write", [
                "section": .string("profile"), "text": .string(" +coffee"),
                "mode": .string("append"),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertEqual(files.profile(), "likes terse answers +coffee")
    }

    private func integrationHost(
        writeEnabled: Bool = true,
        calls: LockedCalls = LockedCalls()
    ) -> PerryToolHost {
        let backend = FakeIntegrations(writeEnabled: writeEnabled, calls: calls)
        return PerryToolHost(executors: IntegrationToolExecutors.make(backend: backend))
    }

    func testIntegrationsList() async throws {
        let host = integrationHost()
        let result = await host.handle(call("integrations.list"), context: ToolContext(surface: .agent))
        let json = try parse(result)
        XCTAssertEqual(json["services"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["notion"])
    }

    func testIntegrationReadRunsReadOp() async throws {
        let calls = LockedCalls()
        let host = integrationHost(calls: calls)
        let result = await host.handle(
            call("integrations.read", [
                "service": .string("notion"), "operation": .string("search"),
                "arguments": .object(["query": .string("launch")]),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(calls.all.map { $0.1 }, ["search"])
    }

    func testIntegrationReadRefusesWriteOp() async throws {
        let host = integrationHost()
        let result = await host.handle(
            call("integrations.read", [
                "service": .string("notion"), "operation": .string("create_page"),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
    }

    func testIntegrationWriteNeedsApprovalAndEnabledFlag() async throws {
        let calls = LockedCalls()
        let offHost = integrationHost(writeEnabled: false, calls: calls)
        let off = await offHost.handle(
            call("integrations.write", [
                "service": .string("notion"), "operation": .string("create_page"),
            ]),
            context: ToolContext(surface: .agent, approve: { _, _ in .approvedOnce })
        )
        XCTAssertTrue(off.isError)
        XCTAssertEqual(calls.all.count, 0)

        let onHost = integrationHost(writeEnabled: true, calls: calls)
        let noApprover = await onHost.handle(
            call("integrations.write", [
                "service": .string("notion"), "operation": .string("create_page"),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(noApprover.isError)
        XCTAssertEqual(calls.all.count, 0)

        let approved = await onHost.handle(
            call("integrations.write", [
                "service": .string("notion"), "operation": .string("create_page"),
            ]),
            context: ToolContext(surface: .agent, approve: { _, _ in .approvedOnce })
        )
        XCTAssertFalse(approved.isError)
        XCTAssertEqual(calls.all.map { $0.1 }, ["create_page"])
    }

    func testIntegrationInnerArgsValidated() async throws {
        let host = integrationHost()
        let result = await host.handle(
            call("integrations.read", [
                "service": .string("notion"), "operation": .string("search"),
                "arguments": .object(["bogus": .number(1)]),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
    }

    func testPerryCreateListSchedule() async throws {
        let store = PerryStore(directory: root)
        let opened = StringBox()
        let host = PerryToolHost(executors: PerryToolExecutors.make(store: store) { page in
            opened.value = page
        })

        let created = await host.handle(
            call("perry.createPerry", ["job": .string("clean my Desktop every morning")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(created.isError)
        let createdJSON = try parse(created)
        XCTAssertEqual(createdJSON["name"]?.stringValue, "Tidy Desk")

        let listed = await host.handle(call("perry.list"), context: ToolContext(surface: .agent))
        XCTAssertEqual(try parse(listed)["perrys"]?.arrayValue?.count, 1)

        let id = try XCTUnwrap(createdJSON["id"]?.stringValue)
        let scheduled = await host.handle(
            call("perry.schedule", [
                "perry": .string(id), "kind": .string("daily"),
                "hour": .number(9), "minute": .number(0),
            ]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(scheduled.isError)
        let stored = await store.list().first
        XCTAssertEqual(stored?.schedule?.kind, .daily(hour: 9, minute: 0))

        let cleared = await host.handle(
            call("perry.schedule", ["perry": .string(id), "kind": .string("off")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(cleared.isError)
        let afterClear = await store.list().first
        XCTAssertNil(afterClear?.schedule)

        let openedResult = await host.handle(
            call("perry.settings.open", ["page": .string("perrys")]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertFalse(openedResult.isError)
        XCTAssertEqual(opened.value, "perrys")
    }

    func testPerryScheduleRejectsUnknownPerry() async throws {
        let host = PerryToolHost(executors: PerryToolExecutors.make(store: PerryStore(directory: root)))
        let result = await host.handle(
            call("perry.schedule", ["perry": .string("Nobody"), "kind": .string("daily"), "hour": .number(9)]),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
    }

    func testSettingsOpenWithoutHandlerFails() async throws {
        let host = PerryToolHost(executors: PerryToolExecutors.make(store: PerryStore(directory: root)))
        let result = await host.handle(
            call("perry.settings.open"), context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String? = nil
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String, JSONValue)] = []
    var all: [(String, String, JSONValue)] { lock.withLock { values } }
    func record(_ s: String, _ o: String, _ a: JSONValue) { lock.withLock { values.append((s, o, a)) } }
}

private final class FakeIntegrations: IntegrationBackend {
    let writeEnabled: Bool
    let calls: LockedCalls

    init(writeEnabled: Bool, calls: LockedCalls) {
        self.writeEnabled = writeEnabled
        self.calls = calls
    }

    func services() async throws -> [IntegrationService] {
        [IntegrationService(
            id: "notion", name: "Notion", connected: true, writeEnabled: writeEnabled,
            operations: [
                IntegrationOperation(
                    name: "search", description: "Search pages", isWrite: false,
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["query": .object(["type": .string("string")])]),
                    ])
                ),
                IntegrationOperation(name: "create_page", description: "Create a page", isWrite: true),
            ]
        ), IntegrationService(id: "slack", name: "Slack", connected: false, writeEnabled: false, operations: [])]
    }

    func perform(service: String, operation: String, arguments: JSONValue) async throws -> JSONValue {
        calls.record(service, operation, arguments)
        return .object(["ok": .bool(true)])
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected error", file: file, line: line)
        } catch {}
    }
}
