import XCTest
import PerryCore
@testable import PerryBrain

final class ToolHostTests: XCTestCase {
    private let echoSpec = ToolSpec(
        name: "echo",
        description: "echoes",
        inputSchema: toolSchema(["text": .object(["type": .string("string")])], required: ["text"])
    )

    private func host(_ specs: [(String, TrustTier, Set<ToolSurface>)]) -> (PerryToolHost, [RecordingExecutor]) {
        let executors = specs.map { name, tier, surfaces in
            RecordingExecutor(spec: ToolSpec(
                name: name, description: name,
                inputSchema: toolSchema([:]), tier: tier, surfaces: surfaces
            ))
        }
        return (PerryToolHost(executors: executors), executors)
    }

    private func call(_ name: String, _ args: JSONValue = .object([:])) -> ToolCall {
        ToolCall(id: "c1", name: name, arguments: args)
    }

    func testRuntimeGroupsAddAndRemoveToolsWithoutShadowingBuiltIns() async {
        let (host, builtIns) = host([("files.read", .green, [.agent])])
        let added = ["mcp.notes.search", "files.read"].map {
            RecordingExecutor(spec: ToolSpec(name: $0, description: $0, inputSchema: toolSchema([:]), tier: .green, surfaces: [.agent]))
        }
        host.setExecutors(added, group: "notes")
        XCTAssertEqual(host.specs(for: .agent).map(\.name), ["files.read", "mcp.notes.search"])

        _ = await host.handle(call("mcp.notes.search"), context: ToolContext(surface: .agent))
        _ = await host.handle(call("files.read"), context: ToolContext(surface: .agent))
        XCTAssertEqual(added[0].callCount, 1)
        XCTAssertEqual(added[1].callCount, 0)
        XCTAssertEqual(builtIns[0].callCount, 1)

        host.setExecutors([], group: "notes")
        XCTAssertEqual(host.specs(for: .agent).map(\.name), ["files.read"])
        let removed = await host.handle(call("mcp.notes.search"), context: ToolContext(surface: .agent))
        XCTAssertTrue(removed.isError)
    }

    func testUnknownTool() async {
        let (host, _) = host([("echo", .green, [.agent])])
        let result = await host.handle(call("nope"), context: ToolContext(surface: .agent))
        XCTAssertTrue(result.isError)
    }

    func testCancellationDuringApprovalPreventsExecution() async {
        let (host, executors) = host([("files.delete", .orange, [.agent])])
        let request = call("files.delete")
        let task = Task {
            await host.handle(request, context: ToolContext(
                surface: .agent,
                approve: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .approvedOnce
                }
            ))
        }
        let result = await task.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executors[0].callCount, 0)
    }

    func testSuggestionsCannotUseScreenOrWriteToolsEvenIfRegistered() async {
        let (host, executors) = host([
            ("integrations.read", .green, [.agent, .suggestions]),
            ("integrations.write", .orange, [.agent, .suggestions]),
            ("screen.observe", .green, [.agent, .suggestions]),
            ("ui.click", .yellow, [.agent, .suggestions])
        ])
        XCTAssertEqual(host.specs(for: .suggestions).map(\.name), ["integrations.read"])
        for name in ["integrations.write", "screen.observe", "ui.click"] {
            let result = await host.handle(call(name), context: ToolContext(surface: .suggestions))
            XCTAssertTrue(result.isError)
        }
        XCTAssertTrue(executors.allSatisfy { $0.callCount == 0 })
    }

    func testUnknownKeyRejected() async {
        let executor = RecordingExecutor(spec: echoSpec)
        let host = PerryToolHost(executors: [executor])
        let result = await host.handle(
            ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("hi"), "evil": .bool(true)])),
            context: ToolContext(surface: .agent)
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executor.callCount, 0)
    }

    func testMissingRequiredRejected() async {
        let executor = RecordingExecutor(spec: echoSpec)
        let host = PerryToolHost(executors: [executor])
        let result = await host.handle(call("echo"), context: ToolContext(surface: .agent))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executor.callCount, 0)
    }

    func testNestedViolationNamesPath() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "rect": .object([
                    "type": .string("object"),
                    "properties": .object(["w": .object(["type": .string("number")])]),
                    "required": .array([.string("w")]),
                ]),
            ]),
        ])
        let detail = PerryToolHost.validate(
            .object(["rect": .object(["w": .string("wide")])]), against: schema
        )
        XCTAssertEqual(detail, "arguments.rect.w: expected number")
    }

    func testUnknownKeysFollowAdditionalProperties() {
        let declared = JSONValue.object(["type": .string("object"), "properties": .object(["q": .object(["type": .string("string")])])])
        let open = JSONValue.object(["type": .string("object")])
        let explicitlyOpen = JSONValue.object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(true)])
        let closed = JSONValue.object(["type": .string("object"), "additionalProperties": .bool(false)])
        let arguments = JSONValue.object(["extra": .string("x")])

        XCTAssertEqual(PerryToolHost.validate(arguments, against: declared), "arguments: unknown key \"extra\"")
        XCTAssertNil(PerryToolHost.validate(arguments, against: open))
        XCTAssertNil(PerryToolHost.validate(arguments, against: explicitlyOpen))
        XCTAssertEqual(PerryToolHost.validate(arguments, against: closed), "arguments: unknown key \"extra\"")
    }

    func testTalkSurfaceRunsAnAgentTool() async {
        let (host, executors) = host([("ui.click", .yellow, [.agent])])
        let result = await host.handle(call("ui.click"), context: ToolContext(surface: .talk))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(executors[0].callCount, 1)
    }

    func testGuideSurfaceRejectsActTool() async {
        let (host, executors) = host([("ui.click", .yellow, [.agent, .guide])])
        let result = await host.handle(call("ui.click"), context: ToolContext(surface: .guide))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executors[0].callCount, 0)
    }

    func testSpecsForTalkIncludeAgentTools() {
        let (host, _) = host([
            ("ui.click", .yellow, [.agent]),
            ("ring", .green, [.talk]),
            ("screen.observe", .green, [.talk, .agent]),
        ])
        XCTAssertEqual(host.specs(for: .talk).map(\.name), ["ring", "screen.observe", "ui.click"])
        XCTAssertEqual(host.specs(for: .agent).map(\.name), ["screen.observe", "ui.click"])
    }

    func testOrangeRequiresApprover() async {
        let (host, executors) = host([("files.delete", .orange, [.agent])])
        let denied = await host.handle(call("files.delete"), context: ToolContext(surface: .agent))
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(executors[0].callCount, 0)

        var asked = false
        let allowed = await host.handle(call("files.delete"), context: ToolContext(
            surface: .agent,
            approve: { _, _ in asked = true; return .approvedOnce }
        ))
        XCTAssertFalse(allowed.isError)
        XCTAssertTrue(asked)
        XCTAssertEqual(executors[0].callCount, 1)
    }

    func testApprovalDenied() async {
        let (host, executors) = host([("files.delete", .orange, [.agent])])
        let result = await host.handle(call("files.delete"), context: ToolContext(
            surface: .agent, approve: { _, _ in .denied }
        ))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executors[0].callCount, 0)
    }

    func testRedRequiresTypedConfirmationAndApproval() async {
        let (host, executors) = host([("files.emptyTrash", .red, [.agent])])
        let noTyped = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, approve: { _, _ in .approvedOnce }
        ))
        XCTAssertTrue(noTyped.isError)
        let noApprover = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, redConfirmed: true
        ))
        XCTAssertTrue(noApprover.isError)
        let ok = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, redConfirmed: true, approve: { _, _ in .approvedOnce }
        ))
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(executors[0].callCount, 1)
        let cardPath = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, approve: { _, _ in .approvedTyped }
        ))
        XCTAssertFalse(cardPath.isError)
        XCTAssertEqual(executors[0].callCount, 2)
    }

    func testExecutorThrowBecomesErrorResult() async {
        struct Boom: Error {}
        let executor = RecordingExecutor(spec: ToolSpec(name: "boom", description: "b", inputSchema: toolSchema([:])))
        executor.body = { _ in throw Boom() }
        let host = PerryToolHost(executors: [executor])
        let result = await host.handle(call("boom"), context: ToolContext(surface: .agent))
        XCTAssertTrue(result.isError)
    }
}
