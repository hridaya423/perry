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

    func testUnknownTool() async {
        let (host, _) = host([("echo", .green, [.agent])])
        let result = await host.handle(call("nope"), context: ToolContext(surface: .agent))
        XCTAssertTrue(result.isError)
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

    func testTalkSurfaceRejectsActTool() async {
        let (host, executors) = host([("ui.click", .yellow, [.agent, .talk])])
        // Even though the spec claims .talk, the name gate denies it.
        let result = await host.handle(call("ui.click"), context: ToolContext(surface: .talk))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(executors[0].callCount, 0)
    }

    func testSpecsForTalkOnlyReturnsObserveAndDraw() {
        let (host, _) = host([
            ("ui.click", .yellow, [.agent, .talk]),
            ("ring", .green, [.talk]),
            ("screen.observe", .green, [.talk, .agent]),
        ])
        XCTAssertEqual(host.specs(for: .talk).map(\.name), ["ring", "screen.observe"])
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
        // Approver allows but no typed confirmation.
        let noTyped = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, approve: { _, _ in .approvedOnce }
        ))
        XCTAssertTrue(noTyped.isError)
        // Typed confirmation with no approver still fails closed.
        let noApprover = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, redConfirmed: true
        ))
        XCTAssertTrue(noApprover.isError)
        // Both present → runs.
        let ok = await host.handle(call("files.emptyTrash"), context: ToolContext(
            surface: .agent, redConfirmed: true, approve: { _, _ in .approvedOnce }
        ))
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(executors[0].callCount, 1)
        // A surface that collects the typed phrase itself (intent card)
        // answers .approvedTyped and needs no preflighted flag.
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
