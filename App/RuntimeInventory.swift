import Foundation
import PerryRuntimes

struct ConfiguredDirectRuntime {
    let endpoint: BYOKAgentEndpoint
    let credential: String
}

/// What the runtime probe found: the Settings setup snapshot plus the composer
/// choices list. Nothing routes through providers — open-ended work runs on the
/// built-in agent; this is install/auth bookkeeping only.
struct RuntimeInventory {
    let setup: RuntimeSetupSnapshot
    let choices: [RuntimeChoice]
    let credentialFailure: String?

}

@MainActor
struct RuntimeInventoryInspector {
    let readDirectProvider: () throws -> ConfiguredDirectRuntime?
    let commandLineProviders: [RuntimeCLIDefinition]

    func inspect(workingDirectory: URL? = nil) async throws -> RuntimeInventory {
        try Task.checkCancellation()
        var records: [RuntimeSetupRecord] = []
        var choices = [RuntimeChoice(id: RuntimeChoice.automaticID, name: "Automatic")]
        var directSummary: String?
        var credentialFailure: String?
        do {
            if let configured = try readDirectProvider(), !configured.credential.isEmpty {
                let endpoint = configured.endpoint
                if let host = endpoint.baseURL.host, let kind = DirectAIProvider(officialHost: host) {
                    choices.append(RuntimeChoice(id: kind.runtimeID, name: kind.displayName))
                    directSummary = "\(kind.displayName) credential configured. Perry verifies it when a task starts."
                } else {
                    choices.append(RuntimeChoice(id: "byok.vision", name: "Custom OpenAI-compatible provider"))
                    directSummary = "Custom provider credential configured. Perry verifies it when a task starts."
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            credentialFailure = "Perry could not read the direct-provider credential from Keychain."
        }
        for definition in commandLineProviders {
            try Task.checkCancellation()
            guard let record = try await definition.inspect() else { continue }
            records.append(record)
            if record.canRun {
                choices.append(RuntimeChoice(id: record.id, name: record.name))
            }
        }
        if workingDirectory != nil {
            choices.append(RuntimeChoice(id: "local.workspace-files", name: "Perry workspace files"))
        }
        try Task.checkCancellation()
        return RuntimeInventory(
            setup: RuntimeSetupSnapshot(
                summary: credentialFailure ?? directSummary ?? records.first?.status
                    ?? "Perry's built-in agent handles open-ended work. Install Codex for delegated coding tasks.",
                records: records
            ),
            choices: choices, credentialFailure: credentialFailure
        )
    }
}

@MainActor
struct RuntimeCLIDefinition {
    let name: String
    let usesProviderAuthentication: Bool
    let unverifiedMessage: String
    let locate: () throws -> URL
    let verify: (URL) async throws -> RuntimeInstallationStatus
    let authenticate: (URL) async throws -> RuntimeAuthenticationStatus
    let id: String
    let signInArguments: [String]
    let signOutArguments: [String]
    let environment: [String: String]
    /// When true, account sign-in happens inside the app and the setup record
    /// carries no shell commands for Settings to copy into Terminal.
    var authenticatesInApp = false

    private enum Inspection {
        case verified(RuntimeInstallationIdentity, RuntimeAuthenticationStatus)
        case rejected(reason: String)
    }

    func inspect() async throws -> RuntimeSetupRecord? {
        try Task.checkCancellation()
        let executable: URL
        do {
            executable = try locate().resolvingSymlinksInPath().standardizedFileURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
        let installation: RuntimeInstallationStatus
        do {
            installation = try await verify(executable)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            installation = .unverified(reason: "\(name) installation inspection failed")
        }
        try Task.checkCancellation()
        let inspection: Inspection
        switch installation {
        case .verified(let identity) where identity.version?.isEmpty == false:
            let authentication: RuntimeAuthenticationStatus
            do {
                authentication = try await authenticate(executable)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                authentication = .unknown(reason: "\(name) authentication inspection failed")
            }
            try Task.checkCancellation()
            inspection = .verified(identity, authentication)
        case .unverified(let reason):
            inspection = .rejected(reason: reason)
        default:
            inspection = .rejected(reason: "\(name) did not provide a verified version")
        }
        let readiness = readiness(for: inspection)
        let commands: (signIn: RuntimeAuthenticationCommand?, signOut: RuntimeAuthenticationCommand?)
        if authenticatesInApp {
            commands = (nil, nil)
        } else {
            commands = readiness.commands(
                executable: executable, signIn: signInArguments, signOut: signOutArguments, environment: environment
            )
        }
        try Task.checkCancellation()
        return RuntimeSetupRecord(
            id: id, name: name, status: readiness.message,
            isReady: readiness.isReady, authentication: readiness.authentication,
            signInCommand: commands.signIn, signOutCommand: commands.signOut,
            authenticatesInApp: authenticatesInApp
        )
    }

    private func readiness(for inspection: Inspection) -> RuntimeReadiness {
        guard case .verified(let identity, let authentication) = inspection, let version = identity.version else {
            return RuntimeReadiness(isReady: false, message: unverifiedMessage)
        }
        let label = "\(name) \(version)"
        let signIn = usesProviderAuthentication ? "provider sign-in" : "sign-in"
        let message: String
        let ready: Bool
        switch authentication {
        case .configured:
            message = "\(label) has configured credentials that Perry could not verify."
            ready = false
        case .authenticated:
            message = usesProviderAuthentication
                ? "\(label) is verified and has a signed-in provider."
                : "\(label) is verified and signed in."
            ready = true
        case .missing:
            message = "\(label) is verified but needs \(usesProviderAuthentication ? "a " : "")\(signIn)."
            ready = false
        case .invalid:
            message = "\(label) is verified, but its \(signIn) has expired."
            ready = false
        case .unknown:
            message = "\(label) is verified, but Perry could not confirm \(signIn)."
            ready = false
        case .notRequired:
            message = "\(label) is verified."
            ready = true
        }
        return RuntimeReadiness(isReady: ready, message: message, authentication: authentication)
    }

    static func production(codexRuntimeHome: URL?) -> [RuntimeCLIDefinition] {
        [
            RuntimeCLIDefinition(
                name: "Bundled Codex",
                usesProviderAuthentication: false,
                unverifiedMessage: codexRuntimeHome == nil
                    ? "Perry's private Codex data directory is unavailable. Check storage and folder permissions, then refresh runtime setup."
                    : "Bundled Codex could not be verified. Reinstall Perry before running open-ended tasks.",
                locate: { try CodexRuntime.bundledLocator() },
                verify: { executable in
                    guard codexRuntimeHome != nil else {
                        return .unverified(reason: "Perry's private Codex home is unavailable")
                    }
                    return try await RuntimeExecutableVerifier.codex(at: executable)
                },
                authenticate: { try await CodexRuntime.authenticationStatus(executable: $0, runtimeHome: codexRuntimeHome) },
                id: "cli.codex",
                signInArguments: ["login", "--device-auth"], signOutArguments: ["logout"],
                environment: codexRuntimeHome.map { ["CODEX_HOME": $0.path] } ?? [:],
                // ChatGPT sign-in goes through account/login/start in
                // Conversation model — never a Terminal command (§5.4).
                authenticatesInApp: true
            ),
            RuntimeCLIDefinition(
                name: "Claude Code",
                usesProviderAuthentication: false,
                unverifiedMessage: "Claude Code is installed but could not be verified as Anthropic software. Perry will not use it.",
                locate: { try CLIRuntime.locateExecutable() }, verify: RuntimeExecutableVerifier.claude,
                authenticate: { try await CLIRuntime.authenticationStatus(executable: $0) },
                id: "cli.claude-code",
                signInArguments: ["auth", "login"], signOutArguments: ["auth", "logout"], environment: [:]
            ),
            RuntimeCLIDefinition(
                name: "OpenCode",
                usesProviderAuthentication: true,
                unverifiedMessage: "OpenCode is installed but does not match Perry's pinned release. Perry will not use it.",
                locate: { try OpenCodeRuntime.locateExecutable() }, verify: RuntimeExecutableVerifier.openCode,
                authenticate: { try await OpenCodeRuntime.authenticationStatus(executable: $0) },
                id: "cli.opencode",
                signInArguments: ["auth", "login"], signOutArguments: ["auth", "logout"], environment: [:]
            ),
        ]
    }
}
