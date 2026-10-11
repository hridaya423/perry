import AppKit
import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

/// Owns runtime routing: inventory inspection, provider selection for a goal,
/// the user-facing runtime choices list, and BYOK provider configuration.
/// Session-state checks and status text stay outside — callers pass them in.
@MainActor
final class RuntimeCatalog: ObservableObject {
    static let byokVisionKeychainAccount = "byok.vision"

    @Published private(set) var choices = [RuntimeChoice(id: RuntimeChoice.automaticID, name: "Automatic")]

    private let setStatus: (String) -> Void
    private var choicesRefreshTask: Task<Void, Never>?

#if DEBUG
    typealias InventoryLoader = @MainActor (URL?) async throws -> RuntimeInventory
    private let debugInventoryLoader: InventoryLoader?

    init(
        setStatus: @escaping (String) -> Void,
        inventoryLoader: InventoryLoader? = nil
    ) {
        self.setStatus = setStatus
        self.debugInventoryLoader = inventoryLoader
    }
#else
    init(setStatus: @escaping (String) -> Void) {
        self.setStatus = setStatus
    }
#endif

    private var inspector: RuntimeInventoryInspector {
        RuntimeInventoryInspector(
            readDirectProvider: {
                guard let endpoint = Self.currentBYOKVisionEndpoint(),
                      let key = try KeychainStore().readChecked(account: Self.byokVisionKeychainAccount),
                      !key.isEmpty else { return nil }
                return ConfiguredDirectRuntime(endpoint: endpoint, credential: key)
            },
            commandLineProviders: RuntimeCLIDefinition.production(codexRuntimeHome: Self.codexRuntimeHome)
        )
    }

    static var codexRuntimeHome: URL? {
        AppController.supportDirectory?.appendingPathComponent("CodexRuntime", isDirectory: true)
    }

    private var cachedInventory: (key: String, at: Date, inventory: RuntimeInventory)?
    private let inventoryCacheTTL: TimeInterval = 30

    /// Inspecting is expensive — SHA-256 over each runtime executable plus a
    /// spawned auth probe per CLI — so the result is cached briefly, keyed by
    /// everything that can change the answer. `currentSetup` bypasses it: an
    /// explicit Settings refresh must always see the real state.
    func inspect(workingDirectory: URL? = nil) async throws -> RuntimeInventory {
#if DEBUG
        if let debugInventoryLoader {
            return try await debugInventoryLoader(workingDirectory)
        }
#endif
        let key = await inventoryCacheKey(workingDirectory: workingDirectory)
        if let cached = cachedInventory, cached.key == key,
           Date().timeIntervalSince(cached.at) < inventoryCacheTTL {
            return cached.inventory
        }
        let inventory = try await inspector.inspect(workingDirectory: workingDirectory)
        cachedInventory = (key, Date(), inventory)
        return inventory
    }

    func invalidateRuntimeInventory() {
        cachedInventory = nil
    }

    /// Cheap fingerprint of everything inspection can report differently:
    /// each CLI's located executable (path+mtime+size), the bundled Codex
    /// data directory's contents (auth writes land there), the BYOK endpoint
    /// and model, and the working directory. locate+stat only — no hashing,
    /// no spawned probes.
    private func inventoryCacheKey(workingDirectory: URL?) async -> String {
        var parts = [workingDirectory?.path ?? "-"]
        for definition in RuntimeCLIDefinition.production(codexRuntimeHome: Self.codexRuntimeHome) {
            do {
                let url = try definition.locate().resolvingSymlinksInPath().standardizedFileURL
                parts.append("\(definition.name):\(url.path):\(Self.fileStamp(url))")
            } catch {
                parts.append("\(definition.name):absent")
            }
        }
        if let home = Self.codexRuntimeHome,
           let entries = try? FileManager.default.contentsOfDirectory(atPath: home.path) {
            let stamp = entries.sorted().map { name in
                "\(name)=\(Self.fileStamp(home.appendingPathComponent(name)))"
            }.joined(separator: ",")
            parts.append("codexHome:\(stamp)")
        }
        if let endpoint = Self.currentBYOKVisionEndpoint() {
            parts.append("byok:\(endpoint.baseURL.absoluteString)/\(endpoint.model)")
        }
        return parts.joined(separator: "|")
    }

    static func fileStamp(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "missing"
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(mtime):\(size)"
    }

    /// Selects a provider for one attempt. `attemptIsCurrent` is the caller's
    /// staleness check — it is consulted after each suspension so a superseded
    /// attempt cannot keep routing.
    func select(
        workingDirectory: URL?,
        preferredProviderID requestedProviderID: RuntimeProviderID? = nil,
        goal: String? = nil,
        attemptID: UUID? = nil,
        attemptIsCurrent: (UUID) -> Bool = { _ in true }
    ) async -> ProductionRuntimeSelection? {
        func current(_ attemptID: UUID?) -> Bool {
            guard let attemptID else { return true }
            return attemptIsCurrent(attemptID)
        }
        do {
            let inventory = try await inspect(workingDirectory: workingDirectory)
            guard current(attemptID) else { return nil }
            if let failure = inventory.credentialFailure {
                guard current(attemptID) else { return nil }
                setStatus(failure)
            }
            let route = Self.foregroundRouteRequirements(for: goal)
            return ProductionRuntimeSelector().select(
                from: inventory.registry,
                preferredProviderID: requestedProviderID ?? inventory.automaticPreference,
                requiredCapabilities: route.capabilities,
                requiredOperations: route.operations
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard current(attemptID) else { return nil }
            setStatus("Perry could not inspect the available runtimes. Try refreshing runtime setup.")
            return nil
        }
    }

    static func foregroundRouteRequirements(for goal: String?) -> (
        capabilities: Set<RuntimeCapability>,
        operations: Set<RuntimeOperation>
    ) {
        guard let goal, LocalTaskPlannerRuntime.supportsWorkspaceExecutionGoal(goal) else {
            return ([], [.planning])
        }
        return ([.fileIO], [.planning, .execution])
    }

    func cancelPendingRefreshes() {
        choicesRefreshTask?.cancel()
    }

    func refreshChoices() {
        choicesRefreshTask?.cancel()
        choicesRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let choices = await self.availableChoices()
            guard !Task.isCancelled else { return }
            self.choices = choices
        }
    }

    /// Whether any runtime beyond the planning-only local planner is offered —
    /// i.e. something exists that can actually take a task over. The panel uses
    /// this for its inline "no runtime" recovery; `start` still re-validates.
    var hasExecutionCapableChoice: Bool {
        choices.contains { $0.id != RuntimeChoice.automaticID && $0.id != "local.task-planner" }
    }

    func availableChoices() async -> [RuntimeChoice] {
        do {
            let inventory = try await inspect()
            if let failure = inventory.credentialFailure { setStatus(failure) }
            return inventory.choices
        } catch is CancellationError {
            return []
        } catch {
            setStatus("Perry could not inspect the available runtimes. Try refreshing runtime setup.")
            return []
        }
    }

    /// Settings and explicit refresh surfaces call this — always re-inspect.
    func currentSetup() async -> RuntimeSetupSnapshot {
        invalidateRuntimeInventory()
        do {
            return try await inspect().setup
        } catch is CancellationError {
            return RuntimeSetupSnapshot(summary: "Runtime inspection was canceled.", records: [])
        } catch {
            return RuntimeSetupSnapshot(summary: "Perry could not inspect the available runtimes. Try refreshing runtime setup.", records: [])
        }
    }

    func name(for id: String) -> String {
        if let choice = choices.first(where: { $0.id == id }) {
            return choice.name
        }
        switch id {
        case "cli.codex": return "Bundled Codex"
        case "cli.claude-code": return "Claude Code"
        case "cli.opencode": return "OpenCode"
        case "local.task-planner": return "Perry local planner"
        case "local.workspace-files": return "Perry workspace files"
        case "byok.vision": return "Custom provider"
        case DirectAIProvider.openAI.runtimeID: return DirectAIProvider.openAI.displayName
        case DirectAIProvider.anthropic.runtimeID: return DirectAIProvider.anthropic.displayName
        case DirectAIProvider.gemini.runtimeID: return DirectAIProvider.gemini.displayName
        case DirectAIProvider.openRouter.runtimeID: return DirectAIProvider.openRouter.displayName
        default: return id
        }
    }

    static func providerID(from preference: String?) -> RuntimeProviderID? {
        guard let preference,
              preference != RuntimeChoice.automaticID else { return nil }
        return RuntimeProviderID(rawValue: preference)
    }

    static func currentBYOKVisionEndpoint() -> BYOKAgentEndpoint? {
        guard let rawURL = PerryPreferences.byokVisionEndpoint,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil,
              let model = PerryPreferences.byokVisionModel,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return BYOKAgentEndpoint(baseURL: url, model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
