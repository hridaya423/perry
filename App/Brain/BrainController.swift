import AppKit
import Foundation
import PerryBrain
import PerryGuide
import PerryRuntimes

/// Owns Perry's model providers: the bundled Codex brain (ChatGPT sign-in), any BYOK keys in
/// Keychain, local model servers, and Apple Intelligence. Callers ask `router()` for a route.
@MainActor
final class BrainController: ObservableObject {
    @Published private(set) var account: CodexAccountStatus = .unknown
    @Published private(set) var localModels: [LocalModel] = []
    @Published private(set) var activeExplanation = ""

    private let keychain = KeychainStore()
    private lazy var codex: CodexAppServerProvider? = Self.makeCodexProvider()
    private var loginTask: Task<Void, Never>?

    static func keychainAccount(for provider: DirectAIProvider) -> String {
        "brain.\(provider.rawValue.lowercased())"
    }

    func refresh() async {
        localModels = await LocalServerDiscovery().discover()
        account = await codex?.account.status() ?? .unknown
    }

    func router(preference: [ProviderID] = []) -> ProviderRouter {
        ProviderRouter(providers: providers(), preference: preference)
    }

    func route(_ requirement: RouteRequirement) async throws -> RouteDecision {
        let decision = try await router().route(requirement)
        activeExplanation = decision.explanation
        return decision
    }

    func signInWithChatGPT() {
        guard let codex else { return }
        loginTask?.cancel()
        loginTask = Task { [weak self] in
            do {
                let events = try await codex.account.loginEvents()
                guard let url = try await codex.account.signIn() else { return }
                NSWorkspace.shared.open(url)
                var iterator = events.makeAsyncIterator()
                _ = await iterator.next()
                await self?.refresh()
            } catch {
                self?.account = .unknown
            }
        }
    }

    func signOut() async {
        try? await codex?.account.signOut()
        await refresh()
    }

    private func providers() -> [any ModelProvider] {
        var result: [any ModelProvider] = []
        if let codex { result.append(codex) }
        for provider in DirectAIProvider.allCases {
            guard let key = apiKey(for: provider) else { continue }
            let keyProvider: @Sendable () -> String? = { key }
            switch provider {
            case .openAI: result.append(OpenAIResponsesProvider(apiKeyProvider: keyProvider))
            case .anthropic: result.append(AnthropicMessagesProvider(apiKeyProvider: keyProvider))
            case .gemini: result.append(GeminiProvider(apiKeyProvider: keyProvider))
            case .openRouter:
                result.append(OpenAIChatCompatibleProvider(
                    id: .openRouter, displayName: "OpenRouter", baseURL: provider.defaultBaseURL,
                    apiKeyProvider: keyProvider, models: BrainModelCatalog.openRouter,
                    capabilities: [.vision, .tools, .streaming]
                ))
            }
        }
        for model in localModels {
            result.append(OpenAIChatCompatibleProvider(
                id: ProviderID(rawValue: "local.\(model.server.rawValue).\(model.name)"),
                displayName: "\(model.name) (on this Mac)",
                baseURL: model.baseURL,
                models: BrainModelDefaults(fast: model.name, deep: model.name),
                capabilities: model.supportsVision ? [.vision, .streaming] : [.streaming]
            ))
        }
        if #available(macOS 26, *), AppleFoundationModelProvider.isAvailable {
            result.append(AppleFoundationModelProvider())
        }
        return result
    }

    /// ponytail: reads the legacy single `byok.vision` key as a fallback instead of migrating it,
    /// so an older build still finds its key. Drop the fallback once Settings writes `brain.*`.
    private func apiKey(for provider: DirectAIProvider) -> String? {
        if let key = try? keychain.readChecked(account: Self.keychainAccount(for: provider)), !key.isEmpty {
            return key
        }
        guard let endpoint = RuntimeCatalog.currentBYOKVisionEndpoint(),
              endpoint.baseURL.host.flatMap(DirectAIProvider.init(officialHost:)) == provider,
              let legacy = try? keychain.readChecked(account: RuntimeCatalog.byokVisionKeychainAccount),
              !legacy.isEmpty else { return nil }
        return legacy
    }

    private static func makeCodexProvider() -> CodexAppServerProvider? {
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("CodexRuntime/bin/codex"),
              FileManager.default.isExecutableFile(atPath: binary.path),
              let home = RuntimeCatalog.codexRuntimeHome else { return nil }
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-brain-cwd", isDirectory: true)
        return CodexAppServerProvider(process: CodexAppServerProcess(configuration: CodexAppServerConfiguration(
            binaryURL: binary, codexHome: home, workingDirectory: workingDirectory
        )))
    }

#if DEBUG
    /// Routes a fast text turn and reports what answered and how quickly the first words came.
    func smokeTest(report: @escaping @MainActor (String) -> Void) {
        Task {
            await refresh()
            let started = Date()
            do {
                let decision = try await route(RouteRequirement(tier: .fast))
                report("Asking \(decision.explanation)…")
                var text = ""
                var firstDelta: Int?
                for try await event in decision.provider.stream(ModelRequest(
                    system: "Answer in one short sentence.",
                    messages: [.user([.text("Say hello from Perry's brain.")])],
                    tier: .fast
                )) {
                    if case .textDelta(let delta) = event {
                        firstDelta = firstDelta ?? Int(Date().timeIntervalSince(started) * 1000)
                        text += delta
                        report("\(text) — first words in \(firstDelta ?? 0) ms")
                    }
                }
            } catch {
                report("Brain smoke test failed: \(error.localizedDescription)")
            }
        }
    }
#endif
}
