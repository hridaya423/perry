import Foundation
import PerryCore
import PerryRuntimes

@MainActor
struct RuntimeCatalog {
    static let byokVisionKeychainAccount = "byok.vision"

    typealias SetupLoader = @MainActor () async throws -> RuntimeSetupSnapshot
    var setupLoader: SetupLoader?

    static var codexRuntimeHome: URL? {
        AppController.supportDirectory?.appendingPathComponent("CodexRuntime", isDirectory: true)
    }

    private var inspector: RuntimeInventoryInspector {
        RuntimeInventoryInspector(
            readDirectProvider: {
                guard let profile = ModelProfileStore(defaults: .standard).active(),
                      let key = try KeychainStore().readChecked(account: profile.keyAccount),
                      !key.isEmpty else { return nil }
                return ConfiguredDirectRuntime(endpoint: BYOKAgentEndpoint(baseURL: profile.baseURL, model: profile.model), credential: key)
            },
            commandLineProviders: RuntimeCLIDefinition.production(codexRuntimeHome: Self.codexRuntimeHome)
        )
    }

    func currentSetup() async -> RuntimeSetupSnapshot {
        do {
            if let setupLoader { return try await setupLoader() }
            return try await inspector.inspect()
        } catch is CancellationError {
            return RuntimeSetupSnapshot(summary: "I stopped looking for coding agents.", records: [])
        } catch {
            return RuntimeSetupSnapshot(summary: "I couldn’t look for coding agents. Choose Check again.", records: [])
        }
    }
}
