import Foundation
import PerryRuntimes

struct ConfiguredDirectRuntime {
    let endpoint: BYOKAgentEndpoint
    let credential: String
}

struct RuntimeInventory {
    let registry: RuntimeProviderRegistry
    let setup: RuntimeSetupSnapshot
    let choices: [RuntimeChoice]
    let automaticPreference: RuntimeProviderID?
    let credentialFailure: String?

    var hasReadyCLIPlanner: Bool { setup.records.contains(where: \.isReady) }
}

@MainActor
struct RuntimeInventoryInspector {
    let readDirectProvider: () throws -> ConfiguredDirectRuntime?
    let commandLineProviders: [RuntimeCLIDefinition]

    func inspect(workingDirectory: URL? = nil) async throws -> RuntimeInventory {
        try Task.checkCancellation()
        var providers: [RuntimeProvider] = []
        var records: [RuntimeSetupRecord] = []
        var choices = [RuntimeChoice(id: RuntimeChoice.automaticID, name: "Automatic")]
        var automaticPreference: RuntimeProviderID?
        var directSummary: String?
        var credentialFailure: String?
        do {
            if let configured = try readDirectProvider(), !configured.credential.isEmpty {
                let key = configured.credential
                let endpoint = configured.endpoint
                let provider: RuntimeProvider
                if let host = endpoint.baseURL.host, let kind = DirectAIProvider(officialHost: host) {
                    let runtime = DirectProviderRuntime(
                        configuration: DirectProviderConfiguration(provider: kind, model: endpoint.model, baseURL: endpoint.baseURL),
                        apiKeyProvider: { key }
                    )
                    provider = RuntimeProvider(planner: runtime as any TaskPlanner, descriptor: RuntimeProviderDescriptor(
                        id: runtime.id, displayName: kind.displayName, kind: .byok,
                        capabilities: runtime.capabilities, operations: [.planning],
                        installation: .notApplicable(.directAPI), authentication: .configured,
                        health: .healthy, confinement: .readOnly, priority: 0
                    ))
                    directSummary = "\(kind.displayName) credential configured. Perry verifies it when planning starts."
                } else {
                    let runtime = BYOKAgentRuntime(endpoint: endpoint, apiKeyProvider: { key })
                    provider = RuntimeProvider(planner: runtime as any TaskPlanner, descriptor: RuntimeProviderDescriptor(
                        id: runtime.id, displayName: "Custom OpenAI-compatible provider", kind: .custom,
                        capabilities: runtime.capabilities,
                        operations: [.planning], installation: .notApplicable(.customEndpoint),
                        authentication: .configured, health: .healthy, confinement: .readOnly, priority: 0
                    ))
                    directSummary = "Custom provider credential configured. Perry verifies it when planning starts."
                }
                providers.append(provider)
                automaticPreference = provider.id
                choices.append(RuntimeChoice(id: provider.id.rawValue, name: provider.descriptor.displayName))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            credentialFailure = "Perry could not read the direct-provider credential from Keychain."
        }
        for definition in commandLineProviders {
            try Task.checkCancellation()
            guard let entry = try await definition.inspect(workingDirectory: workingDirectory) else { continue }
            providers.append(entry.provider)
            records.append(entry.setup)
            if automaticPreference == nil && definition.preferredByDefault {
                automaticPreference = entry.provider.id
            }
            if entry.setup.canPlan {
                choices.append(RuntimeChoice(id: entry.setup.id, name: entry.setup.name))
            }
        }
        if let workingDirectory {
            let runtime = WorkspaceFileRuntime(baseURL: workingDirectory)
            let provider = RuntimeProvider(
                planner: WorkspaceFilePlanner(),
                descriptor: RuntimeProviderDescriptor(
                    id: runtime.id,
                    displayName: "Perry workspace files",
                    kind: .local,
                    capabilities: runtime.capabilities,
                    operations: [.planning, .execution],
                    installation: .notApplicable(.local),
                    authentication: .notRequired,
                    health: .healthy,
                    confinement: .workspace,
                    priority: 110
                )
            )
            providers.append(provider)
            choices.append(RuntimeChoice(id: provider.id.rawValue, name: provider.descriptor.displayName))
        }
        let local = LocalTaskPlannerRuntime()
        providers.append(RuntimeProvider(
            planner: local as any TaskPlanner,
            descriptor: RuntimeProviderDescriptor(
            id: local.id, displayName: "Perry local planner", kind: .local,
            capabilities: local.capabilities,
            operations: [.planning], installation: .notApplicable(.local),
            authentication: .notRequired, health: .healthy, confinement: .workspace, priority: 100
            )
        ))
        choices.append(RuntimeChoice(id: local.id, name: "Perry local planner"))
        try Task.checkCancellation()
        return RuntimeInventory(
            registry: RuntimeProviderRegistry(providers: providers),
            setup: RuntimeSetupSnapshot(
                summary: credentialFailure ?? directSummary ?? records.first?.status
                    ?? "Perry's local planner is available for supported tasks. Install Codex, Claude Code, or OpenCode for open-ended work.",
                records: records
            ),
            choices: choices, automaticPreference: automaticPreference, credentialFailure: credentialFailure
        )
    }
}

@MainActor
struct RuntimeCLIDefinition {
    let name: String
    let priority: Int
    let confinement: RuntimeConfinement
    let preferredByDefault: Bool
    let usesProviderAuthentication: Bool
    let unverifiedMessage: String
    let locate: () throws -> URL
    let verify: (URL) async throws -> RuntimeInstallationStatus
    let authenticate: (URL) async throws -> RuntimeAuthenticationStatus
    let makePlanner: (URL, URL?) -> any TaskPlanner
    let signInArguments: [String]
    let signOutArguments: [String]
    let environment: [String: String]
    /// When true, account sign-in happens inside the app and the setup record
    /// carries no shell commands for Settings to copy into Terminal.
    var authenticatesInApp = false

    struct Entry {
        let provider: RuntimeProvider
        let setup: RuntimeSetupRecord
    }

    private enum Inspection {
        case verified(RuntimeInstallationIdentity, RuntimeAuthenticationStatus)
        case rejected(reason: String)

        var installation: RuntimeInstallationStatus {
            switch self {
            case .verified(let identity, _): return .verified(identity)
            case .rejected(let reason): return .unverified(reason: reason)
            }
        }

        var authentication: RuntimeAuthenticationStatus? {
            guard case .verified(_, let authentication) = self else { return nil }
            return authentication
        }
    }

    func inspect(workingDirectory: URL?) async throws -> Entry? {
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
        let planner = makePlanner(executable, workingDirectory)
        let descriptor = RuntimeProviderDescriptor(
            id: planner.id, displayName: name, kind: .cli,
            capabilities: planner.capabilities,
            operations: [.planning],
            installation: inspection.installation,
            authentication: inspection.authentication ?? .unknown(reason: "\(name) installation identity is unverified"),
            health: .healthy, confinement: confinement, priority: priority
        )
        let readiness = readiness(for: inspection, planningOnly: true)
        let commands: (signIn: RuntimeAuthenticationCommand?, signOut: RuntimeAuthenticationCommand?)
        if authenticatesInApp {
            commands = (nil, nil)
        } else {
            commands = readiness.commands(
                executable: executable, signIn: signInArguments, signOut: signOutArguments, environment: environment
            )
        }
        try Task.checkCancellation()
        return Entry(
            provider: RuntimeProvider(planner: planner, descriptor: descriptor),
            setup: RuntimeSetupRecord(
                id: descriptor.id.rawValue, name: name, status: readiness.message,
                isReady: readiness.isReady, authentication: readiness.authentication,
                signInCommand: commands.signIn, signOutCommand: commands.signOut,
                authenticatesInApp: authenticatesInApp
            )
        )
    }

    private func readiness(for inspection: Inspection, planningOnly: Bool) -> RuntimeReadiness {
        guard case .verified(let identity, let authentication) = inspection, let version = identity.version else {
            return RuntimeReadiness(isReady: false, message: unverifiedMessage)
        }
        let label = "\(name) \(version)"
        let scope = planningOnly ? " for planning" : ""
        let signIn = usesProviderAuthentication ? "provider sign-in" : "sign-in"
        let message: String
        let ready: Bool
        switch authentication {
        case .configured:
            message = "\(label) has configured credentials that Perry could not verify."
            ready = false
        case .authenticated:
            message = usesProviderAuthentication
                ? "\(label) is verified and has a signed-in provider\(scope)."
                : "\(label) is verified and signed in\(scope)."
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
            message = "\(label) is verified\(scope)."
            ready = true
        }
        return RuntimeReadiness(isReady: ready, message: message, authentication: authentication)
    }

    static func production(codexRuntimeHome: URL?) -> [RuntimeCLIDefinition] {
        [
            RuntimeCLIDefinition(
                name: "Bundled Codex", priority: 10, confinement: .workspace,
                preferredByDefault: true, usesProviderAuthentication: false,
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
                makePlanner: { executable, directory in
                    CodexRuntime(executableLocator: { executable }, workingDirectory: directory, runtimeHome: codexRuntimeHome)
                },
                signInArguments: ["login", "--device-auth"], signOutArguments: ["logout"],
                environment: codexRuntimeHome.map { ["CODEX_HOME": $0.path] } ?? [:],
                // ChatGPT sign-in goes through account/login/start in
                // Conversation model — never a Terminal command (§5.4).
                authenticatesInApp: true
            ),
            RuntimeCLIDefinition(
                name: "Claude Code", priority: 20, confinement: .readOnly,
                preferredByDefault: false, usesProviderAuthentication: false,
                unverifiedMessage: "Claude Code is installed but could not be verified as Anthropic software. Perry will not use it.",
                locate: { try CLIRuntime.locateExecutable() }, verify: RuntimeExecutableVerifier.claude,
                authenticate: { try await CLIRuntime.authenticationStatus(executable: $0) },
                makePlanner: { executable, directory in
                    CLIRuntime(executableLocator: { executable }, workingDirectory: directory)
                },
                signInArguments: ["auth", "login"], signOutArguments: ["auth", "logout"], environment: [:]
            ),
            RuntimeCLIDefinition(
                name: "OpenCode", priority: 30, confinement: .readOnly,
                preferredByDefault: false, usesProviderAuthentication: true,
                unverifiedMessage: "OpenCode is installed but does not match Perry's pinned release. Perry will not use it.",
                locate: { try OpenCodeRuntime.locateExecutable() }, verify: RuntimeExecutableVerifier.openCode,
                authenticate: { try await OpenCodeRuntime.authenticationStatus(executable: $0) },
                makePlanner: { executable, directory in
                    OpenCodeRuntime(executableLocator: { executable }, workingDirectory: directory)
                },
                signInArguments: ["auth", "login"], signOutArguments: ["auth", "logout"], environment: [:]
            ),
        ]
    }
}
