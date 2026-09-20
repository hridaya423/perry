# Candidate: data-driven runtime provider catalog

## Usage (caller's view)

Each consumer asks for one fresh, immutable inventory value. The value contains the existing registry plus the projections needed by UI and demo code.

```swift
let inventory = try await runtimeInventory.inspect(workingDirectory: nil)
return RuntimeSettingsState.Status(
    setup: inventory.setup,
    cuaStatus: await currentCuaDriverStatus()
)
```

Settings' picker projection is equally direct:

```swift
let inventory = try await runtimeInventory.inspect(workingDirectory: nil)
return inventory.choices
```

Demo preflight reads the same inventory contract without naming a provider:

```swift
let inventory = try await runtimeInventory.inspect(workingDirectory: nil)
if !inventory.hasReadyPlanningCLI {
    sessionStatus = "Using Perry's private local planner for the supported demo task."
}
return .ready
```

Task routing inspects again at the task boundary, then reuses the registry's current selection and explanation:

```swift
let inventory = try await runtimeInventory.inspect(workingDirectory: workspace)
guard taskStartIsCurrent(attemptID) else { return nil }
guard let selection = ProductionRuntimeSelector().select(
    from: inventory.registry,
    preferredProviderID: requestedProviderID ?? inventory.automaticPreferredProviderID
) else { return nil }
```

The Settings snapshot is never passed to task routing, so a previous status check cannot authorize a later task.

## Problem

`AppController` currently assembles providers in `makeRuntime`, re-locates executables in `currentRuntimeSetup`, repeats verification in three `verified*Status` methods, and rebuilds direct-provider choices separately. The release contract requires one provider-specific source of truth while preserving Codex's private home, Claude's official signing check, OpenCode's pinned artifact, planning-only providers, direct and custom planning, local fallback, route explanations, exact executable identity, and cancellation. The current checkout and `RuntimeSetup.swift` move are the evidence boundary; this candidate makes no claim about historical intent.

## Shape

`RuntimeProviderCatalog` is an ordered value catalog. Each declaration carries typed identity and policy data, an installation spec, an authentication spec, a runtime factory, and readiness presentation. The catalog contains the active direct declaration when a Keychain credential and endpoint are configured, then Codex, Claude, OpenCode, and local in the existing order.

```swift
struct RuntimeProviderDeclaration {
    let identity: RuntimeProviderIdentity
    let capabilities: RuntimeCapabilities
    let operations: Set<RuntimeOperation>
    let confinement: RuntimeConfinement
    let priority: Int
    let isAutomaticCandidate: Bool
    let installation: RuntimeInstallationSpec
    let authentication: RuntimeAuthenticationSpec
    let makeRuntime: RuntimeFactory
    let readiness: @Sendable (RuntimeInstallationStatus, RuntimeAuthenticationStatus) -> RuntimeReadiness
}

enum RuntimeInstallationSpec {
    case notApplicable(RuntimeInstallationSource)
    case executable(
        locate: @Sendable () throws -> URL,
        verify: @Sendable (URL) async throws -> RuntimeInstallationStatus
    )
}

enum RuntimeAuthenticationSpec {
    case notRequired
    case configuredCredential
    case officialCLI(
        probe: @Sendable (URL) async throws -> RuntimeAuthenticationStatus,
        signIn: [String],
        signOut: [String],
        environment: @Sendable (RuntimeFactoryInput) -> [String: String]
    )
}

enum RuntimeFactoryInput {
    case executable(URL, workingDirectory: URL?, codexRuntimeHome: URL?)
    case direct(DirectProviderConfiguration, credential: String)
    case custom(BYOKAgentEndpoint, credential: String)
    case local
}

typealias RuntimeFactory = @Sendable (RuntimeFactoryInput, RuntimeProviderDescriptor) -> RuntimeProvider
```

`RuntimeProviderInventoryService.inspect(workingDirectory:) async throws` reads endpoint, model, and the direct credential once, creates the catalog, and visits declarations in order. For an executable declaration it locates once, passes that exact URL to verification, and passes the same URL to official authentication, commands, and the runtime factory. It calls authentication only after a verified installation; an unverified entry can remain visible with a rejection descriptor but receives no login command.

The service creates one final `RuntimeProviderDescriptor` and one `RuntimeProvider` per discovered declaration, then constructs one `RuntimeProviderRegistry`. It derives `RuntimeSetupSnapshot`, `RuntimeChoice` values, summary text, and `hasReadyPlanningCLI` from those records. Direct and custom credentials remain `.configured`, which the existing registry treats as planning-eligible while readiness remains false. Claude and OpenCode declarations advertise `[.planning]`; Codex retains `[.planning, .execution]`; local remains the bounded fallback.

`RuntimeExecutableVerifier` remains the only identity boundary. Catalog declarations reference its Codex, Claude, and OpenCode verification entry points, so Codex and OpenCode pins and Claude's Anthropic signing requirement stay immutable and cannot arrive from Settings or a task request. Official authentication references the existing runtime probes, not a generic credential-file reader. The direct declaration uses the existing endpoint policy and Keychain value without a new provider network call.

The public inventory surface is one deep operation. It hides locator failures, checksum and signature checks, official login probing, factory capture, setup-command construction, summary wording, choice ordering, and registry assembly. Callers retain only a snapshot, the existing `ProductionRuntimeSelector`, and typed provider preference. There is no global cache: every Settings refresh, picker load, demo preflight, and task start gets a fresh value, and cancellation returns no inventory.

## Migration steps

1. Add `App/RuntimeProviderCatalog.swift` with the declaration and spec types. Encode the six active shapes as data, map official direct hosts through `DirectAIProvider.allCases`, and keep direct protocol switches inside `DirectProviderRuntime`.
2. Add `App/RuntimeProviderInventory.swift`. Inject the Keychain and settings readers as closures for deterministic tests, inspect sequentially with cancellation checks, and publish only a completed inventory. Preserve the current missing-locator, unverified-installation, authentication-status, summary, and ordering behavior.
3. Replace `makeRuntime`'s provider array with a fresh inspection and pass its registry plus `requestedProviderID ?? automaticPreferredProviderID` to `ProductionRuntimeSelector`. Use the same path for foreground tasks, background enqueue, and background resume.
4. Replace `currentRuntimeSetup`, `availableRuntimeChoices`, and demo calls to `verified*Status` with `inventory.setup`, `inventory.choices`, and `inventory.hasReadyPlanningCLI`. Keep `RuntimeSettingsState` as the cancellation and publication owner; a canceled load never publishes a partial inventory.
5. Replace `RuntimeProviderSetupChoice`, `runtimeName`'s identifier switch, and the provider-specific status methods with catalog projections after all callers use the inventory. Keep the moved `RuntimeReadiness`, `RuntimeSetupRecord`, `RuntimeSetupSnapshot`, `RuntimeChoice`, and `RuntimeAuthenticationCommand` definitions in `App/RuntimeSetup.swift`.
6. Test the inventory boundary with fake declarations: assert one locator call, exact URL reuse, verification-before-authentication, no commands for unverified executables, direct/custom/local behavior, current choice order, cancellation without a returned value, and registry route explanations. Retain the existing registry eligibility tests.

## Synthesis decision

This is one candidate for parent comparison. It does not claim a cross-runner synthesis decision.

## Tradeoffs accepted

- We accept sequential inspection in exchange for a visible cancellation order and one exact executable value; the contract provides no evidence that parallel probing is needed.
- We accept rebuilding a small immutable snapshot for each consumer in exchange for never treating Settings state as task authorization and avoiding cache invalidation.
- We accept a few typed declaration closures in exchange for removing provider identifier switches from `AppController` and keeping provider knowledge in one catalog.

## Alternatives considered

- Keeping `makeRuntime`, three readiness methods, setup assembly, and choice assembly while extracting only shared helpers loses because callers still coordinate separate policy paths, can re-locate different executable values, and cannot prove that the Settings result matches task routing.
- Making `RuntimeProviderRegistry` discover executables and read Keychain state loses because the package would own App infrastructure and code-signing concerns; the existing registry would become a shallow integration layer instead of retaining its focused eligibility algorithm.
- A global cached inventory loses because authentication and executable identity can change after Settings renders, while cache lifetime, invalidation, and cancellation would add state without a release requirement.

## Open questions and risks

Should one Settings refresh serve both the setup view and its background-task picker, or is fresh per-consumer inspection acceptable? This candidate assumes fresh inspection because only task-start inspection can be an authorization boundary.

Should the existing presentation IDs remain `String` for compatibility, or should `RuntimeSetupRecord` and `RuntimeChoice` gain `RuntimeProviderID` after this migration? The catalog and registry use typed IDs either way.

## Next implementation step

Add the catalog and inventory boundary with focused fake-declaration tests, then migrate `AppController` callers one at a time without changing the registry algorithm.
