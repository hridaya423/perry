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
        let inventory = try await fixture.inspector.inspect()

        XCTAssertEqual(fixture.events, ["locate", "verify", "authenticate"])
        XCTAssertEqual(fixture.observedExecutables, Array(repeating: executable.resolvingSymlinksInPath(), count: 2))
        let record = try XCTUnwrap(inventory.setup.records.first)
        XCTAssertEqual(record.signInCommand?.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(record.signOutCommand?.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(record.signInCommand?.environment, ["CODEX_HOME": "/fixture/private-home"])
    }

    func testRejectedInstallationHasNoAuthenticationCommands() async throws {
        let fixture = Fixture()
        fixture.installation = .unverified(reason: "checksum mismatch")
        let inventory = try await fixture.inspector.inspect()

        XCTAssertEqual(fixture.events, ["locate", "verify"])
        let record = try XCTUnwrap(inventory.setup.records.first)
        XCTAssertNil(record.authentication)
        XCTAssertNil(record.signInCommand)
        XCTAssertNil(record.signOutCommand)
        XCTAssertFalse(record.canRun)
    }

    func testConfiguredCredentialsAllowRunningWithoutClaimingReadiness() async throws {
        let fixture = Fixture()
        let inventory = try await fixture.inspector.inspect()
        let record = try XCTUnwrap(inventory.setup.records.first)

        XCTAssertEqual(record.authentication, .configured)
        XCTAssertTrue(record.canRun)
        XCTAssertFalse(record.isReady)
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
    }

    func testOfficialAndCustomProvidersProduceSummaries() async throws {
        let cases: [(String, String)] = [
            ("https://api.openai.com", "OpenAI"),
            ("https://api.anthropic.com", "Anthropic"),
            ("https://generativelanguage.googleapis.com", "Gemini"),
            ("https://openrouter.ai/api", "OpenRouter"),
            ("https://custom.example", "Custom"),
        ]
        for (url, summaryName) in cases {
            let fixture = Fixture()
            let endpoint = BYOKAgentEndpoint(baseURL: try XCTUnwrap(URL(string: url)), model: "fixture-model")
            let inspector = RuntimeInventoryInspector(
                readDirectProvider: { ConfiguredDirectRuntime(endpoint: endpoint, credential: "fixture-secret") },
                commandLineProviders: [fixture.definition]
            )
            let inventory = try await inspector.inspect()
            XCTAssertEqual(inventory.setup.summary, "\(summaryName) key saved. I check it when a task starts.", url)
        }
    }

    func testCredentialFailureIsSanitized() async throws {
        let inventory = try await RuntimeInventoryInspector(
            readDirectProvider: { throw FixtureError() }, commandLineProviders: []
        ).inspect()

        XCTAssertEqual(inventory.setup.summary, "I couldn’t read your API key from the Keychain.")
        XCTAssertEqual(inventory.credentialFailure, inventory.setup.summary)
        XCTAssertFalse(inventory.setup.summary.contains("seeded-secret"))
    }

    func testOrdinaryProbeFailuresKeepRecordsAndSanitizeErrors() async throws {
        for stage in ["verify", "authenticate"] {
            let fixture = Fixture()
            fixture.failAt = stage
            let inventory = try await fixture.inspector.inspect()
            let record = try XCTUnwrap(inventory.setup.records.first)
            XCTAssertFalse(record.canRun)
            XCTAssertFalse(record.status.contains("seeded-secret"))
            if stage == "verify" {
                XCTAssertFalse(fixture.events.contains("authenticate"))
                XCTAssertNil(record.signInCommand)
            } else {
                XCTAssertNotNil(record.signInCommand)
                XCTAssertEqual(record.authentication, .unknown(reason: "Fixture CLI authentication inspection failed"))
            }
        }
    }

    func testProductionDefinitionsKeepCodexHomeAndExpectedAdapters() throws {
        let home = URL(fileURLWithPath: "/fixture/perry-private-codex")
        let definitions = RuntimeCLIDefinition.production(codexRuntimeHome: home)
        XCTAssertEqual(definitions.map(\.name), ["Bundled Codex", "Claude Code"])
        XCTAssertEqual(definitions.map(\.id), ["cli.codex", "cli.claude-code"])
        XCTAssertEqual(definitions.map(\.authenticatesInApp), [true, false])
        XCTAssertEqual(definitions[0].environment, ["CODEX_HOME": home.path])
        XCTAssertEqual(definitions[0].signInArguments, ["login", "--device-auth"])
    }

    /// In-app sign-in replaces the copy-a-Terminal-command flow: even when
    /// the runtime reports it needs authentication, the setup record carries
    /// no shell commands and marks itself as app-authenticating.
    func testInAppAuthenticatingRuntimeCarriesNoCopyCommands() async throws {
        let fixture = Fixture()
        fixture.authenticatesInApp = true
        fixture.authentication = .missing
        let inventory = try await fixture.inspector.inspect()
        let record = try XCTUnwrap(inventory.setup.records.first)

        XCTAssertTrue(record.authenticatesInApp)
        XCTAssertEqual(record.authentication, .missing)
        XCTAssertNil(record.signInCommand)
        XCTAssertNil(record.signOutCommand)
        XCTAssertFalse(record.canRun)
    }

    func testMissingPrivateCodexHomeRejectsCodexAndExplainsRecovery() async throws {
        let definition = try XCTUnwrap(RuntimeCLIDefinition.production(codexRuntimeHome: nil).first)
        let status = try await definition.verify(URL(fileURLWithPath: "/must-not-launch/runtime"))

        XCTAssertEqual(status, .unverified(reason: "Codex’s private folder isn’t available"))
        let inspected = try await definition.inspect()
        let record = try XCTUnwrap(inspected)
        XCTAssertFalse(record.canRun)
        XCTAssertNil(record.signInCommand)
        XCTAssertTrue(record.status.contains("Check storage and folder permissions"))
    }

    /// The inventory cache key leans on `fileStamp` — it must change when the
    /// file does and report "missing" cleanly.
    func testFileStampReflectsContentAndExistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("runtime")

        XCTAssertEqual(RuntimeCatalog.fileStamp(file), "missing")
        try Data("a".utf8).write(to: file)
        let first = RuntimeCatalog.fileStamp(file)
        try Data("much longer contents".utf8).write(to: file)
        XCTAssertNotEqual(RuntimeCatalog.fileStamp(file), first)
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
        var cancelAt: String?
        var failAt: String?
        var authenticatesInApp = false

        var inspector: RuntimeInventoryInspector {
            RuntimeInventoryInspector(readDirectProvider: { nil }, commandLineProviders: [definition])
        }

        var definition: RuntimeCLIDefinition {
            RuntimeCLIDefinition(
                name: "Fixture CLI",
                usesProviderAuthentication: false,
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
                id: "fixture.cli",
                signInArguments: ["login"], signOutArguments: ["logout"],
                environment: ["CODEX_HOME": "/fixture/private-home"],
                authenticatesInApp: authenticatesInApp
            )
        }
    }
}
