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
        case chatGPT, claudeCode, acp, direct, local

        var title: String {
            switch self {
            case .chatGPT: "ChatGPT"
            case .claudeCode: "Claude Code"
            case .acp: "Another agent (ACP)"
            case .direct: "My API provider"
            case .local: "On this Mac"
            }
        }
    }

    @Published private var selectedModel: ModelChoice
    var modelChoice: ModelChoice {
        get { selectedModel }
        set {
            guard acceptsSetup else { return }
            selectedModel = newValue
            defaults.set(newValue.rawValue, forKey: PerryPreferences.$modelChoice.key)
        }
    }

    private static func savedChoice(in defaults: UserDefaults) -> ModelChoice {
        guard let raw = defaults.string(forKey: PerryPreferences.$modelChoice.key) else { return .chatGPT }
        return ModelChoice(rawValue: raw) ?? .local
    }
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInError: String?
    @Published private(set) var account: CodexAccountStatus = .unknown
    @Published private(set) var localModels: [LocalModel] = []
    @Published private(set) var localChecks: [ProviderID: LocalCheckState] = [:]
    @Published private(set) var activeExplanation = ""
    @Published private(set) var profiles: [ModelProfile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var profileChecks: [String: ProfileCheckState] = [:]
    @Published private(set) var acpAgent: AcpAgent?

    private let readCredential: (String) throws -> String?
    private let saveCredential: (String, String) throws -> Void
    private let deleteCredential: (String) throws -> Void
    private let profileStore: ModelProfileStore
    private let transport: any HTTPLineStreaming
    private let defaults: UserDefaults
    private let discoverLocalModels: () async -> [LocalModel]
    private let openAuthenticationURL: (URL) -> Bool
    private let codexFactory: () -> CodexAppServerProvider?
    private lazy var codex: CodexAppServerProvider? = codexFactory()
    var toolScopes: (any MCPScopeHost)?
    private lazy var claudeCode: ClaudeCodeProvider? = Self.makeClaudeCodeProvider(scopes: toolScopes)
    private var acceptsSetup = true
    private var setupGeneration = UUID()
    private var loginCleanupTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginAttempt: UUID?
    private var loginID: String?
    private var cachedRouting: (configuration: RoutingConfiguration, router: ProviderRouter)?
    private var localCheckTasks: [ProviderID: Task<Void, Never>] = [:]
    private var profileCheckTasks: [String: Task<Void, Never>] = [:]

    enum LocalCheckState: Equatable {
        case checking
        case checked(LocalModel, ModelCapabilityProbe.Result)
        case failed(String)
    }

    enum ProfileCheckState: Equatable {
        case checking
        case checked(model: String, ModelCapabilityProbe.Result)
        case failed(String)
    }

    private struct RoutingConfiguration: Equatable {
        let profile: ModelProfile?
        let profileKey: String?
        let profileCapabilities: ModelCapabilities?
        let acpAgent: AcpAgent?
        let localModels: [LocalModel]
        let localCapabilities: [ProviderID: ModelCapabilities]
        let appleAvailable: Bool
        let preference: [ProviderID]
    }

    init(
        readCredential: @escaping (String) throws -> String? = { try KeychainStore().readChecked(account: $0) },
        saveCredential: @escaping (String, String) throws -> Void = { try KeychainStore().save($0, account: $1) },
        deleteCredential: @escaping (String) throws -> Void = { try KeychainStore().deleteChecked(account: $0) },
        transport: any HTTPLineStreaming = URLSessionLineStreaming(),
        defaults: UserDefaults = .standard,
        discoverLocalModels: @escaping () async -> [LocalModel] = { await LocalServerDiscovery().discover() },
        codexFactory: (() -> CodexAppServerProvider?)? = nil,
        openAuthenticationURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.openAuthenticationURL = openAuthenticationURL
        self.codexFactory = codexFactory ?? { Self.makeCodexProvider() }
        self.readCredential = readCredential
        self.saveCredential = saveCredential
        self.deleteCredential = deleteCredential
        self.transport = transport
        self.defaults = defaults
        self.profileStore = ModelProfileStore(defaults: defaults)
        self.discoverLocalModels = discoverLocalModels
        self.selectedModel = Self.savedChoice(in: defaults)
        reloadProfiles()
        acpAgent = defaults.data(forKey: PerryPreferences.$acpAgent.key).flatMap { try? JSONDecoder().decode(AcpAgent.self, from: $0) }
    }

    func setAcpAgent(_ agent: AcpAgent) {
        guard acceptsSetup, let data = try? JSONEncoder().encode(agent) else { return }
        defaults.set(data, forKey: PerryPreferences.$acpAgent.key)
        acpAgent = agent
        modelChoice = .acp
    }

    var acpAgentAvailable: Bool { acpAgent?.executable() != nil }

    var claudeCodeAvailable: Bool { claudeCode != nil }

    var activeProfile: ModelProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    func reloadProfiles() {
        profiles = profileStore.load()
        activeProfileID = profileStore.activeID
    }

    func addProfile(_ profile: ModelProfile, key: String?) throws {
        guard acceptsSetup else { return }
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try saveCredential(key, profile.keyAccount)
        }
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        profileStore.save(profiles)
        setActiveProfile(profile.id)
    }

    func removeProfile(_ profile: ModelProfile) throws {
        guard acceptsSetup else { return }
        if !profiles.contains(where: { $0.id != profile.id && $0.keyAccount == profile.keyAccount }) {
            try deleteCredential(profile.keyAccount)
        }
        profiles.removeAll { $0.id == profile.id }
        profileStore.save(profiles)
        profileChecks[profile.id] = nil
        if activeProfileID == profile.id {
            profileStore.activeID = profiles.first?.id
            activeProfileID = profiles.first?.id
        }
    }

    func setActiveProfile(_ id: String) {
        guard acceptsSetup, profiles.contains(where: { $0.id == id }) else { return }
        profileStore.activeID = id
        activeProfileID = id
        modelChoice = .direct
    }

    func hasCredential(_ profile: ModelProfile) -> Bool {
        ((try? readCredential(profile.keyAccount)) ?? nil)?.isEmpty == false
    }

    func checkProfile(_ profile: ModelProfile) {
        guard acceptsSetup, profileCheckTasks[profile.id] == nil else { return }
        profileChecks[profile.id] = .checking
        profileCheckTasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.profileCheckTasks[profile.id] = nil }
            do {
                let key = try self.readCredential(profile.keyAccount)
                let provider = profile.preset.makeProvider(
                    id: profile.providerID, displayName: profile.displayName, baseURL: profile.baseURL, key: key,
                    models: profile.models, capabilities: [.streaming, .vision, .tools], transport: self.transport
                )
                let (png, digits) = try Self.probeImage()
                let result = try await ModelCapabilityProbe(provider: provider).run(image: png, expectedImageText: digits)
                try Task.checkCancellation()
                guard self.profiles.contains(profile) else { self.profileChecks[profile.id] = nil; return }
                self.profileChecks[profile.id] = .checked(model: profile.model, result)
            } catch is CancellationError {
                self.profileChecks[profile.id] = nil
            } catch {
                self.profileChecks[profile.id] = .failed(error.localizedDescription)
            }
        }
    }

    private static func probeImage() throws -> (png: Data, digits: String) {
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
        return (png, digits)
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
        if modelChoice == .chatGPT {
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
                let (png, digits) = try Self.probeImage()
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
        for task in profileCheckTasks.values { task.cancel() }
    }

    func reloadPreferences() {
        selectedModel = Self.savedChoice(in: defaults)
        reloadProfiles()
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
              defaults.string(forKey: PerryPreferences.$modelChoice.key) == nil,
              onDeviceRouteAvailable else { return }
        modelChoice = .local
    }

    func reopenAdmission() {
        if codex == nil { codex = codexFactory() }
        acceptsSetup = true
    }

    func stopSetup() async {
        closeAdmission()
        let tasks = Array(localCheckTasks.values) + Array(profileCheckTasks.values)
        await codex?.shutdown()
        await loginCleanupTask?.value
        loginCleanupTask = nil
        for task in tasks { await task.value }
        codex = nil
        cachedRouting = nil
        account = .unknown
        localModels = []
        localChecks = [:]
        profileChecks = [:]
        signInError = nil
        activeExplanation = ""
    }

    func router(preference: [ProviderID] = [], scope: ModelChoice? = nil) throws -> ProviderRouter {
        guard acceptsSetup else { throw CancellationError() }
        let usesDirect = scope == nil || scope == .direct
        let profile = usesDirect ? activeProfile : nil
        let profileKey = try profile.flatMap { try readCredential($0.keyAccount) }
        let appleAvailable: Bool
        if #available(macOS 26, *) {
            appleAvailable = AppleFoundationModelProvider.isAvailable
        } else {
            appleAvailable = false
        }
        let profileCapabilities = profile.flatMap { profile -> ModelCapabilities? in
            guard case .checked(let model, let result) = profileChecks[profile.id], model == profile.model,
                  result.text == .passed else { return nil }
            return result.capabilities
        }
        let configuration = RoutingConfiguration(
            profile: profile, profileKey: profileKey, profileCapabilities: profileCapabilities,
            acpAgent: scope == nil || scope == .acp ? acpAgent : nil, localModels: localModels,
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
        let choice = modelChoice
        var requirement = requirement
        switch choice {
        case .chatGPT:
            guard account != .signedOut else {
                throw ModelProviderError(kind: .notConfigured, provider: .codex, message: PromptAssembler.noBrainAnswer)
            }
            requirement.providerID = .codex
        case .acp:
            guard let acpAgent, acpAgentAvailable else {
                throw ModelProviderError(kind: .notConfigured, provider: "settings", message: "Choose an installed agent in Settings, Models.")
            }
            requirement.providerID = ProviderID(rawValue: "acp.\(acpAgent.id)")
        case .claudeCode:
            guard claudeCode != nil else {
                throw ModelProviderError(kind: .notConfigured, provider: .claudeCode, message: "Install Claude Code and sign in with `claude`, then choose it again in Settings.")
            }
            requirement.providerID = .claudeCode
        case .direct:
            guard let profile = activeProfile else {
                throw ModelProviderError(kind: .notConfigured, provider: "settings", message: "Add your API provider, model, and credential in Settings.")
            }
            requirement.providerID = profile.providerID
        case .local:
            requirement.providerID = nil
            requirement.capabilities.insert(.local)
        }
        let decision = try await router(scope: choice).route(requirement)
        activeExplanation = decision.explanation
        return decision
    }

    /// Single fast text completion through whatever brain the user chose —
    /// used for polish passes like routine naming.
    func completeText(_ prompt: String) async throws -> String {
        let decision = try await route(RouteRequirement(tier: .fast))
        var text = ""
        for try await event in decision.provider.stream(ModelRequest(
            messages: [.user([.text(prompt)])],
            tier: .fast
        )) {
            try Task.checkCancellation()
            if case .textDelta(let delta) = event {
                text += delta
            }
        }
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModelProviderError(kind: .malformed, provider: decision.provider.id, message: "The model returned an empty response. Try again.")
        }
        return trimmed
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
        if let claudeCode { result.append(claudeCode) }
        if let agent = configuration.acpAgent, let executable = agent.executable() {
            result.append(AcpAgentProvider(agent: agent, executable: executable, helper: Bundle.main.url(forAuxiliaryExecutable: "perry-mcp"), scopes: toolScopes))
        }
        if let profile = configuration.profile {
            let key = configuration.profileKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !profile.preset.keyRequired || key?.isEmpty == false {
                result.append(profile.preset.makeProvider(
                    id: profile.providerID, displayName: profile.displayName, baseURL: profile.baseURL, key: key,
                    models: profile.models, capabilities: configuration.profileCapabilities ?? [.vision, .tools, .streaming],
                    transport: transport
                ))
            }
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

    private static func makeClaudeCodeProvider(scopes: (any MCPScopeHost)?) -> ClaudeCodeProvider? {
        guard let executable = try? CLIRuntime.locateExecutable() else { return nil }
        return ClaudeCodeProvider(
            executable: executable,
            helper: Bundle.main.url(forAuxiliaryExecutable: "perry-mcp"),
            scopes: scopes
        )
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
                        report("\(text) (first words in \(firstDelta ?? 0) ms)")
                    }
                }
            } catch {
                report("Brain smoke test failed: \(error.localizedDescription)")
            }
        }
    }
#endif
}
