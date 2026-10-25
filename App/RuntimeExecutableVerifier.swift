import CryptoKit
import Foundation
import Security
import PerryRuntimes

enum RuntimeExecutableVerifier {
    static func codex(at executable: URL) async throws -> RuntimeInstallationStatus {
        try Task.checkCancellation()
        guard let digest = try await sha256(at: executable),
              digest == CodexRuntime.pinnedBinarySHA256 else {
            return .unverified(reason: "bundled Codex checksum does not match the pinned artifact")
        }
        do {
            let result = try await CLIRuntime.runProcess(
                executable: executable,
                arguments: ["--version"],
                timeout: 3
            )
            try Task.checkCancellation()
            guard result.exitCode == 0,
                  result.stdout.contains(CodexRuntime.pinnedVersion) else {
                return .unverified(reason: "bundled Codex did not report version \(CodexRuntime.pinnedVersion)")
            }
            return .verified(RuntimeInstallationIdentity(
                source: .bundled,
                version: CodexRuntime.pinnedVersion,
                executablePath: executable.resolvingSymlinksInPath().path,
                artifactSHA256: digest
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unverified(reason: "bundled Codex identity probe failed")
        }
    }

    static func claude(at executable: URL) async throws -> RuntimeInstallationStatus {
        try Task.checkCancellation()
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        let identityVerified = verifiesCodeIdentity(
            at: resolved,
            requirement: "identifier \"com.anthropic.claude-code\" and anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        )
        try Task.checkCancellation()
        guard identityVerified else {
            return .unverified(reason: "Claude Code is not signed by Anthropic")
        }
        do {
            let result = try await CLIRuntime.runProcess(
                executable: resolved,
                arguments: ["--version"],
                timeout: 3
            )
            try Task.checkCancellation()
            let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, !version.isEmpty,
                  let digest = try await sha256(at: resolved) else {
                return .unverified(reason: "Claude Code did not provide a verifiable version")
            }
            return .verified(RuntimeInstallationIdentity(
                source: .officialCLI,
                version: version,
                executablePath: resolved.path,
                artifactSHA256: digest
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unverified(reason: "Claude Code identity probe failed")
        }
    }

    static func sha256(at executable: URL) async throws -> String? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { () throws -> String? in
            do {
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: executable)
                var hash = SHA256()
                do {
                    while true {
                        try Task.checkCancellation()
                        let done = try autoreleasepool { () -> Bool in
                            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return true }
                            hash.update(data: chunk)
                            return false
                        }
                        if done { break }
                    }
                } catch {
                    try handle.close()
                    throw error
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                try handle.close()
                return digest
            } catch {
                try Task.checkCancellation()
                return nil
            }
        }
        return try await withTaskCancellationHandler {
            let digest = try await worker.value
            try Task.checkCancellation()
            return digest
        } onCancel: {
            worker.cancel()
        }
    }

    private static func verifiesCodeIdentity(at executable: URL, requirement requirementText: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }
}
