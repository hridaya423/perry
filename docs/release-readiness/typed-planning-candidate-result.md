## Usage (caller's view)

The queue creates its workspace, selects through the real inventory and selector, then asks the selected provider for one result:

```swift
let request = PlanningRequest(
    goal: trimmed,
    taskID: id,
    workspace: workspace,
    context: .none
)
let result = try await selection.plan(request)
switch result {
case .typed(let plan):
    let record = try await coordinator.enqueue(executablePlan: plan)
case .legacy(let plan):
    let record = try await backgroundTaskRunner.enqueue(plan: plan, id: id)
}
```

If planning throws `contextRequired`, the queue acquires permissions and an exact Cua capture once, builds `request.withScreenContext(...)`, and retries through a route requiring `guiGrounding`. A file-only result never enters that branch. File-only metadata uses the existing `BackgroundTaskMetadata`: `workspacePath` and route fields are set, while its optional target fields stay nil.

The foreground GUI caller supplies the already captured context, while a migration caller can keep the old runner explicit:

```swift
let grounded = try await guiSelection.plan(request.withScreenContext(captured.context))
let legacyRecord = try await backgroundTaskRunner.enqueue(plan: legacyPlan, id: id)
```

## Problem

`TaskPlanner.plan(goal:context:)` returns the legacy `Plan` (`AgentRuntime.swift:4-8`), while the local planner already has a separate typed file boundary (`LocalTaskPlannerRuntime.swift:43-69`). The queue captures a target before selection (`AppController.swift:1393-1419`) and then casts `RuntimeRouteDecision.runtime` to `LocalTaskPlannerRuntime` (`AppController.swift:1422-1427`), even though the decision exposes a `RuntimeProviderAdapter` (`RuntimeProviderRegistry.swift:618-625`). The cast makes canonical typed creation unreachable and forces file-only work through capture and permission setup.

## Shape

Add these domain values in `PerryRuntimes`:

```swift
public struct PlanningRequest: Sendable {
    public let goal: String
    public let taskID: TaskID
    public let workspace: URL
    public let context: PlanningContext
}

public enum PlanningContext: Sendable {
    case none
    case screen(ScreenContext)
}

public enum PlanningResult: Sendable {
    case typed(ExecutionPlan)
    case legacy(Plan)
}

public enum PlanningError: Error, Sendable {
    case contextRequired
    case typedPlanRejected(String)
}

public protocol TaskPlanner: Sendable {
    var id: String { get }
    var capabilities: RuntimeCapabilities { get }
    func plan(_ request: PlanningRequest) async throws -> PlanningResult
}
```

`RuntimeProvider.plan(_:)` owns the planning-operation guard and validates a typed result against the request before it leaves the provider boundary: task ID and canonical goal match, every workspace-bearing operation remains inside `request.workspace`, and the existing `ExecutionPlan` initializer validates action IDs, scopes, operation data, and postconditions. A mismatch throws `typedPlanRejected`; it never becomes a legacy plan or falls through to another provider. The provider registry continues to own authentication, installation, confinement, health, preference, and fallback (`RuntimeProviderRegistry.swift:747-889`).

`LocalTaskPlannerRuntime` returns `.typed` for its canonical file request and may return `.legacy` only for the explicitly fenced migration path. A planner that receives `.none` must either return a context-free result or throw `contextRequired`; it cannot return a GUI plan that pretends to have a target. `RuntimeProviderAdapter` remains a compatibility adapter for old execution callers, but new queue creation calls the selected provider's planning result and never casts a concrete runtime.

The typed result is the only source of typed execution authority. The app passes it to `TaskCoordinator.enqueue(executablePlan:)` (`TaskCoordinator.swift:482-490`); approval issues a grant for the exact action and revision (`TaskCoordinator.swift:497-533`), and execution uses the coordinator-owned grant and workspace runtime (`TaskCoordinator.swift:562-615`). A legacy result is stored as a legacy task and follows the existing legacy runner during migration. It is never converted with `ExecutionPlanAdapter.migrateLegacy`, and it cannot issue a typed workspace grant.

## Module map and migration

- `PerryRuntimes/PlanningTypes.swift`: request, context, result, and planning errors.
- `AgentRuntime.swift`: typed `TaskPlanner`; a local `LegacyTaskPlannerAdapter` wraps existing providers and returns `.legacy` without manufacturing typed authority.
- `RuntimeProviderRegistry.swift`: provider-owned result validation and route-decision planning entry point; descriptor policy remains unchanged.
- `LocalTaskPlannerRuntime.swift`: canonical workspace file requests become typed; other cases stay explicitly legacy until each provider has a typed planner.
- `CLIRuntime`, `CodexRuntime`, `OpenCodeRuntime`, and direct providers: migrate one at a time from legacy adapter to typed result. No provider may silently change a thrown typed-planning error into fallback.
- `App/RuntimeInventory.swift` and `ProductionRuntimeSelector.swift`: keep one inspected registry and the existing bounded, healthy route policy.
- `App/AppController.swift`: plan with `.none`, acquire Cua only after `contextRequired`, write nil target metadata for file-only work, and remove the concrete Local cast.
- `TaskPlan.swift`, `TaskCoordinator.swift`, and `DoSupervisor.swift`: retain legacy records only behind the migration boundary, then remove legacy admission, conversion, and runner overloads once all production planners return typed results.

## Regression tests

- `AppTests/BackgroundTaskLifecycleOrderingTests.swift`: queue a canonical file request through the real `RuntimeInventoryInspector` with empty CLI and direct inputs, let the real selector choose local, and assert no permission or capture spy fired, target metadata is nil, the workspace is under the debug root, and the queued record is executable with approval still required.
- The same test boundary supplies a typed planner rejection and asserts no legacy enqueue, record, metadata, workspace effect, or Cua fallback follows `typedPlanRejected`.
- A context-required fixture starts with a receive of `.none`, asserts one permission and exact Cua capture, retries with `.screen`, and verifies the GUI route carries the captured target. A cancellation barrier during inspection or planning asserts no record or metadata publication.
- `Packages/PerryRuntimes/Tests/PerryRuntimesTests`: assert provider validation rejects wrong task ID, escaped workspace, and missing context; assert a legacy adapter returns `.legacy` unchanged and never produces a typed plan.

## Rationale and tradeoffs

This is a deep planning boundary: callers ask for a result and do not know whether the provider is a local parser, CLI, or direct model, while the provider retains validation and authority policy. It keeps the current registry and readiness contract intact, fixes the observed adapter cast, and makes context acquisition a deliberate retry rather than a prerequisite for every plan.

The accepted cost is a temporary legacy enum and adapter while providers migrate. That cost is explicit and removable. The capability-only alternative, an optional `TypedTaskPlanner` cast beside the old protocol, keeps two planning APIs and leaves the app coordinating concrete capability checks, so it hides less policy. Eager capture preserves today's order but violates file-only no-capture. Universal legacy-to-typed conversion is rejected because it would turn untrusted step payloads into executable approval authority.

## Open questions and next step

Should the migration flag permit legacy admission in production at all, or only in a diagnostic build while typed provider coverage grows? Which first non-local provider can produce a typed action with an independently verifiable postcondition? The first implementation step is to add the result boundary and provider validation, then land the canonical file queue regression before migrating another planner.
