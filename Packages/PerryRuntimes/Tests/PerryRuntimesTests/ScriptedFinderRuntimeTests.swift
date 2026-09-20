import XCTest
@testable import PerryRuntimes
import PerryCore

final class ScriptedFinderRuntimeTests: XCTestCase {
    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-scripted-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    func testPlanProducesTypedWorkspaceCreatesBoundToRequest() async throws {
        let runtime = ScriptedFinderRuntime()
        let request = try PlanningRequest(
            goal: "demo create",
            taskID: TaskID("scripted"),
            workspace: workDirectory,
            context: .none
        )
        let plan = try await runtime.plan(request)
        XCTAssertEqual(plan.taskID, request.taskID)
        XCTAssertEqual(plan.goal, request.goal)
        XCTAssertEqual(plan.actions.count, 3)
        for action in plan.actions {
            guard case .transform(let workspace, let command) = action.operation,
                  case .createUTF8File = command else {
                return XCTFail("expected workspace create actions, got \(action.operation)")
            }
            XCTAssertEqual(workspace.standardizedFileURL, request.workspace)
            XCTAssertEqual(action.approvalRequirement, .action)
        }
    }

    func testFullExecutionCreatesAllFilesOnDisk() async throws {
        let runtime = ScriptedFinderRuntime()
        let request = try PlanningRequest(
            goal: "demo create",
            taskID: TaskID("scripted"),
            workspace: workDirectory,
            context: .none
        )
        let plan = try await runtime.plan(request)
        let executor = WorkspaceFileRuntime(baseURL: workDirectory)

        for action in plan.actions {
            let grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
            let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
            _ = try await executor.execute(approved)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path).sorted()
        XCTAssertEqual(contents, ScriptedFinderRuntime.demoFileNames)
    }
}
