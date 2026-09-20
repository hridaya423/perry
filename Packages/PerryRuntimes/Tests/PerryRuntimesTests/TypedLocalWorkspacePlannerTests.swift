import XCTest
@testable import PerryRuntimes
import PerryCore

final class TypedLocalWorkspacePlannerTests: XCTestCase {
    func testCreateFileGoalBuildsCanonicalExecutionPlanAndPreservesContentsBytes() async throws {
        let runtime = LocalTaskPlannerRuntime()
        let workspace = URL(fileURLWithPath: "/tmp/perry-workspace-\(UUID().uuidString)", isDirectory: true)
        let taskID = TaskID("typed-workspace-task")
        let contents = "  e\u{301}\r\n\t🍐\n  "
        let goal = "create file \"report.txt\" with \"\(contents)\""

        let proposed = try await runtime.workspaceExecutionPlan(
            goal: goal,
            workspace: workspace,
            taskID: taskID
        )
        let plan = try XCTUnwrap(proposed)

        XCTAssertEqual(plan.taskID, taskID)
        XCTAssertEqual(plan.goal, goal)
        XCTAssertEqual(plan.requestedScopes, [.workspaceWrite])
        let action = try XCTUnwrap(plan.actions.first)
        XCTAssertEqual(action.approvalRequirement, .action)
        guard case .transform(let boundWorkspace, let command) = action.operation,
              case .createUTF8File(let path, let encodedContents) = command else {
            return XCTFail("expected one typed workspace file action")
        }
        XCTAssertEqual(boundWorkspace.standardizedFileURL.path, workspace.standardizedFileURL.path)
        XCTAssertEqual(path, "report.txt")
        XCTAssertEqual(Array(encodedContents.utf8), Array(contents.utf8))
        guard case .fileContents(let expectedContents) = action.postcondition else {
            return XCTFail("expected a file contents postcondition")
        }
        XCTAssertEqual(Array(expectedContents.utf8), Array(contents.utf8))
    }

    func testWorkspacePlanDeclinesUnsupportedFileRequestsWithoutPartialWork() async throws {
        let runtime = LocalTaskPlannerRuntime()
        let workspace = URL(fileURLWithPath: "/tmp/perry-workspace-\(UUID().uuidString)", isDirectory: true)

        for goal in [
            "create a folder named reports",
            "rename \"draft.txt\" to \"final.txt\"",
            "move \"draft.txt\" to Trash",
            "create \"draft.txt\" with \"draft\", then move that file to Trash",
        ] {
            let proposed = try await runtime.workspaceExecutionPlan(
                goal: goal,
                workspace: workspace,
                taskID: TaskID()
            )
            XCTAssertNil(proposed, goal)
        }
    }

    func testCommandWordsInsideContentsRemainLiteralText() async throws {
        let contents = "rename the folder, then delete the file and move it to trash"
        let proposed = try await LocalTaskPlannerRuntime().workspaceExecutionPlan(
            goal: "create file \"instructions.txt\" with \"\(contents)\"",
            workspace: URL(fileURLWithPath: "/tmp/perry-literal-contents"),
            taskID: "literal-contents"
        )
        let plan = try XCTUnwrap(proposed)
        XCTAssertEqual(plan.actions.count, 1)
        guard case .transform(_, .createUTF8File(let path, let actualContents)) = plan.actions[0].operation else {
            return XCTFail("Expected a file creation action")
        }
        XCTAssertEqual(path, "instructions.txt")
        XCTAssertEqual(actualContents, contents)
    }

    func testWorkspacePlanRejectsCompoundCreationInsteadOfDroppingActions() async throws {
        let runtime = LocalTaskPlannerRuntime()
        let workspace = URL(fileURLWithPath: "/tmp/perry-workspace-\(UUID().uuidString)", isDirectory: true)
        let goal = #"create file "a.txt" with "A" and create file "b.txt" with "B""#
        do {
            _ = try await runtime.workspaceExecutionPlan(
                goal: goal,
                workspace: workspace,
                taskID: TaskID()
            )
            XCTFail("Compound creation was accepted")
        } catch is PlanError {
        }
    }

    func testWorkspacePlanRejectsContentsAboveUTF8ByteLimit() async throws {
        let runtime = LocalTaskPlannerRuntime()
        let workspace = URL(fileURLWithPath: "/tmp/perry-planner-size")
        let atLimit = String(repeating: "🍐", count: WorkspaceFileRuntime.maximumFileCreationBytes / 4)
        let accepted = try await runtime.workspaceExecutionPlan(goal: "create file \"report.txt\" with \"\(atLimit)\"", workspace: workspace, taskID: "accepted")
        XCTAssertNotNil(accepted)
        do {
            _ = try await runtime.workspaceExecutionPlan(
                goal: "create file \"report.txt\" with \"\(atLimit)x\"", workspace: workspace, taskID: "rejected"
            )
            XCTFail("Oversized creation was accepted")
        } catch is PlanError {
        }
    }

    @MainActor
    func testLargePlanAllowsMainActorToProcessFeedback() async throws {
        let contents = String(repeating: "🍐", count: WorkspaceFileRuntime.maximumFileCreationBytes / 4)
        let goal = "create file \"report.txt\" with \"\(contents)\""
        let started = expectation(description: "planning started")
        let start = ContinuousClock.now
        let planning = Task { @MainActor in
            started.fulfill()
            return try await LocalTaskPlannerRuntime().workspaceExecutionPlan(
                goal: goal, workspace: URL(fileURLWithPath: "/tmp/perry-planner-feedback"), taskID: "feedback"
            )
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let proposed = try await planning.value
        XCTAssertNotNil(proposed)
    }
}
