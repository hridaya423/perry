import XCTest
import PerryRuntimes
@testable import Perry

@MainActor
final class ProviderSetupStateTests: XCTestCase {
    private func record(_ id: String, _ authentication: RuntimeAuthenticationStatus?) -> RuntimeSetupRecord {
        RuntimeSetupRecord(
            id: id, name: id, status: "", isReady: authentication == .authenticated,
            authentication: authentication, signInCommand: nil, signOutCommand: nil
        )
    }

    private func snapshot(codex: RuntimeSetupRecord? = nil, claude: RuntimeSetupRecord? = nil) -> RuntimeSetupSnapshot {
        RuntimeSetupSnapshot(summary: "", records: [codex, claude].compactMap { $0 })
    }

    func testClaudeCodeProbeResultsMapToSetupStates() {
        let cases: [(RuntimeSetupRecord?, SetupState)] = [
            (record("cli.claude-code", .authenticated), .ready(detail: "Signed in with Claude Code")),
            (record("cli.claude-code", .missing), .needsSignIn),
            (record("cli.claude-code", .invalid(reason: "expired")), .needsSignIn),
            (record("cli.claude-code", .unknown(reason: "probe timed out")), .unchecked),
            (record("cli.claude-code", .configured), .unchecked),
            (record("cli.claude-code", nil), .notInstalled),
            (nil, .notInstalled),
        ]
        for (claude, expected) in cases {
            let states = snapshot(codex: record("cli.codex", .authenticated), claude: claude)
                .setupStates(chatGPTEmail: nil, acpInstalled: false)
            XCTAssertEqual(states[.claudeCode], expected, "\(String(describing: claude?.authentication))")
        }
    }

    func testChatGPTProbeResultsMapToSetupStates() {
        let cases: [(RuntimeAuthenticationStatus?, String?, SetupState)] = [
            (.authenticated, "me@example.com", .ready(detail: "me@example.com")),
            (.authenticated, nil, .ready(detail: "Signed in with ChatGPT")),
            (.missing, nil, .needsSignIn),
            (.unknown(reason: "timed out"), nil, .unchecked),
            (nil, nil, .notInstalled),
        ]
        for (authentication, email, expected) in cases {
            let states = snapshot(codex: record("cli.codex", authentication))
                .setupStates(chatGPTEmail: email, acpInstalled: false)
            XCTAssertEqual(states[.chatGPT], expected, "\(String(describing: authentication))")
        }
    }

    func testACPAgentsAreInstalledNeverSignedIn() {
        let installed = snapshot(codex: record("cli.codex", .authenticated)).setupStates(chatGPTEmail: nil, acpInstalled: true)
        let missing = snapshot(codex: record("cli.codex", .authenticated)).setupStates(chatGPTEmail: nil, acpInstalled: false)
        XCTAssertEqual(installed[.acp], .ready(detail: "Installed"))
        XCTAssertEqual(missing[.acp], .notInstalled)
    }

    func testAFailedInspectionLeavesCLIRowsUnchecked() {
        let states = RuntimeSetupSnapshot(summary: "Perry could not inspect the available runtimes.", records: [])
            .setupStates(chatGPTEmail: nil, acpInstalled: false)
        XCTAssertEqual(states[.chatGPT], .unchecked)
        XCTAssertEqual(states[.claudeCode], .unchecked)
    }

    func testEveryChoiceHasAStateAndStartsUnchecked() throws {
        let name = "ProviderSetupStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let brain = BrainController(defaults: defaults, codexFactory: { nil })
        XCTAssertEqual(Set(brain.setupStates.keys), Set(BrainController.ModelChoice.allCases))
        XCTAssertTrue(brain.setupStates.values.allSatisfy { $0 == .unchecked })
        let states = snapshot().setupStates(chatGPTEmail: nil, acpInstalled: false)
        XCTAssertEqual(Set(states.keys), Set(BrainController.ModelChoice.allCases))
    }

    func testClaudeCodeBinaryNotSignedByAnthropicIsNotUsed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let impostor = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: impostor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: impostor.path))
        XCTAssertNil(BrainController.makeClaudeCodeProvider(scopes: nil, locate: { impostor }))
    }
}
