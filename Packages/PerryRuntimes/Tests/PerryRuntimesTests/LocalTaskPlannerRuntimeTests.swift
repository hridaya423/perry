import XCTest
@testable import PerryRuntimes
import PerryCore

final class LocalTaskPlannerRuntimeTests: XCTestCase {
    func testPlansCanonicalFileRequestAsTypedPlanWithoutScreenContext() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/perry-planner-typed")
        let request = try PlanningRequest(
            goal: #"create file "notes.txt" with "hello""#,
            taskID: "typed-file",
            workspace: workspace,
            context: .none
        )
        let plan = try await LocalTaskPlannerRuntime().plan(request)

        XCTAssertEqual(plan.taskID, request.taskID)
        XCTAssertEqual(plan.goal, request.goal)
        guard case .transform(let actionWorkspace, let command) = plan.actions[0].operation else {
            return XCTFail("expected a workspace transform")
        }
        XCTAssertEqual(actionWorkspace, request.workspace)
        guard case .createUTF8File(let path, let contents) = command else {
            return XCTFail("expected a UTF-8 file creation")
        }
        XCTAssertEqual(path, "notes.txt")
        XCTAssertEqual(contents, "hello")
    }

    func testTypedMalformedFileRequestFailsWithoutLegacyFallback() async throws {
        let request = try PlanningRequest(
            goal: "create file named report.txt",
            taskID: "typed-malformed",
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-malformed"),
            context: .screen(.empty)
        )

        do {
            _ = try await LocalTaskPlannerRuntime().plan(request)
            XCTFail("expected malformed typed file input to fail")
        } catch let error as PlanError {
            XCTAssertTrue(error.message.contains("needs one explicit request"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonFileRequestFailsHonestly() async throws {
        for goal in ["click Save", "rename \"draft.txt\" to \"final.txt\"", "send an email"] {
            let request = try PlanningRequest(
                goal: goal,
                taskID: "non-file",
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-nonfile"),
                context: .none
            )
            do {
                _ = try await LocalTaskPlannerRuntime().plan(request)
                XCTFail("expected non-file request to fail: \(goal)")
            } catch let error as PlanError {
                XCTAssertTrue(error.message.contains("workspace file requests"), goal)
            } catch {
                XCTFail("unexpected error for \(goal): \(error)")
            }
        }
    }

    func testCanonicalFileCreationIgnoresScreenContextNoise() async throws {
        let goal = #"create file "notes.txt" with "slack remote gui rename folder trash click Save""#
        let request = try PlanningRequest(
            goal: goal,
            taskID: "typed-precedence",
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-precedence"),
            context: .screen(ScreenContext(
                accessibilitySnapshot: "w/window:0/button:1 button Save",
                remoteIntegrationContext: "- slack"
            ))
        )
        let plan = try await LocalTaskPlannerRuntime().plan(request)

        XCTAssertEqual(plan.actions.count, 1)
        guard case .transform(_, .createUTF8File(let path, let contents)) = plan.actions[0].operation else {
            return XCTFail("expected a typed file creation action")
        }
        XCTAssertEqual(path, "notes.txt")
        XCTAssertEqual(contents, "slack remote gui rename folder trash click Save")
    }

    func testCanonicalCompoundCreationFailsClosedBeforeOtherRouting() async {
        let goal = #"create file "notes.txt" with "slack click Save" then move it to trash"#
        let request = try! PlanningRequest(
            goal: goal,
            taskID: "typed-compound",
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-compound"),
            context: .none
        )

        do {
            _ = try await LocalTaskPlannerRuntime().plan(request)
            XCTFail("expected compound canonical creation to fail closed")
        } catch let error as PlanError {
            XCTAssertTrue(error.message.contains("Compound requests require another planner"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnquotedCreationWithContentsFailsClosed() async {
        for goal in [
            "create file report.txt with \"hello\"",
            "create file report.txt with hello"
        ] {
            let request = try! PlanningRequest(
                goal: goal,
                taskID: "typed-unquoted",
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-unquoted"),
                context: .none
            )
            do {
                _ = try await LocalTaskPlannerRuntime().plan(request)
                XCTFail("expected explicit content syntax to fail closed: \(goal)")
            } catch let error as PlanError {
                XCTAssertTrue(error.message.contains("needs one explicit request"), goal)
            } catch {
                XCTFail("unexpected error for \(goal): \(error)")
            }
        }
    }

    func testCanonicalCreationRejectsEscapingFilename() async {
        for name in ["../report.txt", "/tmp/report.txt"] {
            let goal = "create file \"\(name)\" with \"hello\""
            let request = try! PlanningRequest(
                goal: goal,
                taskID: "typed-unsafe",
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-unsafe"),
                context: .none
            )
            do {
                _ = try await LocalTaskPlannerRuntime().plan(request)
                XCTFail("expected unsafe filename to fail closed: \(name)")
            } catch {
            }
        }
    }

    func testTypedCanonicalCreationPreservesFilenameWhitespace() async throws {
        let proposed = try await LocalTaskPlannerRuntime().workspaceExecutionPlan(
            goal: #"create file " report.txt " with "hello""#,
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-whitespace"),
            taskID: "typed-whitespace"
        )
        let plan = try XCTUnwrap(proposed)
        guard case .transform(_, .createUTF8File(let path, let contents)) = plan.actions[0].operation else {
            return XCTFail("expected a typed file creation action")
        }
        XCTAssertEqual(path, " report.txt ")
        XCTAssertEqual(contents, "hello")
    }

    func testWorkspaceExecutionPlanReturnsNilForNonFileGoals() async throws {
        let plan = try await LocalTaskPlannerRuntime().workspaceExecutionPlan(
            goal: "organize the desktop",
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-nil"),
            taskID: "typed-nil"
        )
        XCTAssertNil(plan)
    }
}
