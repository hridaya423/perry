import XCTest
import PerryRuntimes
@testable import Perry

final class CompositeActionVerifierTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-composite-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defer { workspace = nil }
        if let workspace {
            try FileManager.default.removeItem(at: workspace)
        }
        try super.tearDownWithError()
    }

    func testTransformVerifiesThroughWorkspaceReadBack() async throws {
        let action = try ExecutableAction(
            id: "write",
            summary: "Create a file",
            approvalRequirement: .plan,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "out.txt", contents: "hello")
            ),
            postcondition: .fileContents("hello")
        )
        let approved = try await approve(action)
        let result = try await WorkspaceFileRuntime(baseURL: workspace).execute(approved)

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: result, context: .empty)
        guard case .verified = status else {
            XCTFail("transform should verify, got \(status)")
            return
        }
    }

    func testTransformWithoutReceiptIsUnverified() async throws {
        let action = try ExecutableAction(
            id: "write",
            summary: "Create a file",
            approvalRequirement: .plan,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "out.txt", contents: "hello")
            ),
            postcondition: .fileContents("hello")
        )
        let approved = try await approve(action)
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("out.txt"))

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: ActionExecutionResult(action: action), context: .empty)
        guard case .unverified = status else {
            XCTFail("a transform without a bound receipt must not verify, got \(status)")
            return
        }
    }

    func testShellVerifiesDeclaredWorkspaceResult() async throws {
        let action = try shellAction()
        let approved = try await approve(action)
        try Data("expected".utf8).write(to: workspace.appendingPathComponent("result.txt"))

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: ActionExecutionResult(action: action), context: .empty)
        guard case .verified = status else {
            XCTFail("shell postcondition should verify from the workspace, got \(status)")
            return
        }
    }

    func testShellWithoutProducedFileIsUnverified() async throws {
        let action = try shellAction()
        let approved = try await approve(action)

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: ActionExecutionResult(action: action), context: .empty)
        guard case .unverified = status else {
            XCTFail("process exit alone must not verify a shell action, got \(status)")
            return
        }
    }

    func testComputerActionWithoutWorkerIsUnverified() async throws {
        let action = try ExecutableAction(
            id: "click",
            summary: "Click a control",
            approvalRequirement: .plan,
            operation: .computer(
                window: ExecutableAction.WindowIdentity(
                    bundleID: "com.example.Editor",
                    processID: 4242,
                    windowID: 1001,
                    connectionGeneration: 7
                ),
                command: .click(.windowPixels(x: 10, y: 10))
            ),
            postcondition: .visualChange(baselineSHA256: String(repeating: "a", count: 64))
        )
        let approved = try await approve(action)

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: ActionExecutionResult(action: action), context: .empty)
        guard case .unverified = status else {
            XCTFail("a computer action with no window reader must not verify, got \(status)")
            return
        }
    }

    func testIntegrationVerifiesWhenResponseEchoesWrittenContent() async throws {
        let action = try integrationAction()
        let approved = try await approve(action)
        let result = ActionExecutionResult(
            action: action,
            evidence: .integrationResponse(Data(#"{"ok":true,"text":"hello channel"}"#.utf8))
        )

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: result, context: .empty)
        guard case .verified = status else {
            XCTFail("an echoed integration write should verify, got \(status)")
            return
        }
    }

    func testIntegrationWithoutResponseOrEchoIsUnverified() async throws {
        let action = try integrationAction()
        let approved = try await approve(action)
        let verifier = CompositeActionVerifier(workspace: workspace, worker: nil)

        for result in [
            ActionExecutionResult(action: action),
            ActionExecutionResult(action: action, evidence: .integrationResponse(Data(#"{"ok":true}"#.utf8))),
        ] {
            let status = await verifier.verify(approvedAction: approved, result: result, context: .empty)
            guard case .unverified = status else {
                XCTFail("provider acceptance without an echoed write must not verify, got \(status)")
                return
            }
        }
    }

    func testAskUserAnswerIsItsOwnEvidence() async throws {
        let action = try ExecutableAction(
            id: "ask",
            summary: "Ask the user",
            approvalRequirement: .action,
            operation: .askUser(prompt: "Continue?", choices: ["Yes", "No"]),
            postcondition: .answered
        )
        let approved = try await approve(action)

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: ActionExecutionResult(action: action), context: .empty)
        guard case .verified = status else {
            XCTFail("an answered question should verify, got \(status)")
            return
        }
    }

    func testMismatchedResultIsUnverified() async throws {
        let action = try integrationAction()
        let approved = try await approve(action)
        let result = ActionExecutionResult(
            actionID: "someone-else",
            operation: action.operation
        )

        let status = await CompositeActionVerifier(workspace: workspace, worker: nil)
            .verify(approvedAction: approved, result: result, context: .empty)
        guard case .unverified = status else {
            XCTFail("a result for another action must not verify, got \(status)")
            return
        }
    }

    private func approve(_ action: ExecutableAction) async throws -> ApprovedExecutableAction {
        let plan = try ExecutionPlan(
            taskID: "task",
            goal: "goal",
            actions: [action],
            requestedScopes: action.operation.requiredScopes
        )
        let scope: ExecutionApprovalGrant.Scope = action.approvalRequirement == .plan
            ? .plan
            : .action(action.id)
        let grant = try await ExecutionApprovalRegistry().issue(plan: plan, scope: scope)
        return try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
    }

    private func shellAction() throws -> ExecutableAction {
        try ExecutableAction(
            id: "shell",
            summary: "Run a coding task",
            approvalRequirement: .plan,
            operation: .shell(
                workspace: workspace,
                executable: ExecutableAction.ExecutableIdentity(
                    path: URL(fileURLWithPath: "/usr/bin/true"),
                    version: "1",
                    sha256: String(repeating: "b", count: 64)
                ),
                confinement: .workspaceReadWrite,
                command: .codingTask(runtimeID: "test-runtime", prompt: "write result.txt")
            ),
            postcondition: .workspaceFileContents(path: "result.txt", contents: "expected")
        )
    }

    private func integrationAction() throws -> ExecutableAction {
        try ExecutableAction(
            id: "send",
            summary: "Send a message",
            approvalRequirement: .action,
            operation: .integration(
                accountID: "slack",
                command: .slackSendMessage(channelID: "C1", text: "hello channel")
            ),
            postcondition: .integrationResource(identifier: "C1", expectedText: "hello channel")
        )
    }
}
