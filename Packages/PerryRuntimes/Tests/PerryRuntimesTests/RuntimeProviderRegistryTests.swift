import XCTest
@testable import PerryRuntimes
import PerryCore

final class RuntimeProviderRegistryTests: XCTestCase {
    private let measuredAt = Date(timeIntervalSince1970: 123)

    func testDescriptorAndPlannerPreserveRuntimeBoundary() async throws {
        let planner = StubPlanner(
            id: "underlying",
            capabilities: RuntimeCapabilities(fileIO: true, latencyClass: .fast)
        )
        let descriptor = RuntimeProviderDescriptor(
            id: "provider.stub",
            displayName: "Stub provider",
            kind: .custom,
            capabilities: planner.capabilities,
            installation: .notApplicable(.local),
            authentication: .authenticated,
            health: .healthy,
            confinement: .workspace,
            measuredLatency: RuntimeLatencyMeasurement(milliseconds: 18, measuredAt: measuredAt),
            priority: 4
        )
        let provider = RuntimeProvider(planner: planner, descriptor: descriptor)

        XCTAssertEqual(provider.descriptor.identity.displayName, "Stub provider")
        XCTAssertEqual(provider.descriptor.authentication, .authenticated)
        XCTAssertEqual(provider.descriptor.health, .healthy)
        XCTAssertEqual(provider.descriptor.confinement, .workspace)
        XCTAssertEqual(provider.descriptor.measuredLatency?.milliseconds, 18)

        let request = try makeRequest()
        let plan = try await provider.plan(request)
        XCTAssertEqual(plan.taskID, request.taskID)
    }

    func testRoutingRequiresCapabilitiesAndUsesMeasuredLatency() {
        var registry = RuntimeProviderRegistry()
        registry.register(makeProvider(
            id: "provider.slower",
            capabilities: RuntimeCapabilities(fileIO: true, latencyClass: .medium),
            measuredMilliseconds: 90
        ))
        registry.register(makeProvider(
            id: "provider.faster",
            capabilities: RuntimeCapabilities(fileIO: true, latencyClass: .slow),
            measuredMilliseconds: 20
        ))

        let fileRoute = registry.route(for: RuntimeRouteRequest(requiredCapabilities: [.fileIO]))
        XCTAssertEqual(fileRoute?.providerID, "provider.faster")

        let guiRoute = registry.route(for: RuntimeRouteRequest(requiredCapabilities: [.guiGrounding]))
        XCTAssertNil(guiRoute)
        let explanation = registry.explain(RuntimeRouteRequest(requiredCapabilities: [.guiGrounding]))
        XCTAssertTrue(explanation.rejectedProviders.allSatisfy { $0.reason.contains("guiGrounding") })
    }

    func testRoutingRejectsProviderThatHasNotProvedTheRequestedOperation() {
        let registry = RuntimeProviderRegistry(providers: [
            makeProvider(
                id: "provider.planner",
                capabilities: RuntimeCapabilities(fileIO: true),
                operations: [.planning],
                measuredMilliseconds: 10
            ),
        ])

        let decision = registry.route(for: RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            requiredOperations: [.execution]
        ))

        XCTAssertNil(decision)
        XCTAssertTrue(registry.explain(RuntimeRouteRequest(requiredOperations: [.execution]))
            .rejectedProviders
            .contains { $0.reason.contains("missing operations: execution") })
    }

    func testRoutingRejectsUnverifiedInstallationIdentity() {
        let provider = RuntimeProvider(
            planner: StubPlanner(
                id: "provider.unverified",
                capabilities: RuntimeCapabilities(fileIO: true)
            ),
            descriptor: RuntimeProviderDescriptor(
                id: "provider.unverified",
                capabilities: RuntimeCapabilities(fileIO: true),
                installation: .unverified(reason: "checksum mismatch"),
                authentication: .authenticated,
                confinement: .workspace
            )
        )
        let registry = RuntimeProviderRegistry(providers: [provider])

        XCTAssertNil(registry.route(for: RuntimeRouteRequest()))
        XCTAssertTrue(registry.explain(RuntimeRouteRequest())
            .rejectedProviders
            .contains { $0.reason.contains("checksum mismatch") })
    }

    func testProviderCanExposePlannerWithoutImplementingExecution() async throws {
        let planner = StubPlanner(id: "provider.planner")
        let provider = RuntimeProvider(
            planner: planner,
            descriptor: RuntimeProviderDescriptor(
                id: planner.id,
                capabilities: planner.capabilities,
                operations: [.planning],
                installation: .notApplicable(.local),
                authentication: .authenticated,
                confinement: .readOnly
            )
        )

        let request = try makeRequest()
        let plan = try await provider.plan(request)
        XCTAssertEqual(plan.taskID, request.taskID)
    }

    func testRoutingTieBreakIsIndependentOfRegistrationOrder() {
        let first = makeProvider(
            id: "provider.zeta",
            capabilities: RuntimeCapabilities(fileIO: true),
            measuredMilliseconds: 40
        )
        let second = makeProvider(
            id: "provider.alpha",
            capabilities: RuntimeCapabilities(fileIO: true),
            measuredMilliseconds: 40
        )
        let request = RuntimeRouteRequest(requiredCapabilities: [.fileIO])

        let firstRegistry = RuntimeProviderRegistry(providers: [first, second])
        let secondRegistry = RuntimeProviderRegistry(providers: [second, first])

        XCTAssertEqual(firstRegistry.route(for: request)?.providerID, "provider.alpha")
        XCTAssertEqual(secondRegistry.route(for: request)?.providerID, "provider.alpha")
    }

    func testPreferredProviderFallsBackWithAuthenticationReason() {
        let registry = RuntimeProviderRegistry(providers: [
            makeProvider(
                id: "provider.cloud",
                capabilities: RuntimeCapabilities(fileIO: true),
                authentication: .missing,
                measuredMilliseconds: 10
            ),
            makeProvider(
                id: "provider.local",
                capabilities: RuntimeCapabilities(fileIO: true),
                confinement: .workspace,
                measuredMilliseconds: 30
            ),
        ])

        let request = RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            preferredProviderID: "provider.cloud",
            requiredConfinement: .workspace
        )
        let decision = registry.route(for: request)

        XCTAssertEqual(decision?.providerID, "provider.local")
        XCTAssertTrue(decision?.usedFallback == true)
        XCTAssertTrue(decision?.fallbackReason?.contains("provider.cloud") == true)
        XCTAssertTrue(decision?.fallbackReason?.contains("authentication is missing") == true)
    }

    func testHealthConfinementAndLatencyAreEligibilityGates() {
        var registry = RuntimeProviderRegistry(providers: [
            makeProvider(
                id: "provider.unhealthy",
                capabilities: RuntimeCapabilities(fileIO: true),
                health: .unavailable(reason: "probe timed out"),
                confinement: .workspace,
                measuredMilliseconds: 5
            ),
            makeProvider(
                id: "provider.open",
                capabilities: RuntimeCapabilities(fileIO: true),
                confinement: .unconfined,
                measuredMilliseconds: 5
            ),
        ])

        let noWorkspaceRoute = registry.route(for: RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            requiredConfinement: .workspace
        ))
        XCTAssertNil(noWorkspaceRoute)

        registry.register(makeProvider(
            id: "provider.safe",
            capabilities: RuntimeCapabilities(fileIO: true),
            confinement: .workspace,
            measuredMilliseconds: 60
        ))
        let route = registry.route(for: RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            requiredConfinement: .workspace,
            maximumLatencyMilliseconds: 50
        ))
        XCTAssertNil(route)
        let explanation = registry.explain(RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            requiredConfinement: .workspace,
            maximumLatencyMilliseconds: 50
        ))
        XCTAssertTrue(explanation.rejectedProviders.contains { $0.providerID == "provider.safe" && $0.reason.contains("latency") })
    }

    func testMaximumLatencyRejectsUnmeasuredPreferredProvider() {
        let unmeasured = RuntimeProvider(
            planner: StubPlanner(
                id: "provider.unmeasured",
                capabilities: RuntimeCapabilities(fileIO: true)
            ),
            descriptor: RuntimeProviderDescriptor(
                id: "provider.unmeasured",
                capabilities: RuntimeCapabilities(fileIO: true),
                installation: .notApplicable(.local),
                authentication: .authenticated
            )
        )
        let registry = RuntimeProviderRegistry(providers: [
            unmeasured,
            makeProvider(
                id: "provider.measured",
                capabilities: RuntimeCapabilities(fileIO: true),
                measuredMilliseconds: 20
            ),
        ])

        let decision = registry.route(for: RuntimeRouteRequest(
            requiredCapabilities: [.fileIO],
            preferredProviderID: "provider.unmeasured",
            maximumLatencyMilliseconds: 50
        ))

        XCTAssertEqual(decision?.providerID, "provider.measured")
        XCTAssertTrue(decision?.fallbackReason?.contains("latency is not measured") == true)
    }

    func testRecordedLatencyChangesMeasuredRouting() {
        var registry = RuntimeProviderRegistry(providers: [
            makeProvider(
                id: "provider.a",
                capabilities: RuntimeCapabilities(fileIO: true),
                measuredMilliseconds: 80
            ),
            makeProvider(
                id: "provider.b",
                capabilities: RuntimeCapabilities(fileIO: true),
                measuredMilliseconds: 40
            ),
        ])
        let request = RuntimeRouteRequest(requiredCapabilities: [.fileIO])

        XCTAssertEqual(registry.route(for: request)?.providerID, "provider.b")
        XCTAssertTrue(registry.recordLatency(for: "provider.a", milliseconds: 10, measuredAt: measuredAt))
        XCTAssertEqual(registry.route(for: request)?.providerID, "provider.a")
        XCTAssertEqual(registry.provider(for: "provider.a")?.descriptor.measuredLatency?.milliseconds, 10)
    }

    private func makeRequest() throws -> PlanningRequest {
        try PlanningRequest(
            goal: "inspect",
            taskID: "registry-test",
            workspace: URL(fileURLWithPath: "/tmp/perry-registry-test"),
            context: .none
        )
    }

    private func makeProvider(
        id: String,
        capabilities: RuntimeCapabilities,
        operations: Set<RuntimeOperation> = [.planning, .execution],
        authentication: RuntimeAuthenticationStatus = .authenticated,
        health: RuntimeHealthStatus = .healthy,
        confinement: RuntimeConfinement = .unconfined,
        measuredMilliseconds: Double,
        priority: Int = 0
    ) -> RuntimeProvider {
        let planner = StubPlanner(id: id, capabilities: capabilities)
        let descriptor = RuntimeProviderDescriptor(
            id: id,
            capabilities: capabilities,
            operations: operations,
            installation: .notApplicable(.local),
            authentication: authentication,
            health: health,
            confinement: confinement,
            measuredLatency: RuntimeLatencyMeasurement(milliseconds: measuredMilliseconds, measuredAt: measuredAt),
            priority: priority
        )
        return RuntimeProvider(planner: planner, descriptor: descriptor)
    }
}

private struct StubPlanner: TaskPlanner {
    let id: String
    var capabilities = RuntimeCapabilities(fileIO: true)

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        let action = try ExecutableAction(
            id: "stub-action",
            summary: request.goal,
            approvalRequirement: .action,
            operation: .transform(
                workspace: request.workspace,
                command: .createUTF8File(path: "stub.txt", contents: "stub")
            ),
            postcondition: .fileContents("stub")
        )
        return try ExecutionPlan(
            taskID: request.taskID,
            goal: request.goal,
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}
