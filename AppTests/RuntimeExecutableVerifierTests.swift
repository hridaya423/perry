import XCTest
import PerryRuntimes
@testable import Perry

final class RuntimeExecutableVerifierTests: XCTestCase {
    func testCanceledIdentityChecksDoNotBecomeInstallationFailures() async {
        let executable = URL(fileURLWithPath: "/must-not-probe/runtime")
        let checks: [@Sendable () async throws -> Void] = [
            { _ = try await RuntimeExecutableVerifier.codex(at: executable) },
            { _ = try await RuntimeExecutableVerifier.claude(at: executable) },
            { _ = try await RuntimeExecutableVerifier.openCode(at: executable) },
            { _ = try await RuntimeExecutableVerifier.sha256(at: executable) },
        ]
        for check in checks {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await check()
            }
            do {
                try await task.value
                XCTFail("Canceled identity checks must propagate cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
        }
    }

    func testHashMatchesKnownSHA256VectorAndUnreadableInputFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-hash-vector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("vector")
        try Data("abc".utf8).write(to: file)

        let digest = try await RuntimeExecutableVerifier.sha256(at: file)
        let unreadable = try await RuntimeExecutableVerifier.sha256(at: directory)

        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(unreadable)
    }

    func testBundledCodexMatchesPinnedVersionAndChecksum() async throws {
        let executable = try CodexRuntime.bundledLocator()
        let status = try await RuntimeExecutableVerifier.codex(at: executable)

        guard case .verified(let identity) = status else {
            return XCTFail("expected bundled Codex identity to verify, got \(status)")
        }
        XCTAssertEqual(identity.source, .bundled)
        XCTAssertEqual(identity.version, CodexRuntime.pinnedVersion)
        XCTAssertEqual(identity.artifactSHA256, CodexRuntime.pinnedBinarySHA256)
    }

    func testChangedCodexArtifactFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-runtime-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        try Data("not codex".utf8).write(to: executable)
        addTeardownBlock {
            try TestTempDirectory.remove(directory)
        }

        let status = try await RuntimeExecutableVerifier.codex(at: executable)

        guard case .unverified(let reason) = status else {
            return XCTFail("expected changed artifact to fail verification")
        }
        XCTAssertTrue(reason.contains("checksum"))
    }

    func testNonAnthropicExecutableCannotRegisterAsClaude() async throws {
        let status = try await RuntimeExecutableVerifier.claude(at: URL(fileURLWithPath: "/bin/echo"))

        guard case .unverified(let reason) = status else {
            return XCTFail("expected non-Anthropic executable to fail verification")
        }
        XCTAssertTrue(reason.contains("signed by Anthropic"))
    }

    func testInstalledOpenCodeMatchesPinnedRelease() async throws {
        let executable: URL
        do {
            executable = try OpenCodeRuntime.locateExecutable()
        } catch {
            throw XCTSkip("OpenCode is not installed")
        }

        let status = try await RuntimeExecutableVerifier.openCode(at: executable)

        guard case .verified(let identity) = status else {
            return XCTFail("Expected the installed OpenCode release to verify, got \(status)")
        }
        XCTAssertEqual(identity.version, OpenCodeRuntime.pinnedVersion)
        XCTAssertEqual(identity.artifactSHA256, OpenCodeRuntime.pinnedBinarySHA256)
    }

    func testChangedOpenCodeArtifactFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("opencode")
        try Data("changed".utf8).write(to: executable)
        addTeardownBlock { try TestTempDirectory.remove(directory) }

        let status = try await RuntimeExecutableVerifier.openCode(at: executable)

        guard case .unverified(let reason) = status else {
            return XCTFail("Expected an unverified installation")
        }
        XCTAssertTrue(reason.contains("checksum"))
    }

    func testInstalledClaudeHasOfficialIdentityAndVersion() async throws {
        let executable: URL
        do {
            executable = try CLIRuntime.locateExecutable()
        } catch {
            throw XCTSkip("Claude Code is not installed on this test account")
        }

        let status = try await RuntimeExecutableVerifier.claude(at: executable)

        guard case .verified(let identity) = status else {
            return XCTFail("expected installed Claude Code identity to verify, got \(status)")
        }
        XCTAssertEqual(identity.source, .officialCLI)
        XCTAssertFalse(identity.version?.isEmpty ?? true)
        XCTAssertFalse(identity.artifactSHA256?.isEmpty ?? true)
    }

}
