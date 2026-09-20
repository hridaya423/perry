import XCTest
@testable import PerryRuntimes
import PerryCore

final class TypedPlanParserTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typed-parser-\(UUID().uuidString)", isDirectory: true)
    private let window = ExecutableAction.WindowIdentity(bundleID: "com.apple.TextEdit", processID: 12, windowID: 34, connectionGeneration: 56)

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private var bindings: TypedPlanParser.Bindings {
        TypedPlanParser.Bindings(workspace: workspace, window: window, screenshotJPEGData: Data([1, 2, 3]))
    }

    func testParsesComputerActionWithBoundWindowAndBaseline() throws {
        let text = #"{"actions":[{"summary":"click Save","operation":{"computer":{"command":{"click":{"target":{"accessibilityID":"ax-ok"}}}}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(actions.count, 1)
        guard case .computer(let boundWindow, let command) = actions[0].operation else {
            return XCTFail("expected computer operation")
        }
        XCTAssertEqual(boundWindow, window)
        XCTAssertEqual(command, .click(.accessibilityID("ax-ok")))
        guard case .visualChange(let baseline) = actions[0].postcondition else {
            return XCTFail("expected visualChange postcondition")
        }
        XCTAssertEqual(baseline.count, 64)
        XCTAssertEqual(actions[0].approvalRequirement, .action)
    }

    func testTypeTextDerivesElementValuePostcondition() throws {
        let text = #"{"actions":[{"summary":"type name","operation":{"computer":{"command":{"typeText":{"text":"hello","target":{"windowPixels":{"x":4,"y":5}}}}}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(actions[0].postcondition, .elementValue("hello"))
    }

    func testTransformBindsWorkspaceAndPostcondition() throws {
        let text = #"{"actions":[{"summary":"create file","operation":{"transform":{"command":{"createUTF8File":{"path":"a.txt","contents":"hi"}}}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        guard case .transform(let boundWorkspace, let command) = actions[0].operation else {
            return XCTFail("expected transform")
        }
        XCTAssertEqual(boundWorkspace.standardizedFileURL.path, workspace.standardizedFileURL.path)
        XCTAssertEqual(command, .createUTF8File(path: "a.txt", contents: "hi"))
        XCTAssertEqual(actions[0].postcondition, .fileContents("hi"))
    }

    func testRenameBindsSourceIdentityFromDisk() throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        var identity = stat()
        XCTAssertEqual(Darwin.lstat(workspace.appendingPathComponent("a.txt").path, &identity), 0)
        let text = #"{"actions":[{"summary":"rename","operation":{"transform":{"command":{"rename":{"path":"a.txt","destination":"b.txt"}}}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(
            actions[0].postcondition,
            .renamedItem(device: UInt64(identity.st_dev), inode: UInt64(identity.st_ino))
        )
    }

    func testRenameOfMissingSourceFails() {
        let text = #"{"actions":[{"summary":"rename","operation":{"transform":{"command":{"rename":{"path":"missing.txt","destination":"b.txt"}}}}}]}"#
        XCTAssertThrowsError(try TypedPlanParser.parse(text, bindings: bindings))
    }

    func testAskUserIsIdempotentWithActionApproval() throws {
        let text = #"{"actions":[{"summary":"ask","operation":{"askUser":{"prompt":"which?","choices":["a","b"]}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(actions[0].approvalRequirement, .action)
        XCTAssertEqual(actions[0].idempotency, .idempotent)
        XCTAssertEqual(actions[0].postcondition, .answered)
    }

    func testIntegrationBindsResourcePostcondition() throws {
        let text = #"{"actions":[{"summary":"send","operation":{"integration":{"accountID":"slack","command":{"slackSendMessage":{"channelID":"C1","text":"hi"}}}}}]}"#
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(actions[0].postcondition, .integrationResource(identifier: "C1", expectedText: "hi"))
    }

    func testComputerActionRequiresWindow() {
        let noWindow = TypedPlanParser.Bindings(workspace: workspace, window: nil, screenshotJPEGData: Data([1]))
        let text = #"{"actions":[{"summary":"click","operation":{"computer":{"command":{"click":{"target":{"accessibilityID":"a"}}}}}}]}"#
        XCTAssertThrowsError(try TypedPlanParser.parse(text, bindings: noWindow))
    }

    func testNonTypeComputerActionRequiresScreenshotBaseline() {
        let noShot = TypedPlanParser.Bindings(workspace: workspace, window: window, screenshotJPEGData: nil)
        let text = #"{"actions":[{"summary":"click","operation":{"computer":{"command":{"click":{"target":{"accessibilityID":"a"}}}}}}]}"#
        XCTAssertThrowsError(try TypedPlanParser.parse(text, bindings: noShot))
    }

    func testExtractsJSONFromProse() throws {
        let text = "Here is the plan:\n```json\n{\"actions\":[{\"summary\":\"ask\",\"operation\":{\"askUser\":{\"prompt\":\"q?\",\"choices\":[\"x\"]}}}]}\n```\nDone."
        let actions = try TypedPlanParser.parse(text, bindings: bindings)
        XCTAssertEqual(actions.count, 1)
    }

    func testRejectsTraversalPath() throws {
        let text = #"{"actions":[{"summary":"evil","operation":{"transform":{"command":{"createUTF8File":{"path":"../out.txt","contents":"x"}}}}}]}"#
        XCTAssertThrowsError(try TypedPlanParser.parse(text, bindings: bindings))
    }

    func testPlanAssemblesScopesAndIDs() throws {
        let taskID = TaskID(UUID().uuidString)
        let request = try PlanningRequest(
            goal: "make a file",
            taskID: taskID,
            workspace: workspace,
            context: .none
        )
        let text = #"{"actions":[{"summary":"create","operation":{"transform":{"command":{"createUTF8File":{"path":"a.txt","contents":"x"}}}}}]}"#
        let plan = try TypedPlanParser.plan(text, request: request, bindings: bindings)
        XCTAssertEqual(plan.taskID, taskID)
        XCTAssertEqual(plan.requestedScopes, [.workspaceWrite])
    }
}
