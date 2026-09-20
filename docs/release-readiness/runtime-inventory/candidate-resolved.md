# Candidate: resolved-runtime inventory

## Problem

`AppController.makeRuntime`, `currentRuntimeSetup`, `availableRuntimeChoices`, and `demoPreflight` each reconstruct provider facts. Settings and task startup can also locate a CLI at different times, so the copied authentication command and the runtime factory are not guaranteed to describe the executable that was verified. The parent extraction leaves `RuntimeReadiness`, `RuntimeSetupRecord`, `RuntimeSetupSnapshot`, `RuntimeChoice`, and `RuntimeAuthenticationCommand` in `App/RuntimeSetup.swift`; this candidate keeps that seam.

The current release contract is the authority: one typed registry, Codex and OpenCode pins, Claude's Anthropic identity check, official authentication after identity verification, planning-only direct and installed non-Codex providers, Codex's private runtime home, cancellation without partial publication, explicit preference and fallback explanations, and a fresh task-start inspection. A Settings snapshot is display state, never an authorization grant.

## Usage (caller's view)

Consumers ask one service for an immutable inspection. They do not locate CLIs, read credentials, or switch on provider IDs.

```swift
let inventory = try await runtimeInventory.inspect(workingDirectory: workspace)
let selection = inventory.select(preferredProviderID: requestedProviderID)
```

Settings loads the setup projection, while `RuntimeSettingsState`'s load closure becomes throwing so cancellation reaches the inventory boundary.

```swift
let settingsState = RuntimeSettingsState {
    let snapshot = try await runtimeInventory.inspect()
    return .init(setup: snapshot.setup, cuaStatus: await currentCuaDriverStatus())
}
```

The picker refreshes from the same snapshot shape, and task startup calls `inspect(workingDirectory:)` again rather than reusing Settings state.

```swift
let snapshot = try await runtimeInventory.inspect()
runtimeChoices = snapshot.choices

let taskSnapshot = try await runtimeInventory.inspect(workingDirectory: workspace)
let taskSelection = taskSnapshot.select(preferredProviderID: requestedProviderID)
```

Demo preflight consumes `hasReadyCLIPlanner` from a fresh snapshot for its existing message, then `beginDo` performs its own fresh task inspection and keeps the existing automatic route.

## Shape

The core is an exhaustive sum. Each case carries a `RuntimeProvider` whose `RuntimeProviderDescriptor` is the existing typed registry descriptor, plus only the provider-specific value needed by projections or runtime construction.

```swift
enum ResolvedRuntime {
    case directAPI(registered: RuntimeProvider, configuration: DirectProviderConfiguration)
    case custom(registered: RuntimeProvider, endpoint: BYOKAgentEndpoint)
    case codex(registered: RuntimeProvider, executable: URL, readiness: RuntimeReadiness)
    case claude(registered: RuntimeProvider, executable: URL, readiness: RuntimeReadiness)
    case openCode(registered: RuntimeProvider, executable: URL, readiness: RuntimeReadiness)
    case local(registered: RuntimeProvider)

    var provider: RuntimeProvider { get }
    var descriptor: RuntimeProviderDescriptor { get }
    var runtime: any AgentRuntime { get }
    var setupRecord: RuntimeSetupRecord? { get }
    var isPlanningChoice: Bool { get }
}

struct RuntimeInventorySnapshot {
    let entries: [ResolvedRuntime]
    let registry: RuntimeProviderRegistry
    let setup: RuntimeSetupSnapshot
    let choices: [RuntimeChoice]
    let automaticPreference: RuntimeProviderID?

    func select(preferredProviderID: RuntimeProviderID?) -> ProductionRuntimeSelection?
    var hasReadyCLIPlanner: Bool { get }
    func displayName(for providerID: RuntimeProviderID) -> String
}

enum RuntimeCLIInspection {
    case verified(executable: URL, identity: RuntimeInstallationIdentity, authentication: RuntimeAuthenticationStatus)
    case rejected(executable: URL, installation: RuntimeInstallationStatus)
}

protocol RuntimeInventoryProbe: Sendable {
    func inspectCodex() async throws -> RuntimeCLIInspection?
    func inspectClaude() async throws -> RuntimeCLIInspection?
    func inspectOpenCode() async throws -> RuntimeCLIInspection?
}

struct ConfiguredDirectProvider {
    let endpoint: BYOKAgentEndpoint
    let key: String
}

struct RuntimeInventoryService {
    init(
        codexRuntimeHome: URL?,
        readDirectProvider: @escaping () throws -> ConfiguredDirectProvider?,
        probe: any RuntimeInventoryProbe
    )
    func inspect(workingDirectory: URL? = nil) async throws -> RuntimeInventorySnapshot
}
```

`LiveRuntimeInventoryProbe` locates each CLI once, verifies the located URL with `RuntimeExecutableVerifier`, and only then runs the matching official authentication probe on that same URL. A rejected inspection carries no authentication result, so the service cannot construct login commands for an unverified executable. Runtime factories capture that URL; Codex also receives `codexRuntimeHome` and its descriptor keeps `.workspace` plus `.planning` and `.execution`.

The service assembles entries in direct API, Codex, Claude, OpenCode, and local order. Direct API uses `DirectProviderRuntime` with `.configured` and `.planning`; custom uses `BYOKAgentRuntime` with `.configured`, `.customEndpoint`, and `.planning`; Claude and OpenCode use `.officialCLI`, `.readOnly`, and `.planning`; local uses `.local`, `.notRequired`, and `.planning`. Codex, Claude, OpenCode, and local retain priorities 10, 20, 30, and 100, while configured direct providers retain priority 0.

`RuntimeInventorySnapshot` builds the one `RuntimeProviderRegistry` from `entries`; `select` delegates to `ProductionRuntimeSelector`, which continues to call the registry's existing eligibility and fallback algorithm. `setup`, `choices`, `hasReadyCLIPlanner`, and display names are immutable projections of the same entries, with the current automatic choice, CLI ordering, local choice, configured-credential choice, and route explanations preserved. The enum owns the exhaustive switches, so adding a provider fails at the central projection boundary instead of creating identifier switches in callers.

`RuntimeExecutableVerifier` remains the only owner of immutable Codex/OpenCode pins and Claude's signing requirement. The service accepts no version, checksum, signing requirement, endpoint policy, or auth policy from callers. Cancellation is rethrown by the probe and checked between entries; `inspect` returns no snapshot after cancellation. The Settings state catches cancellation and keeps its last published status, while task startup discards the canceled inspection.

The single probe seam exists for deterministic inventory tests and is not a provider-definition table. It can record locator, verification, authentication, command, and factory order without adding per-provider protocols. There is no global cache, persistence, download, network call, or background poll.

## Synthesis decision

Pending arena synthesis. This candidate intentionally uses the enum-centered shape and keeps the existing package registry as the routing authority.

## Tradeoffs accepted

- We accept one exhaustive switch in the inventory module for each projection in exchange for compile-time coverage when a provider case changes.
- We accept a fresh bounded inspection for Settings, picker, demo, and every task start in exchange for preventing stale Settings authorization and avoiding a global cache.
- We accept keeping setup read models in `App/RuntimeSetup.swift` in exchange for preserving the existing Settings contract and tests.
- We accept `.configured` as planning-eligible but not ready or authenticated in exchange for preserving direct-provider behavior and explicit user verification at planning time.

## Alternatives considered

A data-driven `[ProviderSpec]` table with IDs, names, factories, verification closures, authentication closures, and command closures has a short assembly loop, but it exposes a shallow bag of policy and lets a runtime, descriptor, executable, and command drift apart. It also makes “verify before auth” and the Codex, Claude, and OpenCode trust differences closure conventions rather than type-visible cases. The enum hides those choices behind one inventory interface and lets the compiler find provider additions; the only closures retained here are the single credential source and test probe seam.

Putting probing and routing into `RuntimeProviderRegistry` would make the package depend on App Keychain, executable verification, and Codex home policy. It would leak infrastructure into the existing eligibility module, so the App inventory builds typed providers and reuses the registry only for eligibility and fallback.

## Open questions and risks

- Should background task cards retain the current known display names when a provider is absent from a fresh snapshot, or is the raw provider ID fallback acceptable?
- Should a non-cancellation Keychain read failure remain represented only in `setup.summary`, as it is today, or gain a dedicated inventory error state?

## Next implementation step

Add `App/RuntimeInventory.swift` with the enum, live probe, and pure snapshot projections, then migrate task routing first so every execution path proves freshness before Settings and demo callers are switched.

## Module map

- `App/RuntimeInventory.swift`: owns `ResolvedRuntime`, inspection sequencing, provider assembly, snapshot projections, and the one test probe seam.
- `App/RuntimeSetup.swift`: retains the moved setup value types verbatim.
- `App/AppController.swift`: owns the service and delegates setup, choices, demo preflight, and fresh task selection without provider-ID switches.
- `App/SettingsView.swift`, `App/SessionPanelView.swift`, and `App/BackgroundTasksWindow.swift`: consume setup, choice, and descriptor-derived display projections.
- `App/RuntimeExecutableVerifier.swift`: remains the immutable executable trust and pin policy boundary.
- `Packages/PerryRuntimes/Sources/PerryRuntimes/DirectProviderRuntime.swift`: becomes the single host-to-`DirectAIProvider` mapping used by App settings and inventory.
- `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeProviderRegistry.swift` and `App/ProductionRuntimeSelector.swift`: keep their existing eligibility, fallback, and explanation behavior.

## Exact migration steps

1. Add the enum, inspection result, service, and snapshot; wire live locators to the existing verifier and official auth methods in verify-then-auth order.
2. Centralize direct host inference in `DirectAIProvider`; make `RuntimeProviderSetupChoice` and `AppController.directProviderConfiguration` consume it, removing repeated host and ID switches.
3. Replace `makeRuntime` with fresh snapshot inspection plus `snapshot.select`, preserving explicit task preference and the service's automatic preference; use the same path for foreground, background, and resumed tasks.
4. Make `RuntimeSettingsState`'s loader throwing, publish only a completed snapshot, and replace `currentRuntimeSetup` and `availableRuntimeChoices` internals with `snapshot.setup` and `snapshot.choices`.
5. Replace demo's three readiness probes with `hasReadyCLIPlanner`, keep its local fallback message, and leave `beginDo` responsible for a new task inspection.
6. Replace picker and background display identifier switches with projections; add inventory-boundary tests for exact executable reuse, auth ordering, rejected-command absence, cancellation, projections, and registry fallback explanations.
