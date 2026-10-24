import XCTest
@testable import PerryRuntimes
import PerryCore

final class WorkspaceFilePlanFabricatorTests: XCTestCase {
    func testPlansCanonicalFileRequestAsTypedPlan() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/perry-planner-typed")
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: #"create file "notes.txt" with "hello""#,
            workspace: workspace,
            taskID: "typed-file"
        )
        let plan = try XCTUnwrap(proposed)

        XCTAssertEqual(plan.taskID, TaskID("typed-file"))
        XCTAssertEqual(plan.goal, #"create file "notes.txt" with "hello""#)
        guard case .transform(let actionWorkspace, let command) = plan.actions[0].operation else {
            return XCTFail("expected a workspace transform")
        }
        XCTAssertEqual(actionWorkspace, workspace)
        guard case .createUTF8File(let path, let contents) = command else {
            return XCTFail("expected a UTF-8 file creation")
        }
        XCTAssertEqual(path, "notes.txt")
        XCTAssertEqual(contents, "hello")
    }

    func testMalformedFileRequestFailsWithoutLegacyFallback() async throws {
        do {
            _ = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
                goal: "create file named report.txt",
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-malformed"),
                taskID: "typed-malformed"
            )
            XCTFail("expected malformed typed file input to fail")
        } catch let error as PlanError {
            XCTAssertTrue(error.message.contains("needs one explicit request"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonFileRequestReturnsNilHonestly() async throws {
        for goal in ["click Save", "rename \"draft.txt\" to \"final.txt\"", "send an email"] {
            let plan = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
                goal: goal,
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-nonfile"),
                taskID: "non-file"
            )
            XCTAssertNil(plan, goal)
        }
    }

    func testCanonicalFileCreationPreservesNoiseInContents() async throws {
        let goal = #"create file "notes.txt" with "slack remote gui rename folder trash click Save""#
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: goal,
            workspace: URL(fileURLWithPath: "/tmp/perry-planner-precedence"),
            taskID: "typed-precedence"
        )
        let plan = try XCTUnwrap(proposed)

        XCTAssertEqual(plan.actions.count, 1)
        guard case .transform(_, .createUTF8File(let path, let contents)) = plan.actions[0].operation else {
            return XCTFail("expected a typed file creation action")
        }
        XCTAssertEqual(path, "notes.txt")
        XCTAssertEqual(contents, "slack remote gui rename folder trash click Save")
    }

    func testCanonicalCompoundCreationFailsClosedBeforeOtherRouting() async {
        let goal = #"create file "notes.txt" with "slack click Save" then move it to trash"#
        do {
            _ = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
                goal: goal,
                workspace: URL(fileURLWithPath: "/tmp/perry-planner-compound"),
                taskID: "typed-compound"
            )
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
            do {
                _ = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
                    goal: goal,
                    workspace: URL(fileURLWithPath: "/tmp/perry-planner-unquoted"),
                    taskID: "typed-unquoted"
                )
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
            do {
                _ = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
                    goal: goal,
                    workspace: URL(fileURLWithPath: "/tmp/perry-planner-unsafe"),
                    taskID: "typed-unsafe"
                )
                XCTFail("expected unsafe filename to fail closed: \(name)")
            } catch {
            }
        }
    }

    func testTypedCanonicalCreationPreservesFilenameWhitespace() async throws {
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
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
}
