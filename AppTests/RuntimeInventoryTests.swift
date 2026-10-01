import XCTest
import PerryCore
import PerryRuntimes
@testable import Perry

@MainActor
final class RuntimeInventoryTests: XCTestCase {
    func testInspectionResolvesOnceAndUsesTheSameExecutableForEveryStage() async throws {
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let executable = directory.appendingPathComponent("runtime")
        try Data("fixture".utf8).write(to: executable)
        fixture.executable = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: fixture.executable, withDestinationURL: executable)
        let workspace = directory.appendingPathComponent("workspace")
        let inventory = try await fixture.inspector.inspect(workingDirectory: workspace)

        XCTAssertEqual(fixture.events, ["locate", "verify", "authenticate", "construct"])
        XCTAssertEqual(fixture.observedExecutables, Array(repeating: executable.resolvingSymlinksInPath(), count: 3))
        XCTAssertEqual(fixture.workspace, workspace)
        let record = try XCTUnwrap(inventory.setup.records.first)
        XCTAssertEqual(record.signInCommand?.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(record.signOutCommand?.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(record.signInCommand?.environment, ["CODEX_HOME": "/fixture/private-home"])
        XCTAssertEqual(inventory.registry.providers.map(\.id.rawValue), ["fixture.cli", "local.workspace-files", "local.task-planner"])
    }

    func testRejectedInstallationHasNoAuthenticationCommandsOrPlanningChoice() async throws {
        let fixture = Fixture()
        fixture.installation = .unverified(reason: "checksum mismatch")
        let inventory = try await fixture.inspector.inspect()

        XCTAssertEqual(fixture.events, ["locate", "verify", "construct"])
        let record = try XCTUnwrap(inventory.setup.records.first)
        XCTAssertNil(record.authentication)
        XCTAssertNil(record.signInCommand)
        XCTAssertNil(record.signOutCommand)
        XCTAssertFalse(record.canPlan)
        XCTAssertFalse(inventory.hasReadyCLIPlanner)
        XCTAssertEqual(inventory.choices.map(\.id), ["automatic", "local.task-planner"])
        let selection = ProductionRuntimeSelector().select(from: inventory.registry, preferredProviderID: inventory.automaticPreference)
        XCTAssertEqual(selection?.providerID, "local.task-planner")
        XCTAssertTrue(selection?.explanation.fallbackReason?.contains("checksum mismatch") == true)
    }

    func testConfiguredCredentialsAllowPlanningWithoutClaimingReadiness() async throws {
        let fixture = Fixture()
        let inventory = try await fixture.inspector.inspect()
        let record = try XCTUnwrap(inventory.setup.records.first)

        XCTAssertEqual(record.authentication, .configured)
        XCTAssertTrue(record.canPlan)
        XCTAssertFalse(record.isReady)
        XCTAssertFalse(inventory.hasReadyCLIPlanner)
        XCTAssertEqual(inventory.choices.map(\.id), ["automatic", "fixture.cli", "local.task-planner"])
        XCTAssertEqual(ProductionRuntimeSelector().select(from: inventory.registry)?.providerID, "fixture.cli")
        XCTAssertEqual(inventory.registry.provider(for: "fixture.cli")?.descriptor.operations, [.planning])
    }

    func testCancellationDuringVerificationOrAuthenticationReturnsNoInventory() async {
        for stage in ["verify", "authenticate"] {
            let fixture = Fixture()
            fixture.cancelAt = stage
            let task = Task { try await fixture.inspector.inspect() }
            do {
                _ = try await task.value
                XCTFail("Cancellation must prevent a completed inventory")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
            XCTAssertFalse(fixture.events.contains("construct"))
            if stage == "verify" { XCTAssertFalse(fixture.events.contains("authenticate")) }
        }
    }

    func testEveryInspectionRefreshesExecutableAndAuthenticationState() async throws {
        let fixture = Fixture()
        let inspector = fixture.inspector
        _ = try await inspector.inspect()
        fixture.executable = URL(fileURLWithPath: "/fixture/replacement")
        fixture.authentication = .missing
        let inventory = try await inspector.inspect()

        XCTAssertEqual(fixture.events.filter { $0 == "locate" }.count, 2)
        XCTAssertEqual(fixture.observedExecutables.last, fixture.executable)
        XCTAssertEqual(inventory.setup.records.first?.authentication, .missing)
        XCTAssertEqual(inventory.setup.records.first?.signInCommand?.executable, fixture.executable)
        XCTAssertEqual(inventory.choices.map(\.id), ["automatic", "local.task-planner"])
    }

    func testOfficialAndCustomProvidersUseTheSameInventoryForRoutingAndChoices() async throws {
        let cases: [(String, String, RuntimeProviderKind, RuntimeInstallationSource)] = [
            ("https://api.openai.com", "direct.openai", .byok, .directAPI),
            ("https://api.anthropic.com", "direct.anthropic", .byok, .directAPI),
            ("https://generativelanguage.googleapis.com", "direct.gemini", .byok, .directAPI),
            ("https://openrouter.ai/api", "direct.openrouter", .byok, .directAPI),
            ("https://custom.example", "byok.vision", .custom, .customEndpoint),
        ]
        for (url, id, kind, source) in cases {
            let fixture = Fixture()
            let endpoint = BYOKAgentEndpoint(baseURL: try XCTUnwrap(URL(string: url)), model: "fixture-model")
            let inspector = RuntimeInventoryInspector(
                readDirectProvider: { ConfiguredDirectRuntime(endpoint: endpoint, credential: "fixture-secret") },
                commandLineProviders: [fixture.definition]
            )
            let inventory = try await inspector.inspect()
            let provider = try XCTUnwrap(inventory.registry.provider(for: id))
            XCTAssertEqual(provider.descriptor.identity.kind, kind)
            XCTAssertEqual(provider.descriptor.installation, .notApplicable(source))
            XCTAssertEqual(provider.descriptor.authentication, .configured)
            XCTAssertEqual(provider.descriptor.operations, [.planning])
            XCTAssertEqual(inventory.choices.map(\.id), ["automatic", id, "fixture.cli", "local.task-planner"])
            XCTAssertEqual(inventory.automaticPreference?.rawValue, id)
            XCTAssertEqual(ProductionRuntimeSelector().select(from: inventory.registry, preferredProviderID: inventory.automaticPreference)?.providerID.rawValue, id)
            XCTAssertEqual(ProductionRuntimeSelector().select(from: inventory.registry, preferredProviderID: "fixture.cli")?.providerID, "fixture.cli")
        }
    }

    func testCredentialFailureIsSanitizedAndRetainsLocalFallback() async throws {
        let inventory = try await RuntimeInventoryInspector(
            readDirectProvider: { throw FixtureError() }, commandLineProviders: []
        ).inspect()

        XCTAssertEqual(inventory.setup.summary, "Perry could not read the direct-provider credential from Keychain.")
        XCTAssertEqual(inventory.credentialFailure, inventory.setup.summary)
        XCTAssertFalse(inventory.setup.summary.contains("seeded-secret"))
        XCTAssertEqual(inventory.choices.map(\.id), ["automatic", "local.task-planner"])
        XCTAssertEqual(ProductionRuntimeSelector().select(from: inventory.registry)?.providerID, "local.task-planner")
    }

    func testOrdinaryProbeFailuresKeepOtherProvidersAndSanitizeErrors() async throws {
        for stage in ["verify", "authenticate"] {
            let fixture = Fixture()
            fixture.failAt = stage
            let inventory = try await fixture.inspector.inspect()
            let record = try XCTUnwrap(inventory.setup.records.first)
            XCTAssertFalse(record.canPlan)
            XCTAssertEqual(ProductionRuntimeSelector().select(from: inventory.registry)?.providerID, "local.task-planner")
            XCTAssertFalse(record.status.contains("seeded-secret"))
            let rejected = try XCTUnwrap(inventory.registry.provider(for: "fixture.cli"))
            XCTAssertFalse(rejected.descriptor.installation.explanation.contains("seeded-secret"))
            XCTAssertFalse(rejected.descriptor.authentication.explanation.contains("seeded-secret"))
            if stage == "verify" {
                XCTAssertFalse(fixture.events.contains("authenticate"))
                XCTAssertNil(record.signInCommand)
                XCTAssertEqual(rejected.descriptor.installation, .unverified(reason: "Fixture CLI installation inspection failed"))
            } else {
                XCTAssertNotNil(record.signInCommand)
                XCTAssertEqual(record.authentication, .unknown(reason: "Fixture CLI authentication inspection failed"))
                XCTAssertEqual(rejected.descriptor.installation, fixture.installation)
            }
        }
    }

    func testProductionDefinitionsKeepCodexHomeAndPlanningOnlyInstalledAdapters() throws {
        let home = URL(fileURLWithPath: "/fixture/perry-private-codex")
        let definitions = RuntimeCLIDefinition.production(codexRuntimeHome: home)
        XCTAssertEqual(definitions.map(\.name), ["Bundled Codex", "Claude Code", "OpenCode"])
        XCTAssertEqual(definitions.map(\.priority), [10, 20, 30])
        XCTAssertEqual(definitions.map(\.confinement), [.workspace, .readOnly, .readOnly])
        XCTAssertEqual(definitions.map(\.preferredByDefault), [true, false, false])
        let executable = URL(fileURLWithPath: "/fixture/never-launch")
        let planners = definitions.map { $0.makePlanner(executable, nil) }
        XCTAssertEqual(planners.map(\.id), ["cli.codex", "cli.claude-code", "cli.opencode"])
        XCTAssertEqual(definitions[0].environment, ["CODEX_HOME": home.path])
        XCTAssertEqual(definitions[0].signInArguments, ["login", "--device-auth"])
    }

    func testMissingPrivateCodexHomeRejectsCodexAndExplainsRecovery() async throws {
        let definition = try XCTUnwrap(RuntimeCLIDefinition.production(codexRuntimeHome: nil).first)
        let status = try await definition.verify(URL(fileURLWithPath: "/must-not-launch/runtime"))

        XCTAssertEqual(status, .unverified(reason: "Perry's private Codex home is unavailable"))
        let inspected = try await definition.inspect(workingDirectory: nil)
        let entry = try XCTUnwrap(inspected)
        XCTAssertFalse(entry.setup.canPlan)
        XCTAssertNil(entry.setup.signInCommand)
        XCTAssertTrue(entry.setup.status.contains("Check storage and folder permissions"))
    }

    private struct FixtureError: Error, CustomStringConvertible {
        var description: String { "seeded-secret" }
    }

    private final class Fixture {
        var executable = URL(fileURLWithPath: "/fixture/runtime")
        var installation: RuntimeInstallationStatus = .verified(RuntimeInstallationIdentity(source: .officialCLI, version: "1.0"))
        var authentication: RuntimeAuthenticationStatus = .configured
        var events: [String] = []
        var observedExecutables: [URL] = []
        var workspace: URL?
        var cancelAt: String?
        var failAt: String?

        var inspector: RuntimeInventoryInspector {
            RuntimeInventoryInspector(readDirectProvider: { nil }, commandLineProviders: [definition])
        }

        var definition: RuntimeCLIDefinition {
            RuntimeCLIDefinition(
                name: "Fixture CLI", priority: 10, confinement: .readOnly,
                preferredByDefault: true, usesProviderAuthentication: false,
                unverifiedMessage: "Fixture CLI could not be verified.",
                locate: {
                    self.events.append("locate")
                    return self.executable
                },
                verify: {
                    self.events.append("verify")
                    self.observedExecutables.append($0)
                    if self.cancelAt == "verify" { withUnsafeCurrentTask { $0?.cancel() } }
                    if self.failAt == "verify" { throw FixtureError() }
                    return self.installation
                },
                authenticate: {
                    self.events.append("authenticate")
                    self.observedExecutables.append($0)
                    if self.cancelAt == "authenticate" { withUnsafeCurrentTask { $0?.cancel() } }
                    if self.failAt == "authenticate" { throw FixtureError() }
                    return self.authentication
                },
                makePlanner: {
                    self.events.append("construct")
                    self.observedExecutables.append($0)
                    self.workspace = $1
                    return InventoryPlanner()
                },
                signInArguments: ["login"], signOutArguments: ["logout"],
                environment: ["CODEX_HOME": "/fixture/private-home"]
            )
        }
    }
}

private struct InventoryPlanner: TaskPlanner {
    let id = "fixture.cli"
    let capabilities = RuntimeCapabilities(fileIO: true)

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        throw PlanError(message: "Inventory inspection must not invoke planning")
    }
}
