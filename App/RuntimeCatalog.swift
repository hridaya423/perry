import AppKit
import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

/// Owns runtime inventory inspection and BYOK provider configuration.
/// Session-state checks and status text stay outside — callers pass them in.
@MainActor
final class RuntimeCatalog: ObservableObject {
    static let byokVisionKeychainAccount = "byok.vision"

    private let setStatus: (String) -> Void

#if DEBUG
    typealias InventoryLoader = @MainActor () async throws -> RuntimeInventory
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
                guard let profile = ModelProfileStore(defaults: .standard).active(),
                      let key = try KeychainStore().readChecked(account: profile.keyAccount),
                      !key.isEmpty else { return nil }
                return ConfiguredDirectRuntime(endpoint: BYOKAgentEndpoint(baseURL: profile.baseURL, model: profile.model), credential: key)
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
    func inspect() async throws -> RuntimeInventory {
#if DEBUG
        if let debugInventoryLoader {
            return try await debugInventoryLoader()
        }
#endif
        let key = await inventoryCacheKey()
        if let cached = cachedInventory, cached.key == key,
           Date().timeIntervalSince(cached.at) < inventoryCacheTTL {
            return cached.inventory
        }
        let inventory = try await inspector.inspect()
        cachedInventory = (key, Date(), inventory)
        return inventory
    }

    func invalidateRuntimeInventory() {
        cachedInventory = nil
    }

    /// Cheap fingerprint of everything inspection can report differently:
    /// each CLI's located executable (path+mtime+size), the bundled Codex
    /// data directory's contents (auth writes land there), the BYOK endpoint
    /// and model. locate+stat only — no hashing,
    /// no spawned probes.
    private func inventoryCacheKey() async -> String {
        var parts: [String] = []
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
        if let profile = ModelProfileStore(defaults: .standard).active() {
            parts.append("byok:\(profile.baseURL.absoluteString)/\(profile.model)")
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
        switch id {
        case "cli.codex": return "Bundled Codex"
        case "cli.claude-code": return "Claude Code"
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
}

enum SetupState: Equatable {
    case ready(detail: String)
    case needsSignIn
    case notInstalled
    case unchecked
}

extension RuntimeSetupSnapshot {
    func setupStates(chatGPTEmail: String?, acpInstalled: Bool) -> [BrainController.ModelChoice: SetupState] {
        [
            .chatGPT: state(of: "cli.codex", readyDetail: chatGPTEmail ?? "Signed in with ChatGPT"),
            .claudeCode: state(of: "cli.claude-code", readyDetail: "Signed in with Claude Code"),
            .acp: acpInstalled ? .ready(detail: "Installed") : .notInstalled,
            .direct: .unchecked,
            .local: .unchecked,
        ]
    }

    private func state(of id: String, readyDetail: String) -> SetupState {
        guard !records.isEmpty else { return .unchecked }
        guard let record = records.first(where: { $0.id == id }) else { return .notInstalled }
        switch record.authentication {
        case nil: return .notInstalled
        case .authenticated?: return .ready(detail: readyDetail)
        case .missing?, .invalid?: return .needsSignIn
        case .notRequired?, .configured?, .unknown?: return .unchecked
        }
    }
}
