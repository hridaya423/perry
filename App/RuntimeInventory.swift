import Foundation
import PerryRuntimes

struct ConfiguredDirectRuntime {
    let endpoint: BYOKAgentEndpoint
    let credential: String
}

@MainActor
struct RuntimeInventoryInspector {
    let readDirectProvider: () throws -> ConfiguredDirectRuntime?
    let commandLineProviders: [RuntimeCLIDefinition]

    func inspect() async throws -> RuntimeSetupSnapshot {
        try Task.checkCancellation()
        var records: [RuntimeSetupRecord] = []
        var directSummary: String?
        var credentialFailure: String?
        do {
            if let configured = try readDirectProvider(), !configured.credential.isEmpty {
                let endpoint = configured.endpoint
                if let host = endpoint.baseURL.host, let kind = DirectAIProvider(officialHost: host) {
                    directSummary = "\(kind.displayName) key saved. I check it when a task starts."
                } else {
                    directSummary = "Custom key saved. I check it when a task starts."
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            credentialFailure = "I couldn’t read your API key from the Keychain."
        }
        for definition in commandLineProviders {
            try Task.checkCancellation()
            guard let record = try await definition.inspect() else { continue }
            records.append(record)
        }
        try Task.checkCancellation()
        return RuntimeSetupSnapshot(
            summary: credentialFailure ?? directSummary ?? records.first?.status
                ?? "Perry handles open-ended work on its own. Install Codex to hand off coding tasks.",
            records: records
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
            message = "\(label) has sign-in details I couldn’t confirm."
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
            message = "\(label) is confirmed, but I couldn’t confirm \(signIn)."
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
                    ? "I can’t reach Codex’s private data folder. Check storage and folder permissions, then check again."
                    : "I couldn’t confirm the Codex that came with Perry. Reinstall Perry before running open-ended tasks.",
                locate: { try CodexRuntime.bundledLocator() },
                verify: { executable in
                    guard codexRuntimeHome != nil else {
                        return .unverified(reason: "Codex’s private folder isn’t available")
                    }
                    return try await RuntimeExecutableVerifier.codex(at: executable)
                },
                authenticate: { try await CodexRuntime.authenticationStatus(executable: $0, runtimeHome: codexRuntimeHome) },
                id: "cli.codex",
                signInArguments: ["login", "--device-auth"], signOutArguments: ["logout"],
                environment: codexRuntimeHome.map { ["CODEX_HOME": $0.path] } ?? [:],
                authenticatesInApp: true
            ),
            RuntimeCLIDefinition(
                name: "Claude Code",
                usesProviderAuthentication: false,
                unverifiedMessage: "Claude Code is installed, but I couldn’t confirm it’s Anthropic software, so I’ll not use it.",
                locate: { try CLIRuntime.locateExecutable() }, verify: RuntimeExecutableVerifier.claude,
                authenticate: { try await CLIRuntime.authenticationStatus(executable: $0) },
                id: "cli.claude-code",
                signInArguments: ["auth", "login"], signOutArguments: ["auth", "logout"], environment: [:]
            ),
        ]
    }
}
