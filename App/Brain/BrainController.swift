import AppKit
import Foundation
import PerryBrain
import PerryGuide
import PerryRuntimes

/// Owns Perry's model providers: the bundled Codex brain (ChatGPT sign-in), any BYOK keys in
/// Keychain, local model servers, and Apple Intelligence. Callers ask `router()` for a route.
@MainActor
final class BrainController: ObservableObject {
    enum ModelChoice: String, CaseIterable {
        case chatGPT, direct, local

        var title: String {
            switch self {
            case .chatGPT: "ChatGPT"
            case .direct: "My API provider"
            case .local: "On this Mac"
            }
        }
    }

    static let modelChoiceKey = "perry.brain.modelChoice"
    @Published private var selectedModel: String
    var modelChoice: String {
        get { selectedModel }
        set {
            guard acceptsSetup else { return }
            selectedModel = newValue
            defaults.set(newValue, forKey: Self.modelChoiceKey)
        }
    }
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInError: String?
    @Published private(set) var account: CodexAccountStatus = .unknown
    @Published private(set) var localModels: [LocalModel] = []
    @Published private(set) var localChecks: [ProviderID: LocalCheckState] = [:]
    @Published private(set) var activeExplanation = ""

    private let readCredential: (String) throws -> String?
    private let configuredEndpoint: @MainActor () -> BYOKAgentEndpoint?
    private let transport: any HTTPLineStreaming
    private let defaults: UserDefaults
    private let discoverLocalModels: () async -> [LocalModel]
    private let openAuthenticationURL: (URL) -> Bool
    private let codexFactory: () -> CodexAppServerProvider?
    private lazy var codex: CodexAppServerProvider? = codexFactory()
    private var acceptsSetup = true
    private var setupGeneration = UUID()
    private var loginCleanupTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginAttempt: UUID?
    private var loginID: String?
    private var cachedRouting: (configuration: RoutingConfiguration, router: ProviderRouter)?
    private var localCheckTasks: [ProviderID: Task<Void, Never>] = [:]

    enum LocalCheckState: Equatable {
        case checking
        case checked(LocalModel, ModelCapabilityProbe.Result)
        case failed(String)
    }

    private struct RoutingConfiguration: Equatable {
        let credentials: [DirectAIProvider: String]
        let customCredential: String?
        let endpoint: BYOKAgentEndpoint?
        let localModels: [LocalModel]
        let localCapabilities: [ProviderID: ModelCapabilities]
        let appleAvailable: Bool
        let preference: [ProviderID]
    }

    init(
        readCredential: @escaping (String) throws -> String? = { try KeychainStore().readChecked(account: $0) },
        configuredEndpoint: @escaping @MainActor () -> BYOKAgentEndpoint? = { RuntimeCatalog.currentBYOKVisionEndpoint() },
        transport: any HTTPLineStreaming = URLSessionLineStreaming(),
        defaults: UserDefaults = .standard,
        discoverLocalModels: @escaping () async -> [LocalModel] = { await LocalServerDiscovery().discover() },
        codexFactory: (() -> CodexAppServerProvider?)? = nil,
        openAuthenticationURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.openAuthenticationURL = openAuthenticationURL
        self.codexFactory = codexFactory ?? { Self.makeCodexProvider() }
        self.readCredential = readCredential
        self.configuredEndpoint = configuredEndpoint
        self.transport = transport
        self.defaults = defaults
        self.discoverLocalModels = discoverLocalModels
        self.selectedModel = defaults.string(forKey: Self.modelChoiceKey) ?? ModelChoice.chatGPT.rawValue
    }

    static func keychainAccount(for provider: DirectAIProvider) -> String {
        "brain.\(provider.rawValue.lowercased())"
    }

    func refresh() async {
        guard acceptsSetup else { return }
        let generation = setupGeneration
        let discovered = await discoverLocalModels()
        guard acceptsSetup, setupGeneration == generation, !Task.isCancelled else { return }
        localModels = discovered
        localChecks = localChecks.filter { id, state in
            guard localModels.contains(where: { $0.id == id }) else { return false }
            if case .checked(let model, _) = state { return localModels.contains(model) }
            return true
        }
        if modelChoice == ModelChoice.chatGPT.rawValue {
            let status = await codex?.account.status() ?? .unknown
            guard acceptsSetup, setupGeneration == generation, !Task.isCancelled else { return }
            account = status
        }
    }

    func checkLocalModel(_ model: LocalModel) {
        guard acceptsSetup, localModels.contains(model), localCheckTasks[model.id] == nil else { return }
        localChecks[model.id] = .checking
        localCheckTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.localCheckTasks[model.id] = nil }
            do {
                let digits = String(Int.random(in: 100000...999999))
                let image = NSImage(size: NSSize(width: 640, height: 180), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    digits.draw(in: NSRect(x: 80, y: 30, width: 500, height: 120), withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
                        .foregroundColor: NSColor.black
                    ])
                    return true
                }
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let provider = self.localProvider(model, capabilities: [.streaming, .vision, .tools])
                let result = try await ModelCapabilityProbe(provider: provider).run(image: png, expectedImageText: digits)
                try Task.checkCancellation()
                guard self.localModels.contains(model) else { self.localChecks[model.id] = nil; return }
                self.localChecks[model.id] = .checked(model, result)
            } catch is CancellationError {
                self.localChecks[model.id] = nil
            } catch {
                self.localChecks[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLocalCheck(_ model: LocalModel) {
        localCheckTasks[model.id]?.cancel()
    }

    func closeAdmission() {
        acceptsSetup = false
        setupGeneration = UUID()
        cancelSignIn()
        for task in localCheckTasks.values { task.cancel() }
    }

    func reloadPreferences() {
        selectedModel = defaults.string(forKey: Self.modelChoiceKey) ?? ModelChoice.chatGPT.rawValue
    }

    /// True when an on-device provider can answer — Apple Foundation Models
    /// on macOS 26+, or a discovered local model whose capability check
    /// passed. The router picks among them for `.local` scope.
    var onDeviceRouteAvailable: Bool {
        if #available(macOS 26, *), AppleFoundationModelProvider.isAvailable { return true }
        return localChecks.values.contains {
            if case .checked(_, let result) = $0 { return result.text == .passed }
            return false
        }
    }

    /// Onboarding's value-first beat: when the user never picked a model and
    /// an on-device route exists, make it the choice so the first answer
    /// needs no account. An explicit saved choice is never overridden.
    func preferOnDeviceModelIfUnchosen() {
        guard acceptsSetup,
              defaults.string(forKey: Self.modelChoiceKey) == nil,
              onDeviceRouteAvailable else { return }
        modelChoice = ModelChoice.local.rawValue
    }

    func reopenAdmission() {
        if codex == nil { codex = codexFactory() }
        acceptsSetup = true
    }

    func stopSetup() async {
        closeAdmission()
        let tasks = Array(localCheckTasks.values)
        await codex?.shutdown()
        await loginCleanupTask?.value
        loginCleanupTask = nil
        for task in tasks { await task.value }
        codex = nil
        cachedRouting = nil
        account = .unknown
        localModels = []
        localChecks = [:]
        signInError = nil
        activeExplanation = ""
    }

    func router(preference: [ProviderID] = [], scope: ModelChoice? = nil) throws -> ProviderRouter {
        guard acceptsSetup else { throw CancellationError() }
        let endpoint = configuredEndpoint()
        let usesDirect = scope == nil || scope == .direct
        let credentials = try Dictionary(uniqueKeysWithValues: (usesDirect ? DirectAIProvider.allCases : []).compactMap { provider in
            try apiKey(for: provider, endpoint: endpoint).map { (provider, $0) }
        })
        let customCredential: String?
        if usesDirect, let endpoint, endpoint.baseURL.host.flatMap(DirectAIProvider.init(officialHost:)) == nil {
            customCredential = try readCredential(RuntimeCatalog.byokVisionKeychainAccount)
        } else {
            customCredential = nil
        }
        let appleAvailable: Bool
        if #available(macOS 26, *) {
            appleAvailable = AppleFoundationModelProvider.isAvailable
        } else {
            appleAvailable = false
        }
        let configuration = RoutingConfiguration(
            credentials: credentials, customCredential: customCredential, endpoint: endpoint, localModels: localModels,
            localCapabilities: localChecks.compactMapValues { state in
                if case .checked(_, let result) = state, result.text == .passed { return result.capabilities }
                return nil
            },
            appleAvailable: appleAvailable, preference: preference
        )
        if let cachedRouting, cachedRouting.configuration == configuration { return cachedRouting.router }
        let router = ProviderRouter(providers: providers(configuration), preference: preference)
        cachedRouting = (configuration, router)
        return router
    }

    func route(_ requirement: RouteRequirement) async throws -> RouteDecision {
        guard let choice = ModelChoice(rawValue: modelChoice) else {
            throw ModelProviderError(kind: .notConfigured, provider: "settings", message: "Choose a conversation model in Settings. The saved choice is unavailable.")
        }
        var requirement = requirement
        switch choice {
        case .chatGPT:
            requirement.providerID = .codex
        case .direct:
            guard let endpoint = configuredEndpoint() else {
                throw ModelProviderError(kind: .notConfigured, provider: "settings", message: "Add your API provider, model, and credential in Settings.")
            }
            requirement.providerID = endpoint.baseURL.host.flatMap(DirectAIProvider.init(officialHost:))
                .map { ProviderID(rawValue: $0.rawValue.lowercased()) } ?? "custom"
        case .local:
            requirement.providerID = nil
            requirement.capabilities.insert(.local)
        }
        let decision = try await router(scope: choice).route(requirement)
        activeExplanation = decision.explanation
        return decision
    }

    func makeGuidePlanner(
        storageDirectory: URL?,
        prepareRequest: (@MainActor @Sendable (any ModelProvider, ModelRequest) async throws -> ModelRequest)? = nil
    ) -> RuntimeGuidePlanner {
        RuntimeGuidePlanner(complete: { [weak self] prompt, screenshot in
            guard let self else {
                throw ModelProviderError(kind: .unavailable, provider: "guide", message: "Perry is shutting down.")
            }
            try Task.checkCancellation()
            let selected = try await self.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .deep)).provider
            var parts: [ModelContentPart] = [.text(prompt)]
            if let (data, mimeType) = screenshot { parts.append(.image(data: data, mimeType: mimeType)) }
            let capacity = try await selected.contextWindow(for: .deep)
            try Task.checkCancellation()
            var request = ModelRequest(
                system: "Return the requested Guide JSON only. Guide explains actions for the user to perform; do not perform actions or call tools.",
                messages: [.user(parts)], tier: .deep, maxOutputTokens: 2048
            )
            if let prepareRequest { request = try await prepareRequest(selected, request) }
            request = try request.reservingOutput(in: capacity)
            var text = ""
            var completed = false
            for try await event in selected.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    text += delta
                    guard text.utf8.count <= 65_536 else {
                        throw ModelProviderError(kind: .malformed, provider: selected.id, message: "The Guide response was too large. Try a more specific request.")
                    }
                case .done(.endTurn): completed = true
                case .done, .toolCall:
                    throw ModelProviderError(kind: .malformed, provider: selected.id, message: "The model did not finish a usable Guide response. Try again.")
                case .usage: break
                }
            }
            try Task.checkCancellation()
            guard completed else {
                throw ModelProviderError(kind: .malformed, provider: selected.id, message: "The Guide response ended before completion. Try again.")
            }
            return text
        }, skillLibrary: AppSkillLibrary(storageDirectory: storageDirectory))
    }

    func signInWithChatGPT(onCompletion: @escaping (Bool) -> Void = { _ in }) {
        guard acceptsSetup, !isSigningIn else { return }
        guard let codex else {
            signInError = "Perry’s bundled ChatGPT connection is missing. Reinstall Perry to restore it."
            onCompletion(false)
            return
        }
        isSigningIn = true
        signInError = nil
        let attempt = UUID()
        loginAttempt = attempt
        let previousCleanup = loginCleanupTask
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loginAttempt == attempt {
                    self.isSigningIn = false
                    self.loginTask = nil
                    self.loginID = nil
                }
            }
            do {
                await previousCleanup?.value
                try Task.checkCancellation()
                guard self.loginAttempt == attempt else { return }
                let events = try await codex.account.loginEvents()
                let session = try await codex.account.signIn()
                guard self.loginAttempt == attempt, !Task.isCancelled else {
                    try await codex.account.cancelSignIn(id: session.id)
                    return
                }
                self.loginID = session.id
                guard self.openAuthenticationURL(session.url) else {
                    try await codex.account.cancelSignIn(id: session.id)
                    throw ModelProviderError(kind: .unavailable, provider: .codex, message: "Couldn’t open your browser. Try again.")
                }
                for await event in events {
                    try Task.checkCancellation()
                    if case .completed(let success, let id, let message) = event, id == session.id {
                        guard success else {
                            self.signInError = message ?? "Sign-in wasn’t completed. Try again when you’re ready."
                            onCompletion(false)
                            return
                        }
                        await self.refresh()
                        guard self.loginAttempt == attempt, !Task.isCancelled else { return }
                        if case .signedIn = self.account {
                            onCompletion(true)
                        } else {
                            self.signInError = "Sign-in completed, but Perry couldn’t verify the account. Try again."
                            onCompletion(false)
                        }
                        return
                    }
                }
                guard self.loginAttempt == attempt else { return }
                self.signInError = "The sign-in connection closed. Try again."
                onCompletion(false)
            } catch is CancellationError {
                if self.loginAttempt == attempt { onCompletion(false) }
            } catch {
                guard self.loginAttempt == attempt else { return }
                self.signInError = error.localizedDescription
                onCompletion(false)
            }
        }
    }

    func cancelSignIn() {
        loginAttempt = nil
        let cancelledLogin = loginTask
        cancelledLogin?.cancel()
        let previousCleanup = loginCleanupTask
        let cancelledID = loginID
        let provider = cancelledID == nil ? nil : codex
        let generation = setupGeneration
        loginCleanupTask = Task {
            await previousCleanup?.value
            if let cancelledID, let provider {
                do { try await provider.account.cancelSignIn(id: cancelledID) }
                catch {
                    if self.acceptsSetup, self.setupGeneration == generation, self.loginAttempt == nil {
                        self.signInError = "Couldn’t cancel the browser sign-in. Close its browser tab. \(error.localizedDescription)"
                    }
                }
            }
            await cancelledLogin?.value
        }
        loginID = nil
        loginTask = nil
        isSigningIn = false
    }

    func signOut() async {
        guard acceptsSetup else { return }
        let generation = setupGeneration
        cancelSignIn()
        await loginCleanupTask?.value
        guard acceptsSetup, setupGeneration == generation else { return }
        do { try await codex?.account.signOut() }
        catch {
            guard acceptsSetup, setupGeneration == generation else { return }
            signInError = error.localizedDescription
        }
        guard acceptsSetup, setupGeneration == generation else { return }
        await refresh()
    }

    private func providers(_ configuration: RoutingConfiguration) -> [any ModelProvider] {
        var result: [any ModelProvider] = []
        if let codex { result.append(codex) }
        for provider in DirectAIProvider.allCases {
            guard let key = configuration.credentials[provider] else { continue }
            let keyProvider: @Sendable () -> String? = { key }
            let endpoint = configuration.endpoint.flatMap {
                $0.baseURL.host.flatMap(DirectAIProvider.init(officialHost:)) == provider ? $0 : nil
            }
            let models = endpoint.map { BrainModelDefaults(fast: $0.model, deep: $0.model) }
            let baseURL = endpoint?.baseURL ?? provider.defaultBaseURL
            switch provider {
            case .openAI:
                result.append(OpenAIResponsesProvider(baseURL: baseURL, apiKeyProvider: keyProvider, models: models ?? BrainModelCatalog.openAI, transport: transport))
            case .anthropic:
                result.append(AnthropicMessagesProvider(baseURL: baseURL, apiKeyProvider: keyProvider, models: models ?? BrainModelCatalog.anthropic, transport: transport))
            case .gemini:
                result.append(GeminiProvider(baseURL: baseURL, apiKeyProvider: keyProvider, models: models ?? BrainModelCatalog.gemini, transport: transport))
            case .openRouter:
                result.append(OpenAIChatCompatibleProvider(
                    id: .openRouter, displayName: "OpenRouter", baseURL: baseURL,
                    apiKeyProvider: keyProvider, models: models ?? BrainModelCatalog.openRouter,
                    capabilities: [.vision, .tools, .streaming], transport: transport
                ))
            }
        }
        if let endpoint = configuration.endpoint, let key = configuration.customCredential, !key.isEmpty {
            result.append(OpenAIChatCompatibleProvider(
                id: "custom", displayName: "My API provider", baseURL: endpoint.baseURL,
                apiKeyProvider: { key }, models: BrainModelDefaults(fast: endpoint.model, deep: endpoint.model),
                capabilities: [.vision, .tools, .streaming], transport: transport
            ))
        }
        for model in configuration.localModels {
            guard let capabilities = configuration.localCapabilities[model.id] else { continue }
            result.append(localProvider(model, capabilities: capabilities))
        }
        if #available(macOS 26, *), configuration.appleAvailable {
            result.append(AppleFoundationModelProvider())
        }
        return result
    }

    private func localProvider(_ model: LocalModel, capabilities: ModelCapabilities) -> OpenAIChatCompatibleProvider {
        OpenAIChatCompatibleProvider(
            id: model.id, displayName: "\(model.name) (on this Mac)", baseURL: model.baseURL,
            models: BrainModelDefaults(fast: model.name, deep: model.name),
            capabilities: capabilities, transport: transport,
            contextWindow: { _ in try await LocalServerDiscovery(timeout: 2).loadedContextWindow(for: model) }
        )
    }

    private func apiKey(for provider: DirectAIProvider, endpoint: BYOKAgentEndpoint?) throws -> String? {
        if let key = try readCredential(Self.keychainAccount(for: provider)), !key.isEmpty {
            return key
        }
        guard let endpoint,
              endpoint.baseURL.host.flatMap(DirectAIProvider.init(officialHost:)) == provider,
              let legacy = try readCredential(RuntimeCatalog.byokVisionKeychainAccount),
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
            binaryURL: binary, codexHome: home, workingDirectory: workingDirectory,
            stderrLogURL: home.appendingPathComponent("app-server-stderr.log")
        )), models: BrainModelCatalog.codex)
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
