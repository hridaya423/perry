import XCTest
import PerryCore
import PerryRuntimes
@testable import Perry

@MainActor
final class ProductionRuntimeSelectorTests: XCTestCase {
    func testFileExecutionRequirementsOverridePreferredDirectProvider() throws {
        let direct = RuntimeProvider(
            planner: SelectorStubRuntime(id: "direct.openai"),
            descriptor: RuntimeProviderDescriptor(
                id: "direct.openai",
                capabilities: RuntimeCapabilities(remoteIntegrations: true),
                operations: [.planning],
                installation: .notApplicable(.directAPI),
                authentication: .configured,
                confinement: .readOnly,
                priority: 0
            )
        )
        let workspace = RuntimeProvider(
            planner: WorkspaceFilePlanner(),
            descriptor: RuntimeProviderDescriptor(
                id: "local.workspace-files",
                capabilities: RuntimeCapabilities(fileIO: true, latencyClass: .fast),
                operations: [.planning, .execution],
                installation: .notApplicable(.local),
                authentication: .notRequired,
                confinement: .workspace,
                priority: 110
            )
        )
        let registry = RuntimeProviderRegistry(providers: [direct, workspace])

        let fileSelection = ProductionRuntimeSelector().select(
            from: registry,
            preferredProviderID: "direct.openai",
            requiredCapabilities: [.fileIO],
            requiredOperations: [.planning, .execution]
        )
        XCTAssertEqual(fileSelection?.providerID, "local.workspace-files")

        let remoteSelection = ProductionRuntimeSelector().select(
            from: registry,
            preferredProviderID: "direct.openai",
            requiredCapabilities: [.remoteIntegrations]
        )
        XCTAssertEqual(remoteSelection?.providerID, "direct.openai")
    }

    func testRejectsUnauthenticatedAndUnconfinedProviders() {
        let registry = RuntimeProviderRegistry(providers: [
            provider(id: "missing-auth", authentication: .missing, confinement: .workspace),
            provider(id: "unconfined", authentication: .authenticated, confinement: .unconfined),
        ])

        XCTAssertNil(ProductionRuntimeSelector().select(from: registry))
    }

    func testFallsBackToEligibleBoundedProviderWithReason() {
        let registry = RuntimeProviderRegistry(providers: [
            provider(id: "preferred", authentication: .missing, confinement: .readOnly),
            provider(id: "local", authentication: .notRequired, confinement: .workspace),
        ])

        let selection = ProductionRuntimeSelector().select(
            from: registry,
            preferredProviderID: "preferred"
        )

        XCTAssertEqual(selection?.providerID, "local")
        XCTAssertTrue(selection?.explanation.fallbackReason?.contains("authentication is missing") == true)
        XCTAssertEqual(
            selection?.routingSummary,
            "Selected local. preferred provider preferred was not eligible: authentication is missing."
        )
    }

    func testAcceptsPlannerOnlyProviderForProductionPlanning() {
        let runtime = SelectorStubRuntime(id: "planner")
        let registry = RuntimeProviderRegistry(providers: [
            RuntimeProvider(
                planner: runtime,
                descriptor: RuntimeProviderDescriptor(
                    id: runtime.id,
                    capabilities: runtime.capabilities,
                    operations: [.planning],
                    installation: .notApplicable(.local),
                    authentication: .authenticated,
                    confinement: .readOnly
                )
            ),
        ])

        XCTAssertEqual(ProductionRuntimeSelector().select(from: registry)?.providerID, "planner")
    }

    func testAcceptsConfiguredDirectCredentialWithoutCallingItAuthenticated() {
        let registry = RuntimeProviderRegistry(providers: [
            provider(id: "direct", authentication: .configured, confinement: .readOnly),
        ])

        let selection = ProductionRuntimeSelector().select(from: registry)

        XCTAssertEqual(selection?.providerID, "direct")
        XCTAssertEqual(
            registry.provider(for: "direct")?.descriptor.authentication.explanation,
            "credential is configured but has not been verified by the provider"
        )
    }

    func testRuntimeProviderSetupChoiceInfersOfficialAndCustomEndpoints() {
        XCTAssertEqual(RuntimeProviderSetupChoice.infer(from: "https://api.openai.com"), .openAI)
        XCTAssertEqual(RuntimeProviderSetupChoice.infer(from: "https://api.anthropic.com/v1"), .anthropic)
        XCTAssertEqual(RuntimeProviderSetupChoice.infer(from: "https://generativelanguage.googleapis.com"), .gemini)
        XCTAssertEqual(RuntimeProviderSetupChoice.infer(from: "https://openrouter.ai/api"), .openRouter)
        XCTAssertEqual(RuntimeProviderSetupChoice.infer(from: "https://provider.example"), .custom)
        XCTAssertNil(RuntimeProviderSetupChoice.infer(from: ""))
    }

    func testRuntimeProviderSetupChoiceRejectsUnsafeCustomEndpoints() {
        XCTAssertTrue(RuntimeProviderSetupChoice.custom.accepts(endpoint: "https://provider.example"))
        XCTAssertTrue(RuntimeProviderSetupChoice.custom.accepts(endpoint: "http://127.0.0.1:8080"))
        XCTAssertFalse(RuntimeProviderSetupChoice.custom.accepts(endpoint: "http://provider.example"))
        XCTAssertFalse(RuntimeProviderSetupChoice.custom.accepts(endpoint: "file:///tmp/provider"))
    }

    func testConfiguredRuntimeRemainsSelectableAndCanSignOutWithoutClaimingReadiness() {
        let readiness = RuntimeReadiness(isReady: false, message: "Credential configured", authentication: .configured)
        let commands = readiness.commands(
            executable: URL(fileURLWithPath: "/verified/opencode"),
            signIn: ["auth", "login"],
            signOut: ["auth", "logout"]
        )
        let record = RuntimeSetupRecord(
            id: "cli.opencode", name: "OpenCode", status: readiness.message,
            isReady: readiness.isReady, authentication: readiness.authentication,
            signInCommand: commands.signIn, signOutCommand: commands.signOut
        )

        XCTAssertFalse(record.isReady)
        XCTAssertTrue(record.canPlan)
        XCTAssertEqual(record.signInCommand?.arguments, ["auth", "login"])
        XCTAssertEqual(record.signOutCommand?.arguments, ["auth", "logout"])
    }

    func testUnavailableRuntimeCannotBeSelectedOrOfferUnverifiedCommands() {
        let readiness = RuntimeReadiness(isReady: false, message: "Installation could not be verified")
        let commands = readiness.commands(
            executable: URL(fileURLWithPath: "/unverified/opencode"),
            signIn: ["auth", "login"], signOut: ["auth", "logout"]
        )
        let record = RuntimeSetupRecord(
            id: "cli.opencode", name: "OpenCode", status: readiness.message,
            isReady: readiness.isReady, authentication: readiness.authentication,
            signInCommand: commands.signIn, signOutCommand: commands.signOut
        )

        XCTAssertFalse(record.canPlan)
        XCTAssertNil(record.signInCommand)
        XCTAssertNil(record.signOutCommand)
    }

    func testVerifiedRuntimeAuthenticationStatesPreserveRecoveryCommands() {
        let executable = URL(fileURLWithPath: "/verified/runtime")
        for authentication in [
            RuntimeAuthenticationStatus.missing,
            .invalid(reason: "Expired credential"),
            .unknown(reason: "Login probe failed"),
        ] {
            let commands = RuntimeReadiness(
                isReady: false, message: "Needs attention", authentication: authentication
            ).commands(executable: executable, signIn: ["auth", "login"], signOut: ["auth", "logout"])

            XCTAssertEqual(commands.signIn?.executable, executable)
            XCTAssertEqual(commands.signIn?.arguments, ["auth", "login"])
            XCTAssertNil(commands.signOut)
        }

        let authenticated = RuntimeReadiness(
            isReady: true, message: "Signed in", authentication: .authenticated
        ).commands(executable: executable, signIn: ["auth", "login"], signOut: ["auth", "logout"])

        XCTAssertNil(authenticated.signIn)
        XCTAssertEqual(authenticated.signOut?.executable, executable)
        XCTAssertEqual(authenticated.signOut?.arguments, ["auth", "logout"])
    }

    func testRuntimeAuthenticationCommandQuotesExecutableAndArgumentsForShell() throws {
        let command = RuntimeAuthenticationCommand(
            executable: URL(fileURLWithPath: "/Applications/Perry's Tools/codex"),
            arguments: ["login", "--device-auth", "value with spaces"]
        )

        XCTAssertEqual(
            command.shellText,
            "'/Applications/Perry'\\''s Tools/codex' 'login' '--device-auth' 'value with spaces'"
        )
    }

    func testRuntimeAuthenticationCommandPinsCodexHomeWithoutShellExpansion() {
        let command = RuntimeAuthenticationCommand(
            executable: URL(fileURLWithPath: "/Applications/Perry.app/codex"),
            arguments: ["login", "--device-auth"],
            environment: ["CODEX_HOME": "/Users/test/Library/Application Support/Perry/CodexRuntime"]
        )

        XCTAssertEqual(
            command.shellText,
            "'/usr/bin/env' 'CODEX_HOME=/Users/test/Library/Application Support/Perry/CodexRuntime' '/Applications/Perry.app/codex' 'login' '--device-auth'"
        )
    }

    private func provider(
        id: String,
        authentication: RuntimeAuthenticationStatus,
        confinement: RuntimeConfinement
    ) -> RuntimeProvider {
        let runtime = SelectorStubRuntime(id: id)
        return RuntimeProvider(
            planner: runtime,
            descriptor: RuntimeProviderDescriptor(
                id: runtime.id,
                capabilities: runtime.capabilities,
                installation: .notApplicable(.local),
                authentication: authentication,
                health: .healthy,
                confinement: confinement
            )
        )
    }
}

private struct SelectorStubRuntime: TaskPlanner {
    let id: String
    let capabilities = RuntimeCapabilities(guiGrounding: true)

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        throw PlanError(message: "selector fixture must not plan")
    }
}
