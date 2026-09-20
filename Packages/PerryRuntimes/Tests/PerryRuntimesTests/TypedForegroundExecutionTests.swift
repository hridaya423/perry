import XCTest
import PerryCore
@testable import PerryRuntimes

final class TypedForegroundExecutionTests: XCTestCase {
    func testPlannedActionReachesTheExecutorWithExactIdentityFields() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/perry-typed-foreground")
        let action = try ExecutableAction(
            id: ActionID("write-report"),
            summary: "Write report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "report.txt", contents: "hello")
            ),
            postcondition: .fileContents("hello")
        )
        let plan = try ExecutionPlan(
            taskID: TaskID("typed-foreground-task"),
            goal: "Write report",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let executor = RecordingTypedExecutor()
        let provider = RuntimeProvider(
            planner: TypedPlanner(executionPlan: plan),
            descriptor: RuntimeProviderDescriptor(
                id: "typed-only",
                capabilities: RuntimeCapabilities(fileIO: true),
                operations: [.planning, .execution],
                installation: .notApplicable(.local),
                authentication: .notRequired,
                confinement: .workspace
            )
        )
        let registry = RuntimeProviderRegistry(providers: [provider])
        let route = registry.route(for: RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            requiredOperations: [.planning, .execution]
        ))
        let decision = try XCTUnwrap(route)

        let request = try PlanningRequest(
            goal: plan.goal,
            taskID: plan.taskID,
            workspace: workspace,
            context: .none
        )
        let planned = try await decision.provider.plan(request)

        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
        let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
        let result = try await executor.execute(approved)
        let received = await executor.received
        XCTAssertEqual(received?.id, action.id)
        XCTAssertEqual(received?.summary, action.summary)
        XCTAssertEqual(received?.timeout, action.timeout)
        XCTAssertEqual(received?.approvalRequirement, action.approvalRequirement)
        XCTAssertEqual(received?.idempotency, action.idempotency)
        XCTAssertEqual(received?.operation, action.operation)
        XCTAssertEqual(received?.postcondition, action.postcondition)
        XCTAssertEqual(result.actionID, action.id)
        XCTAssertEqual(result.operation, action.operation)
        XCTAssertEqual(planned.actions.map(\.id), [action.id])
    }
}

private struct TypedPlanner: TaskPlanner {
    let executionPlan: PerryRuntimes.ExecutionPlan
    let id = "typed-only"
    let capabilities = RuntimeCapabilities(fileIO: true)

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        executionPlan
    }
}

private actor RecordingTypedExecutor: ExecutableActionExecutor {
    private(set) var received: ExecutableAction?

    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        received = approvedAction.action
        return ActionExecutionResult(action: approvedAction.action)
    }
}
