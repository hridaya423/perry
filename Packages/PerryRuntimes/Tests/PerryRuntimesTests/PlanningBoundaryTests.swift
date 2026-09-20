import Foundation
import XCTest
import PerryCore
@testable import PerryRuntimes

final class PlanningBoundaryTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/tmp/perry-planning-boundary")

    func testProviderRejectsTypedPlanForWrongTaskID() async throws {
        let request = try makeRequest()
        let plan = try makePlan(taskID: "different-task", goal: request.goal, workspace: request.workspace)
        let provider = makeProvider(planner: FixedPlanner(result: plan))

        try await assertTypedPlanRejected(provider, request: request, reason: "task ID does not match the planning request")
    }

    func testProviderRejectsTypedPlanForWrongGoal() async throws {
        let request = try makeRequest()
        let plan = try makePlan(taskID: request.taskID, goal: "different goal", workspace: request.workspace)
        let provider = makeProvider(planner: FixedPlanner(result: plan))

        try await assertTypedPlanRejected(provider, request: request, reason: "goal does not match the planning request")
    }

    func testProviderRejectsTypedPlanForDescendantWorkspace() async throws {
        let request = try makeRequest()
        let plan = try makePlan(
            taskID: request.taskID,
            goal: request.goal,
            workspace: request.workspace.appendingPathComponent("nested")
        )
        let provider = makeProvider(planner: FixedPlanner(result: plan))

        try await assertTypedPlanRejected(provider, request: request, reason: "workspace does not match the planning request")
    }

    func testProviderUsesWorkspaceRuntimeNormalizationForTmpAlias() async throws {
        let rawWorkspace = URL(fileURLWithPath: "/tmp/perry-planning-boundary/../perry-planning-boundary")
        let request = try PlanningRequest(
            goal: "write report",
            taskID: "requested-task",
            workspace: rawWorkspace,
            context: .none
        )
        let expectedWorkspace = rawWorkspace.resolvingSymlinksInPath().standardizedFileURL
        let plan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: request.workspace)
        let provider = makeProvider(planner: FixedPlanner(result: plan))

        XCTAssertEqual(Array(request.workspace.path.utf8), Array(expectedWorkspace.path.utf8))
        XCTAssertEqual(Array(request.withScreenContext(.empty).workspace.path.utf8), Array(request.workspace.path.utf8))
        let returned = try await provider.plan(request)
        XCTAssertEqual(returned.planID, plan.planID)
    }

    func testProviderAcceptsUnicodeSpellingsWithIdenticalStandardizedWorkspaceBytes() async throws {
        let composedWorkspace = URL(fileURLWithPath: "/tmp/perry-planning-é")
        let decomposedWorkspace = URL(fileURLWithPath: "/tmp/perry-planning-e\u{301}")
        let request = try PlanningRequest(
            goal: "write report",
            taskID: "requested-task",
            workspace: composedWorkspace,
            context: .none
        )
        let plan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: decomposedWorkspace)
        let provider = makeProvider(planner: FixedPlanner(result: plan))

        XCTAssertEqual(Array(request.workspace.path.utf8), Array(decomposedWorkspace.standardizedFileURL.path.utf8))
        let returned = try await provider.plan(request)
        XCTAssertEqual(returned.planID, plan.planID)
    }

    func testProviderRejectsWorkspaceAliasAndAcceptsPinnedTargetAfterAliasRetargeting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-planning-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let replacement = directory.appendingPathComponent("replacement")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let request = try PlanningRequest(goal: "write report", taskID: "alias-task", workspace: alias, context: .none)
        XCTAssertEqual(request.workspace.lastPathComponent, "target")
        let aliasPlan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: alias)
        try await assertTypedPlanRejected(
            makeProvider(planner: FixedPlanner(result: aliasPlan)),
            request: request,
            reason: "workspace does not match the planning request"
        )

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let contextualRequest = request.withScreenContext(.empty)
        XCTAssertEqual(Array(contextualRequest.workspace.path.utf8), Array(request.workspace.path.utf8))
        let replacementPlan = try makePlan(
            taskID: request.taskID,
            goal: request.goal,
            workspace: replacement.resolvingSymlinksInPath().standardizedFileURL
        )
        try await assertTypedPlanRejected(
            makeProvider(planner: FixedPlanner(result: replacementPlan)),
            request: contextualRequest,
            reason: "workspace does not match the planning request"
        )
        let pinnedPlan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: request.workspace)
        let returned = try await makeProvider(planner: FixedPlanner(result: pinnedPlan)).plan(contextualRequest)
        XCTAssertEqual(returned.planID, pinnedPlan.planID)
    }

    func testProviderChecksCancellationBeforeCanonicalPlannerInvocation() async throws {
        let request = try makeRequest()
        let probe = PlanningProbe()
        let gate = PlanningGate()
        let plan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: request.workspace)
        let provider = makeProvider(planner: CountingPlanner(result: plan, probe: probe))
        let operation = Task {
            await gate.wait()
            return try await provider.plan(request)
        }

        var gateReady = false
        for _ in 0..<2_000 {
            if await gate.waiting {
                gateReady = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(gateReady)
        operation.cancel()
        await gate.open()
        do {
            _ = try await operation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        let callCount = await probe.count
        XCTAssertEqual(callCount, 0)
    }

    func testProviderPropagatesCancellationWhileCanonicalPlannerIsRunning() async throws {
        let request = try makeRequest()
        let probe = PlanningProbe()
        let plan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: request.workspace)
        let provider = makeProvider(planner: BlockingPlanner(result: plan, probe: probe))
        let operation = Task { try await provider.plan(request) }

        var started = false
        for _ in 0..<2_000 {
            if await probe.count > 0 {
                started = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(started)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }

    func testLatencyUpdatePreservesCanonicalPlanner() async throws {
        let request = try makeRequest()
        let plan = try makePlan(taskID: request.taskID, goal: request.goal, workspace: request.workspace)
        let provider = makeProvider(planner: FixedPlanner(result: plan), id: "provider.latency")
        var registry = RuntimeProviderRegistry(providers: [provider])

        XCTAssertTrue(registry.recordLatency(for: provider.id, milliseconds: 12))
        let updated = try XCTUnwrap(registry.provider(for: provider.id))
        let returnedPlan = try await updated.plan(request)
        XCTAssertEqual(updated.descriptor.measuredLatency?.milliseconds, 12)
        XCTAssertEqual(returnedPlan.planID, plan.planID)
    }

    private func makeRequest(
        goal: String = "write report",
        context: PlanningContext = .none
    ) throws -> PlanningRequest {
        try PlanningRequest(goal: goal, taskID: "requested-task", workspace: workspace, context: context)
    }

    private func makePlan(taskID: TaskID, goal: String, workspace: URL) throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: "write",
            summary: "Write report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "report.txt", contents: "value")
            ),
            postcondition: .fileContents("value")
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func makeProvider(
        planner: any TaskPlanner,
        id: String = "provider.typed"
    ) -> RuntimeProvider {
        RuntimeProvider(
            planner: planner,
            descriptor: RuntimeProviderDescriptor(
                id: id,
                capabilities: RuntimeCapabilities(fileIO: true),
                operations: [.planning],
                installation: .notApplicable(.local),
                authentication: .authenticated,
                confinement: .workspace
            )
        )
    }

    private func assertTypedPlanRejected(
        _ provider: RuntimeProvider,
        request: PlanningRequest,
        reason: String
    ) async throws {
        do {
            _ = try await provider.plan(request)
            XCTFail("expected typed plan rejection")
        } catch let error as PlanningError {
            guard case .typedPlanRejected(let actualReason) = error else {
                return XCTFail("unexpected planning error: \(error)")
            }
            XCTAssertEqual(actualReason, reason)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private struct FixedPlanner: TaskPlanner {
    let id = "fixed.planner"
    let capabilities = RuntimeCapabilities(fileIO: true)
    let result: ExecutionPlan

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        result
    }
}

private struct CountingPlanner: TaskPlanner {
    let id = "counting.planner"
    let capabilities = RuntimeCapabilities(fileIO: true)
    let result: ExecutionPlan
    let probe: PlanningProbe

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        await probe.record()
        return result
    }
}

private struct BlockingPlanner: TaskPlanner {
    let id = "blocking.planner"
    let capabilities = RuntimeCapabilities(fileIO: true)
    let result: ExecutionPlan
    let probe: PlanningProbe

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        await probe.record()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return result
    }
}

private actor PlanningProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor PlanningGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        waiting = false
        continuation?.resume()
        continuation = nil
    }
}
